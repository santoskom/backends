const express = require('express');
const router = express.Router();
const { Pool } = require('pg');
const authenticateToken = require('../middleware/authenticateToken');

// Configuration du pool PostgreSQL
const pool = new Pool({
  host: process.env.DB_HOST || 'localhost',
  port: process.env.DB_PORT || 5432,
  database: process.env.DB_NAME || 'vaccination',
  user: process.env.DB_USER || 'postgres',
  password: process.env.DB_PASSWORD || 'password',
  ssl: false,
});

// GET /api/inventory - Récupérer tous les items d'inventaire avec filtres
router.get('/', authenticateToken, async (req, res) => {
  const {
    search = '',
    category = 'all',
    status = 'all',
    page = 1,
    limit = 10,
    sortBy = 'vaccine_name',
    sortOrder = 'asc'
  } = req.query;

  try {
    let query = `
      SELECT 
        vs.id, vs.batch_number, vs.expiry_date, vs.quantity,
        v.vaccine_name, v.vaccine_code,
        CONCAT(v.storage_temperature_min, '-', v.storage_temperature_max, '°C') AS temperature,
        hc.center_name, hc.address, hc.contact_phone,
        CASE 
          WHEN vs.quantity <= 0 THEN 'critical'
          WHEN vs.quantity <= v.expiry_alert_days THEN 'alert'
          ELSE 'normal'
        END AS status,
        vs.last_updated,
        v.manufacturer,
        v.expiry_alert_days
      FROM vaccination.vaccine_stocks vs
      JOIN vaccination.vaccines v ON vs.vaccine_id = v.id
      JOIN vaccination.health_centers hc ON vs.health_center_id = hc.id
      WHERE 1=1
    `;

    const params = [];
    let paramIndex = 1;

    if (search) {
      query += ` AND (v.vaccine_name ILIKE $${paramIndex} OR vs.batch_number ILIKE $${paramIndex})`;
      params.push(`%${search}%`);
      paramIndex++;
    }

    if (category !== 'all') {
      // Ajuster selon ta table vaccines si tu as un champ vaccine_type
      query += ` AND v.vaccine_type = $${paramIndex}`;
      params.push(category);
      paramIndex++;
    }

    if (status !== 'all') {
      if (status === 'critical') {
        query += ` AND vs.quantity <= 0`;
      } else if (status === 'alert') {
        query += ` AND vs.quantity > 0 AND vs.quantity <= v.expiry_alert_days`;
      } else {
        query += ` AND vs.quantity > v.expiry_alert_days`;
      }
    }

    // Pagination + tri
    const validSortColumns = ['vaccine_name', 'batch_number', 'expiry_date', 'quantity', 'status'];
    const validOrder = ['asc', 'desc'].includes(sortOrder.toLowerCase()) ? sortOrder : 'asc';

    if (validSortColumns.includes(sortBy)) {
      query += ` ORDER BY ${sortBy} ${validOrder}`;
    } else {
      query += ` ORDER BY v.vaccine_name ${validOrder}`;
    }

    query += ` LIMIT $${paramIndex} OFFSET $${paramIndex + 1}`;
    params.push(parseInt(limit), (parseInt(page) - 1) * parseInt(limit));

    const countQuery = `
      SELECT COUNT(*) FROM vaccination.vaccine_stocks vs
      JOIN vaccination.vaccines v ON vs.vaccine_id = v.id
      WHERE 1=1
      ${search ? `AND (v.vaccine_name ILIKE $1 OR vs.batch_number ILIKE $1)` : ''}
    `;

    const countResult = await pool.query(countQuery, search ? [`%${search}%`] : []);
    const totalItems = parseInt(countResult.rows[0].count);

    const result = await pool.query(query, params);

    res.json({
      success: true,
      data: result.rows,
      pagination: {
        totalItems,
        totalPages: Math.ceil(totalItems / parseInt(limit)),
        currentPage: parseInt(page),
        itemsPerPage: parseInt(limit),
      }
    });

  } catch (error) {
    console.error('Error fetching inventory:', error);
    res.status(500).json({ success: false, message: error.message });
  }
});

