const express = require('express');
const router = express.Router();
const { Pool } = require('pg');
const authenticateToken = require('../middleware/authenticateToken');

const pool = new Pool({
  host: process.env.DB_HOST || 'localhost',
  port: process.env.DB_PORT || 5432,
  database: process.env.DB_NAME || 'vaccination_db',
  user: process.env.DB_USER || 'postgres',
  password: process.env.DB_PASSWORD || 'password',
  ssl: process.env.NODE_ENV === 'production' ? { rejectUnauthorized: false } : false
});

router.get('/verify', authenticateToken, async (req, res) => {
  const client = await pool.connect();
  try {
    const result = await client.query(
      `SELECT u.id, u.first_name, u.last_name, u.email, u.phone, u.user_type_id, 
              ut.type_code, ut.type_name, hc.center_name
       FROM vaccination.users u
       JOIN vaccination.user_types ut ON u.user_type_id = ut.id
       LEFT JOIN vaccination.health_centers hc ON u.health_center_id = hc.id
       WHERE u.id = $1`,
      [req.user.userId]
    );

    if (result.rows.length === 0) {
      return res.status(404).json({ error: 'Utilisateur non trouvé' });
    }

    const user = result.rows[0];

    res.json({
      valid: true,
      user: {
        id: user.id,
        first_name: user.first_name,
        last_name: user.last_name,
        email: user.email,
        phone: user.phone,
        user_type_id: user.user_type_id,
        user_type_code: user.type_code,
        type_name: user.type_name,
        center_name: user.center_name
      }
    });
  } catch (error) {
    console.error('Erreur vérification token :', error);
    res.status(500).json({ error: 'Erreur interne du serveur' });
  } finally {
    client.release();
  }
});

module.exports = router;
