// routes/sideEffects.js
const express = require('express');
const router = express.Router();
const { Pool } = require('pg');

// Config connexion PG, adapte selon ton .env ou config
const pool = new Pool({
  host: process.env.DB_HOST || 'localhost',
  port: process.env.DB_PORT || 5432,
  database: process.env.DB_NAME || 'vaccination',
  user: process.env.DB_USER || 'postgres',
  password: process.env.DB_PASSWORD || 'password',
});

// GET /side-effects?status=active&severity=grave&page=1&limit=10
router.get('/', async (req, res) => {
  try {
    const { status, severity, page = 1, limit = 10, search } = req.query;

    let filters = [];
    let values = [];
    let idx = 1;

    if (status) {
      filters.push(`status = $${idx++}`);
      values.push(status);
    }
    if (severity) {
      filters.push(`severity = $${idx++}`);
      values.push(severity);
    }
    if (search) {
      filters.push(`(patient_name ILIKE $${idx} OR effect_description ILIKE $${idx})`);
      values.push(`%${search}%`);
      idx++;
    }

    const whereClause = filters.length ? `WHERE ${filters.join(' AND ')}` : '';

    const offset = (page - 1) * limit;

    const query = `
      SELECT *
      FROM vaccination.side_effect_monitoring
      ${whereClause}
      ORDER BY created_at DESC
      LIMIT $${idx++} OFFSET $${idx++}
    `;

    values.push(limit);
    values.push(offset);

    const { rows } = await pool.query(query, values);

    // Obtenir total pour pagination
    const countQuery = `
      SELECT COUNT(*) AS total
      FROM vaccination.side_effect_monitoring
      ${whereClause}
    `;
    const countResult = await pool.query(countQuery, values.slice(0, idx - 3));
    const total = parseInt(countResult.rows[0].total, 10);

    res.json({
      data: rows,
      pagination: {
        total,
        page: Number(page),
        limit: Number(limit),
        totalPages: Math.ceil(total / limit),
      },
    });
  } catch (error) {
    console.error('Erreur GET /side-effects', error);
    res.status(500).json({ error: 'Erreur serveur' });
  }
});

// GET /side-effects/:id
router.get('/:id', async (req, res) => {
  try {
    const effectId = req.params.id;
    const query = `
      SELECT *
      FROM vaccination.side_effect_monitoring
      WHERE id = $1
    `;
    const { rows } = await pool.query(query, [effectId]);
    if (rows.length === 0) {
      return res.status(404).json({ error: 'Effet indésirable non trouvé' });
    }
    res.json(rows[0]);
  } catch (error) {
    console.error('Erreur GET /side-effects/:id', error);
    res.status(500).json({ error: 'Erreur serveur' });
  }
});

// POST /side-effects/:id/followups
// Body: { followup_type: 'appel'|'visite'|'message'|'traitement'|'résolution', notes?: string }
router.post('/:id/followups', async (req, res) => {
  try {
    const effectId = req.params.id;
    const { followup_type, notes } = req.body;

    if (!['appel', 'visite', 'message', 'traitement', 'résolution'].includes(followup_type)) {
      return res.status(400).json({ error: 'Type de suivi invalide' });
    }

    const insertQuery = `
      INSERT INTO vaccination.side_effect_followups(side_effect_id, followup_type, notes)
      VALUES ($1, $2, $3)
      RETURNING *
    `;
    const { rows } = await pool.query(insertQuery, [effectId, followup_type, notes || null]);

    res.status(201).json({ message: 'Suivi ajouté', followup: rows[0] });
  } catch (error) {
    console.error('Erreur POST /side-effects/:id/followups', error);
    res.status(500).json({ error: 'Erreur serveur' });
  }
});

// POST /side-effects/:id/resolve
router.post('/:id/resolve', async (req, res) => {
  try {
    const effectId = req.params.id;

    // Appel à la procédure stockée resolve_side_effect
    const query = `CALL vaccination.resolve_side_effect($1)`;
    await pool.query(query, [effectId]);

    res.json({ message: 'Effet indésirable marqué comme résolu' });
  } catch (error) {
    console.error('Erreur POST /side-effects/:id/resolve', error);
    res.status(500).json({ error: 'Erreur serveur' });
  }
});

module.exports = router;