// GET /api/inventory/:id - Récupérer les détails d'un item
router.get('/:id', authenticateToken, async (req, res) => {
  const { id } = req.params;

  try {
    const itemQuery = `
      SELECT 
        vs.id, vs.vaccine_id, vs.batch_number as lot, vs.expiry_date, vs.quantity, 
        v.vaccine_name as name, v.vaccine_code as code, 
        v.storage_temperature_min || '-' || v.storage_temperature_max || '°C' as temperature,
        hc.center_name as location, hc.address, hc.contact_phone,
        v.manufacturer as supplier,
        v.description,
        CASE 
          WHEN vs.quantity <= 0 THEN 'critical'
          WHEN vs.quantity <= v.expiry_alert_days THEN 'alert'
          ELSE 'normal'
        END as status,
        vs.last_updated,
        'vaccine' as category,
        v.expiry_alert_days as threshold
      FROM vaccination.vaccine_stocks vs
      JOIN vaccination.vaccines v ON vs.vaccine_id = v.id
      JOIN vaccination.health_centers hc ON vs.health_center_id = hc.id
      WHERE v.vaccine_code = $1 OR vs.id::text = $1
    `;
    const itemResult = await pool.query(itemQuery, [id]);

    if (itemResult.rows.length === 0) {
      return res.status(404).json({ success: false, message: 'Item non trouvé' });
    }

    const item = itemResult.rows[0];
    const stockId = item.id;
    const vaccineId = item.vaccine_id;

    const historyQuery = `
      SELECT 
        al.operation,
        al.changed_at as date,
        al.new_values->>'quantity' as quantity_change,
        al.new_values->>'batch_number' as batch_number,
        al.new_values->>'expiry_date' as expiry_date,
        u.first_name || ' ' || u.last_name as changed_by
      FROM vaccination.audit_logs al
      JOIN vaccination.users u ON al.changed_by = u.id
      WHERE al.table_name = 'vaccine_stocks' 
      AND (al.record_id::text = $1 OR al.new_values->>'vaccine_id' = $2::text)
      ORDER BY al.changed_at DESC
      LIMIT 10
    `;
    const historyResult = await pool.query(historyQuery, [stockId, vaccineId]);

    res.json({
      success: true,
      data: {
        ...item,
        history: historyResult.rows
      }
    });
  } catch (error) {
    console.error('Error fetching inventory item:', error);
    res.status(500).json({
      success: false,
      message: 'Erreur lors de la récupération des détails',
      error: error.message
    });
  }
});

// PUT /api/inventory/:id - Mettre à jour un item d'inventaire
router.put('/:id', authenticateToken, async (req, res) => {
  const { id } = req.params;
  const { quantity, reason } = req.body;
  const userId = req.user.userId;

  try {
    const checkQuery = 'SELECT id FROM vaccination.vaccine_stocks WHERE id = $1';
    const checkResult = await pool.query(checkQuery, [id]);

    if (checkResult.rows.length === 0) {
      return res.status(404).json({ success: false, message: 'Item non trouvé' });
    }

    const updateQuery = `
      UPDATE vaccination.vaccine_stocks
      SET quantity = $1, last_updated = NOW(), updated_by = $2
      WHERE id = $3
      RETURNING *
    `;
    const updateResult = await pool.query(updateQuery, [quantity, userId, id]);

    const auditQuery = `
      INSERT INTO vaccination.audit_logs (
        table_name, record_id, operation, new_values, changed_by
      )
      VALUES ('vaccine_stocks', $1, 'UPDATE', $2, $3)
    `;
    await pool.query(auditQuery, [
      id,
      JSON.stringify({ quantity, reason, updated_at: new Date() }),
      userId
    ]);

    res.json({
      success: true,
      data: updateResult.rows[0],
      message: 'Stock mis à jour avec succès'
    });
  } catch (error) {
    console.error('Error updating inventory:', error);
    res.status(500).json({
      success: false,
      message: 'Erreur lors de la mise à jour du stock',
      error: error.message
    });
  }
});

