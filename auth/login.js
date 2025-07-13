const express = require('express');
const router = express.Router();
const bcrypt = require('bcrypt');
const jwt = require('jsonwebtoken');
const { pool } = require('../db');
const logger = require('../logger');

router.post('/login', async (req, res) => {
    const client = await pool.connect();
    try {
        const { identifier, password } = req.body; // identifier peut être email ou phone

        if (!identifier || !password) {
            return res.status(400).json({ error: 'Identifiant et mot de passe requis' });
        }

        // Chercher l'utilisateur
        const userResult = await client.query(
            `SELECT u.*, ut.type_code as user_type_code, ut.type_name, hc.center_name
             FROM vaccination.users u 
             JOIN vaccination.user_types ut ON u.user_type_id = ut.id
             LEFT JOIN vaccination.health_centers hc ON u.health_center_id = hc.id
             WHERE u.email = $1 OR u.phone = $1`,
            [identifier]
        );

        if (userResult.rows.length === 0) {
            return res.status(401).json({ error: 'Identifiant ou mot de passe incorrect' });
        }

        const user = userResult.rows[0];

        // Vérifier le mot de passe
        const passwordMatch = await bcrypt.compare(password, user.password_hash);
        if (!passwordMatch) {
            return res.status(401).json({ error: 'Identifiant ou mot de passe incorrect' });
        }

        // Vérifier si le compte est actif
        if (!user.is_active) {
            return res.status(403).json({ error: 'Compte désactivé' });
        }

        // Mettre à jour la dernière connexion
        await client.query(
            'UPDATE vaccination.users SET last_login = CURRENT_TIMESTAMP WHERE id = $1',
            [user.id]
        );

        // Générer le token JWT
        const token = jwt.sign(
            { userId: user.id, user_type: user.user_type_id, user_type_code: user.user_type_code },
            process.env.JWT_SECRET || 'secret_key',
            { expiresIn: '24h' }
        );
        console.log("🔐 Token JWT généré:", token); // ← ICI
        // Déterminer la redirection selon le type d'utilisateur
        let redirectUrl = '/dashboard';
        switch (user.user_type_code) {
            case 'CITIZEN':
                redirectUrl = '/citoyen/dashboard';
                break;
            case 'HEALTH_PROF':
                redirectUrl = '/pro-sante/dashboard';
                break;
            case 'COMMUNITY_AGENT':
                redirectUrl = '/ag-com/dashboard';
                break;
        }

        res.json({
            message: 'Connexion réussie',
            user: {
                id: user.id,
                first_name: user.first_name,
                last_name: user.last_name,
                email: user.email,
                phone: user.phone,
                user_type_id: user.user_type_id,
                user_type_code: user.user_type_code,
                type_name: user.type_name,
                center_name: user.center_name
            },
            token,
            redirectUrl
        });

    } catch (error) {
        logger.error('Erreur lors de la connexion:', error);
        res.status(500).json({ error: 'Erreur interne du serveur' });
    } finally {
        client.release();
    }

    
      });
    // Nouvelle route pour vérifier le token
router.get('/verify', async (req, res) => {
    const authHeader = req.headers['authorization'];
    const token = authHeader && authHeader.split(' ')[1];

    if (!token) {
        return res.status(401).json({ error: 'Token non fourni' });
    }

    try {
        const decoded = jwt.verify(token, process.env.JWT_SECRET || 'secret_key');
        
        // Vérifiez si l'utilisateur existe toujours
        const userResult = await pool.query(
            `SELECT id, is_active FROM vaccination.users WHERE id = $1`,
            [decoded.userId]
        );

        if (userResult.rows.length === 0 || !userResult.rows[0].is_active) {
            return res.status(401).json({ error: 'Utilisateur invalide' });
        }

        res.json({ valid: true, user: decoded });
    } catch (error) {
        if (error.name === 'TokenExpiredError') {
            return res.status(401).json({ error: 'Token expiré' });
        }
        return res.status(401).json({ error: 'Token invalide' });
    }
});

// Route pour rafraîchir le token
router.post('/refresh', async (req, res) => {
    const { refreshToken } = req.body;
    // Implémentez la logique de refresh token si nécessaire
});




module.exports = router;