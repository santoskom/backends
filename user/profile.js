// routes/user/profile.js
const express = require('express');
const router = express.Router();
const { Pool } = require('pg');
const authenticateToken = require('../../middlewares/authenticateToken');

const pool = new Pool({
    host: process.env.DB_HOST || 'localhost',
    port: process.env.DB_PORT || 5432,
    database: process.env.DB_NAME || 'vaccination_db',
    user: process.env.DB_USER || 'postgres',
    password: process.env.DB_PASSWORD || 'password',
    ssl: process.env.NODE_ENV === 'production' ? { rejectUnauthorized: false } : false
});

// Obtenir le profil de l'utilisateur connecté
router.get('/profile', authenticateToken, async (req, res) => {
    const client = await pool.connect();
    try {
        const userResult = await client.query(
            `SELECT u.*, ut.type_name, ut.type_code, hc.center_name
             FROM vaccination.users u
             JOIN vaccination.user_types ut ON u.user_type_id = ut.id
             LEFT JOIN vaccination.health_centers hc ON u.health_center_id = hc.id
             WHERE u.id = $1`,
            [req.user.userId]
        );

        if (userResult.rows.length === 0) {
            return res.status(404).json({ error: 'Utilisateur non trouvé' });
        }

        const user = userResult.rows[0];
        delete user.password_hash;

        res.json({ user });

    } catch (error) {
        console.error('Erreur lors de la récupération du profil:', error);
        res.status(500).json({ error: 'Erreur interne du serveur' });
    } finally {
        client.release();
    }
});

// Mise à jour du profil
router.put('/profile', authenticateToken, async (req, res) => {
    const client = await pool.connect();
    try {
        const { first_name, last_name, email, phone, preferred_language } = req.body;

        const result = await client.query(
            `UPDATE vaccination.users 
             SET first_name = $1, last_name = $2, email = $3, phone = $4, preferred_language = $5
             WHERE id = $6
             RETURNING id, first_name, last_name, email, phone, preferred_language`,
            [first_name, last_name, email, phone, preferred_language, req.user.userId]
        );

        res.json({
            message: 'Profil mis à jour avec succès',
            user: result.rows[0]
        });

    } catch (error) {
        console.error('Erreur lors de la mise à jour du profil:', error);
        res.status(500).json({ error: 'Erreur interne du serveur' });
    } finally {
        client.release();
    }
});

module.exports = router;
