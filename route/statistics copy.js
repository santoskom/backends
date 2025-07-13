// backend/api/statistics.js
const express = require('express');
const router = express.Router();
const pool = require('../db'); // Connexion PostgreSQL via pg

// Vue de couverture vaccinale
router.get('/coverage', async (req, res) => {
  try {
    const result = await pool.query('SELECT * FROM vaccination.vaccination_coverage_stats');
    res.json(result.rows);
  } catch (err) {
    console.error('Erreur couverture vaccinale:', err);
    res.status(500).json({ error: 'Erreur serveur' });
  }
});

// Vue de stocks de vaccins
router.get('/stocks', async (req, res) => {
  try {
    const result = await pool.query('SELECT * FROM vaccination.stock_status');
    res.json(result.rows);
  } catch (err) {
    console.error('Erreur stock vaccins:', err);
    res.status(500).json({ error: 'Erreur serveur' });
  }
});

module.exports = router;
