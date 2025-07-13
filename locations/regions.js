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

// GET /api/regions
router.get('/', async (req, res) => {
  const client = await pool.connect();
  try {
    const result = await client.query(
      'SELECT id, region_code, region_name FROM vaccination.regions ORDER BY region_name'
    );
    res.json({ regions: result.rows });
  } catch (error) {
    console.error('Erreur lors de la récupération des régions :', error);
    res.status(500).json({ error: 'Erreur interne du serveur' });
  } finally {
    client.release();
  }
});

module.exports = router;
