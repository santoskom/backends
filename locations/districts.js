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

// GET /api/districts?region_id=123
router.get('/', async (req, res) => {
  const client = await pool.connect();
  try {
    const { region_id } = req.query;
    let query = 'SELECT id, district_code, district_name FROM vaccination.districts';
    const params = [];

    if (region_id) {
      query += ' WHERE region_id = $1';
      params.push(region_id);
    }

    query += ' ORDER BY district_name';

    const result = await client.query(query, params);
    res.json({ districts: result.rows });
  } catch (error) {
    console.error('Erreur lors de la récupération des districts :', error);
    res.status(500).json({ error: 'Erreur interne du serveur' });
  } finally {
    client.release();
  }
});

module.exports = router;