// POST /api/inventory - Ajouter un nouvel item à l'inventaire
router.post('/', authenticateToken, async (req, res) => {
  const {
    vaccineId,
    healthCenterId,
    batchNumber,
    quantity,
    expiryDate,
    temperatureLog
  } = req.body;
  const userId = req.user.userId;

  try {
    const vaccineCheck = await pool.query(
      'SELECT id FROM vaccination.vaccines WHERE id = $1',
      [vaccineId]
    );
    const centerCheck = await pool.query(
      'SELECT id FROM vaccination.health_centers WHERE id = $1',
      [healthCenterId]
    );

    if (vaccineCheck.rows.length === 0 || centerCheck.rows.length === 0) {
      return res.status(400).json({
        success: false,
        message: 'Vaccin ou centre de santé non trouvé'
      });
    }

    const insertQuery = `
      INSERT INTO vaccination.vaccine_stocks (
        vaccine_id, health_center_id, batch_number, 
        quantity, expiry_date, temperature_log,
        last_updated, updated_by
      )
      VALUES ($1, $2, $3, $4, $5, $6, NOW(), $7)
      RETURNING *
    `;
    const insertResult = await pool.query(insertQuery, [
      vaccineId,
      healthCenterId,
      batchNumber,
      quantity,
      expiryDate,
      temperatureLog,
      userId
    ]);

    const auditQuery = `
      INSERT INTO vaccination.audit_logs (
        table_name, record_id, operation, new_values, changed_by
      )
      VALUES ('vaccine_stocks', $1, 'INSERT', $2, $3)
    `;
    await pool.query(auditQuery, [
      insertResult.rows[0].id,
      JSON.stringify(insertResult.rows[0]),
      userId
    ]);

    res.status(201).json({
      success: true,
      data: insertResult.rows[0],
      message: 'Nouveau stock ajouté avec succès'
    });
  } catch (error) {
    console.error('Error adding inventory:', error);
    res.status(500).json({
      success: false,
      message: 'Erreur lors de l\'ajout du stock',
      error: error.message
    });
  }
});

// GET /api/inventory/export - Exporter l'inventaire
router.get('/export', authenticateToken, async (req, res) => {
  const { format = 'csv' } = req.query;

  try {
    const query = `
      SELECT 
        v.vaccine_name as name,
        v.vaccine_code as code,
        vs.batch_number as lot,
        vs.quantity,
        v.expiry_alert_days as threshold,
        CASE 
          WHEN vs.quantity <= 0 THEN 'critical'
          WHEN vs.quantity <= v.expiry_alert_days THEN 'alert'
          ELSE 'normal'
        END as status,
        vs.expiry_date,
        hc.center_name as location,
        v.manufacturer as supplier,
        vs.last_updated
      FROM vaccination.vaccine_stocks vs
      JOIN vaccination.vaccines v ON vs.vaccine_id = v.id
      JOIN vaccination.health_centers hc ON vs.health_center_id = hc.id
      ORDER BY v.vaccine_name
    `;
    const result = await pool.query(query);

    if (format === 'csv') {
      // Convertir en CSV
      const header = Object.keys(result.rows[0]).join(',');
      const rows = result.rows.map(row => 
        Object.values(row).map(value => 
          `"${value !== null ? value.toString().replace(/"/g, '""') : ''}"`
        ).join(',')
      );
      const csv = [header, ...rows].join('\n');

      res.setHeader('Content-Type', 'text/csv');
      res.setHeader('Content-Disposition', 'attachment; filename=inventaire_vaccins.csv');
      return res.send(csv);
    } else {
      // Retourner JSON par défaut
      res.json({
        success: true,
        data: result.rows
      });
    }
  } catch (error) {
    console.error('Error exporting inventory:', error);
    res.status(500).json({
      success: false,
      message: 'Erreur lors de l\'export de l\'inventaire',
      error: error.message
    });
  }
});

module.exports = router;
