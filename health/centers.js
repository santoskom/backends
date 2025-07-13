const express = require('express');
const router = express.Router();
const { Pool } = require('pg');

const pool = new Pool({
  host: process.env.DB_HOST || 'localhost',
  port: process.env.DB_PORT || 5432,
  database: process.env.DB_NAME || 'vaccination_db',
  user: process.env.DB_USER || 'postgres',
  password: process.env.DB_PASSWORD || 'password',
  ssl: process.env.NODE_ENV === 'production' ? { rejectUnauthorized: false } : false
});

// GET /api/health-centers?region_id=&district_id=
router.get('/', async (req, res) => {
  const client = await pool.connect();
  try {
    const { region_id, district_id } = req.query;
    let query = `
      SELECT hc.id, hc.center_name, hc.center_code, hc.address,
             d.district_name, r.region_name
      FROM vaccination.health_centers hc
      JOIN vaccination.districts d ON hc.district_id = d.id
      JOIN vaccination.regions r ON d.region_id = r.id
      WHERE hc.is_active = true
    `;
    const params = [];

    if (region_id) {
      params.push(region_id);
      query += ` AND r.id = $${params.length}`;
    }

    if (district_id) {
      params.push(district_id);
      query += ` AND d.id = $${params.length}`;
    }

    query += ' ORDER BY hc.center_name';

    const result = await client.query(query, params);
    res.json({ healthCenters: result.rows });

  } catch (error) {
    console.error('Erreur lors de la récupération des centres de santé :', error);
    res.status(500).json({ error: 'Erreur interne du serveur' });
  } finally {
    client.release();
  }
});

module.exports = router;
