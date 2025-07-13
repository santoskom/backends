const express = require('express');
const router = express.Router();
const { Pool } = require('pg');
const authenticateToken = require('../../middlewares/authenticateToken');
const authorizeRole = require('../../middlewares/authorizeRole');

const pool = new Pool({
  host: process.env.DB_HOST || 'localhost',
  port: process.env.DB_PORT || 5432,
  database: process.env.DB_NAME || 'vaccination_db',
  user: process.env.DB_USER || 'postgres',
  password: process.env.DB_PASSWORD || 'password',
  ssl: process.env.NODE_ENV === 'production' ? { rejectUnauthorized: false } : false
});

// ✅ GET /api/family/members
router.get('/members', authenticateToken, authorizeRole(['CITIZEN']), async (req, res) => {
  const client = await pool.connect();
  try {
    const result = await client.query(
      `SELECT fm.*, vc.id as card_id, vc.card_number, vc.qr_code
       FROM vaccination.family_members fm
       LEFT JOIN vaccination.vaccination_cards vc ON fm.id = vc.family_member_id
       WHERE fm.user_id = $1 AND fm.is_active = true
       ORDER BY fm.created_at DESC`,
      [req.user.userId]
    );

    res.json({ members: result.rows });
  } catch (error) {
    console.error('Erreur lors de la récupération des membres de famille :', error);
    res.status(500).json({ error: 'Erreur interne du serveur' });
  } finally {
    client.release();
  }
});

module.exports = router;
