// backend/routes/userAccount.js
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
  ssl: false,
});

// GET : Récupérer les infos du profil de l'utilisateur connecté
router.get('/', authenticateToken, async (req, res) => {
  try {
    const { rows } = await pool.query(
      `SELECT first_name AS "firstName",
              last_name AS "lastName",
              email,
              phone,
              date_of_birth AS dob,
              EXTRACT(YEAR FROM AGE(date_of_birth))::int AS age,
              cin AS "nationalId"
       FROM vaccination.users
       WHERE id = $1`,
      [req.user.userId]
    );
    if (rows.length === 0) {
      return res.status(404).json({ error: 'Utilisateur non trouvé' });
    }
    res.json(rows[0]);
  } catch (error) {
    console.error('Erreur chargement profil utilisateur :', error);
    res.status(500).json({ error: 'Erreur serveur' });
  }
});

// PUT : Modifier les infos du profil
router.put('/', authenticateToken, async (req, res) => {
  const { firstName, lastName, email, phone, dob, nationalId } = req.body;
  if (!firstName || !lastName || !email || !phone || !dob || !nationalId) {
    return res.status(400).json({ error: 'Tous les champs sont obligatoires' });
  }

  try {
    const result = await pool.query(
      `UPDATE vaccination.users
       SET first_name = $1,
           last_name = $2,
           email = $3,
           phone = $4,
           date_of_birth = $5,
           cin = $6,
           updated_at = CURRENT_TIMESTAMP
       WHERE id = $7`,
      [firstName, lastName, email, phone, dob, nationalId, req.user.userId]
    );
    if (result.rowCount === 0) {
      return res.status(404).json({ error: 'Utilisateur non trouvé' });
    }
    res.json({ message: 'Profil mis à jour avec succès' });
  } catch (error) {
    console.error('Erreur mise à jour profil utilisateur :', error);
    res.status(500).json({ error: 'Erreur serveur' });
  }
});

module.exports = router;
