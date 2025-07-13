// auth/usertypes.js
const express = require('express');
const router = express.Router();
const { pool } = require('../db'); // ✅ CORRECT
const logger = require('../logger'); // facultatif

router.get('/', async (req, res) => {
  try {
    const client = await pool.connect(); // ✅ OK
    const result = await client.query(`
      SELECT id, type_code, type_name, description 
      FROM vaccination.user_types 
      WHERE type_code IN ('CITIZEN', 'HEALTH_PROF', 'COMMUNITY_AGENT')
    `);
    client.release();
    res.json({ user_types: result.rows });
  } catch (error) {
    console.error('Erreur récupération user_types:', error);
    res.status(500).json({ error: 'Erreur interne du serveur' });
  }
});

module.exports = router;
