const express = require('express');
const router = express.Router();
const bcrypt = require('bcrypt');
const jwt = require('jsonwebtoken');
const { pool } = require('../db');
const logger = require('../logger');

router.post('/', async (req, res) => {
    const client = await pool.connect();
    try {
        let {
            user_type_id,
            email,
            phone,
            password,
            first_name,
            last_name,
            date_of_birth,
            gender,
            cin,
            health_center_id,
            preferred_language = 'fr'
        } = req.body;

        // Assure-toi que user_type_id est un nombre
        user_type_id = parseInt(user_type_id);

        if (!user_type_id || !first_name || !last_name || !phone || !password) {
            return res.status(400).json({ 
                error: 'Données manquantes',
                details: "Type d'utilisateur, nom, prénom, téléphone et mot de passe sont obligatoires"
            });
        }

        // Validation conditionnelle : health_center_id obligatoire sauf si CITIZEN (id 1)
        if (user_type_id !== 1 && !health_center_id) {
            return res.status(400).json({ 
                error: 'Centre de santé requis pour les professionnels de santé et agents communautaires'
            });
        }

        // Vérifier si l'utilisateur existe déjà
        const existingUser = await client.query(
            'SELECT id FROM vaccination.users WHERE email = $1 OR phone = $2',
            [email, phone]
        );

        if (existingUser.rows.length > 0) {
            return res.status(409).json({ error: 'Un utilisateur avec cet email ou téléphone existe déjà' });
        }

        const hashedPassword = await bcrypt.hash(password, 10);

        const userResult = await client.query(
            `INSERT INTO vaccination.users (
                user_type_id, email, phone, password_hash, first_name, last_name,
                date_of_birth, gender, cin, health_center_id, preferred_language
            ) VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11)
            RETURNING id, first_name, last_name, email, phone, user_type_id`,
            [user_type_id, email, phone, hashedPassword, first_name, last_name,
             date_of_birth, gender, cin, health_center_id, preferred_language]
        );

        const user = userResult.rows[0];

        if (user_type_id === 1) { // CITIZEN
            await client.query(
                'SELECT vaccination.create_vaccination_card($1, NULL)',
                [user.id]
            );
        }

        const userTypeResult = await client.query(
            'SELECT type_code FROM vaccination.user_types WHERE id = $1',
            [user_type_id]
        );

        const userTypeCode = userTypeResult.rows[0].type_code;

        const token = jwt.sign(
            { userId: user.id, user_type: user_type_id, user_type_code: userTypeCode },
            process.env.JWT_SECRET || 'secret_key',
            { expiresIn: '24h' }
        );

        let redirectUrl = '/dashboard';
        switch (userTypeCode) {
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

        res.status(201).json({
            message: 'Inscription réussie',
            user: {
                id: user.id,
                first_name: user.first_name,
                last_name: user.last_name,
                email: user.email,
                phone: user.phone,
                user_type_id: user.user_type_id,
                user_type_code: userTypeCode
            },
            token,
            redirectUrl
        });

    } catch (error) {
        logger.error('Erreur lors de l\'inscription:', error);
        res.status(500).json({ error: 'Erreur interne du serveur' });
    } finally {
        client.release();
    }
});



module.exports = router;