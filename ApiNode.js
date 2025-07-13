// =============================
// CONFIGURATION ET IMPORTS
// =============================

const express = require('express');
const bcrypt = require('bcrypt');
const jwt = require('jsonwebtoken');
const { Pool } = require('pg');
const cors = require('cors');
const rateLimit = require('express-rate-limit');
const helmet = require('helmet');
const winston = require('winston');
const multer = require('multer');
const QRCode = require('qrcode');
const nodemailer = require('nodemailer');
const twilio = require('twilio');

const app = express();

// Configuration de la base de données
const pool = new Pool({
    host: process.env.DB_HOST || 'localhost',
    port: process.env.DB_PORT || 5432,
    database: process.env.DB_NAME || 'vaccination',
    user: process.env.DB_USER || 'postgres',
    password: process.env.DB_PASSWORD || 'pgadmin',
    ssl: process.env.NODE_ENV === 'production' ? { rejectUnauthorized: false } : false
});

// Configuration du logger
const logger = winston.createLogger({
    level: 'info',
    format: winston.format.json(),
    transports: [
        new winston.transports.File({ filename: 'error.log', level: 'error' }),
        new winston.transports.File({ filename: 'combined.log' })
    ]
});

// Middlewares
app.use(helmet());
app.use(cors());
app.use(express.json({ limit: '10mb' }));
app.use(express.urlencoded({ extended: true }));

// Rate limiting
const limiter = rateLimit({
    windowMs: 15 * 60 * 1000, // 15 minutes
    max: 100 // limite à 100 requêtes par fenêtre
});
app.use('/api/', limiter);

// =============================
// MIDDLEWARES D'AUTHENTIFICATION
// =============================

const authenticateToken = (req, res, next) => {
    const authHeader = req.headers['authorization'];
    const token = authHeader && authHeader.split(' ')[1];

    if (!token) {
        return res.status(401).json({ error: 'Token d\'accès requis' });
    }

    jwt.verify(token, process.env.JWT_SECRET || 'secret_key', (err, user) => {
        if (err) {
            return res.status(403).json({ error: 'Token invalide' });
        }
        req.user = user;
        next();
    });
};

const authorizeRole = (roles) => {
    return (req, res, next) => {
        if (!roles.includes(req.user.user_type)) {
            return res.status(403).json({ error: 'Accès non autorisé' });
        }
        next();
    };
};



// Ajout d'une route pour récupérer les types d'utilisateurs
app.get('/api/auth/user-types', async (req, res) => {
    const client = await pool.connect();
    try {
        const result = await client.query(
            'SELECT id, type_code, type_name, description FROM vaccination.user_types ORDER BY type_name'
        );
        res.json({ userTypes: result.rows });
    } catch (error) {
        logger.error('Erreur lors de la récupération des types d\'utilisateurs:', error);
        res.status(500).json({ error: 'Erreur interne du serveur' });
    } finally {
        client.release();
    }
});

// Ajout d'une route pour récupérer les centres de santé
app.get('/api/health-centers', async (req, res) => {
    const client = await pool.connect();
    try {
        const { region_id, district_id } = req.query;
        let query = `
            SELECT hc.id, hc.center_name, hc.center_code, hc.address,
                   d.district_name, r.region_name
            FROM vaccination.health_centers hc
            JOIN vaccination.districts d ON hc.district_id = d.id
            JOIN vaccination.regions r ON d.region_id = r.id
            WHERE hc.is_active = true
        `;
        const params = [];
        
        if (region_id) {
            query += ' AND r.id = $1';
            params.push(region_id);
        }
        
        if (district_id) {
            query += ` AND d.id = $${params.length + 1}`;
            params.push(district_id);
        }
        
        query += ' ORDER BY hc.center_name';
        
        const result = await client.query(query, params);
        res.json({ healthCenters: result.rows });
    } catch (error) {
        logger.error('Erreur lors de la récupération des centres de santé:', error);
        res.status(500).json({ error: 'Erreur interne du serveur' });
    } finally {
        client.release();
    }
});

// Ajout d'une route pour récupérer les régions
app.get('/api/regions', async (req, res) => {
    const client = await pool.connect();
    try {
        const result = await client.query(
            'SELECT id, region_code, region_name FROM vaccination.regions ORDER BY region_name'
        );
        res.json({ regions: result.rows });
    } catch (error) {
        logger.error('Erreur lors de la récupération des régions:', error);
        res.status(500).json({ error: 'Erreur interne du serveur' });
    } finally {
        client.release();
    }
});

// Ajout d'une route pour récupérer les districts
app.get('/api/districts', async (req, res) => {
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
        logger.error('Erreur lors de la récupération des districts:', error);
        res.status(500).json({ error: 'Erreur interne du serveur' });
    } finally {
        client.release();
    }
});

// Amélioration de la route d'inscription avec validation renforcée
app.post('/api/auth/register', async (req, res) => {
    const client = await pool.connect();
    try {
        const {
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

        // Validation des données requises
        if (!user_type_id || !first_name || !last_name || !phone || !password) {
            return res.status(400).json({ 
                error: 'Données manquantes', 
                details: 'user_type_id, first_name, last_name, phone et password sont requis' 
            });
        }

        // Validation du format email si fourni
        if (email && !/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email)) {
            return res.status(400).json({ error: 'Format email invalide' });
        }

        // Validation du format téléphone
        if (!/^\+?[0-9]{8,15}$/.test(phone.replace(/\s/g, ''))) {
            return res.status(400).json({ error: 'Format téléphone invalide' });
        }

        // Validation du mot de passe (minimum 8 caractères)
        if (password.length < 8) {
            return res.status(400).json({ error: 'Le mot de passe doit contenir au moins 8 caractères' });
        }

        // Vérifier si le type d'utilisateur existe
        const userTypeResult = await client.query(
            'SELECT id, type_code FROM vaccination.user_types WHERE id = $1',
            [user_type_id]
        );

        if (userTypeResult.rows.length === 0) {
            return res.status(400).json({ error: 'Type d\'utilisateur invalide' });
        }

        const userType = userTypeResult.rows[0];

        // Validation spécifique selon le type d'utilisateur
        if (['HEALTH_PROF', 'COMMUNITY_AGENT'].includes(userType.type_code)) {
            if (!health_center_id) {
                return res.status(400).json({ 
                    error: 'Centre de santé requis pour ce type d\'utilisateur' 
                });
            }
        }

        // Vérifier si l'utilisateur existe déjà
        const existingUser = await client.query(
            'SELECT id FROM vaccination.users WHERE email = $1 OR phone = $2',
            [email, phone]
        );

        if (existingUser.rows.length > 0) {
            return res.status(409).json({ error: 'Un utilisateur avec cet email ou téléphone existe déjà' });
        }

        // Hacher le mot de passe
        const hashedPassword = await bcrypt.hash(password, 12);

        // Insérer l'utilisateur
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

        // Créer automatiquement un carnet de vaccination pour les citoyens
        if (user_type_id === 1) { // Type citoyen
            await client.query(
                'SELECT vaccination.create_vaccination_card($1, NULL)',
                [user.id]
            );
        }

        // Générer le token JWT
        const token = jwt.sign(
            { 
                userId: user.id, 
                user_type: user_type_id, 
                user_type_code: userType.type_code 
            },
            process.env.JWT_SECRET || 'secret_key',
            { expiresIn: '24h' }
        );

        res.status(201).json({
            message: 'Inscription réussie',
            user: {
                id: user.id,
                first_name: user.first_name,
                last_name: user.last_name,
                email: user.email,
                phone: user.phone,
                user_type_id: user.user_type_id,
                user_type_code: userType.type_code
            },
            token
        });

    } catch (error) {
        logger.error('Erreur lors de l\'inscription:', error);
        res.status(500).json({ error: 'Erreur interne du serveur' });
    } finally {
        client.release();
    }
});



// Connexion
app.post('/api/auth/login', async (req, res) => {
    const client = await pool.connect();
    try {
        const { identifier, password } = req.body; // identifier peut être email ou phone

        if (!identifier || !password) {
            return res.status(400).json({ error: 'Identifiant et mot de passe requis' });
        }

        // Chercher l'utilisateur
        const userResult = await client.query(
            `SELECT u.*, ut.type_code as user_type_code
             FROM vaccination.users u 
             JOIN vaccination.user_types ut ON u.user_type_id = ut.id
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

        // Déterminer la redirection selon le type d'utilisateur
        let redirectUrl = '/dashboard';
        switch (user.user_type_code) {
            case 'CITIZEN':
                redirectUrl = '/citizen/dashboard';
                break;
            case 'HEALTH_PROF':
                redirectUrl = '/health-professional/dashboard';
                break;
            case 'COMMUNITY_AGENT':
                redirectUrl = '/community-agent/dashboard';
                break;
            case 'HEALTH_AUTHORITY':
                redirectUrl = '/health-authority/dashboard';
                break;
            case 'INTERNATIONAL_PARTNER':
                redirectUrl = '/international-partner/dashboard';
                break;
            case 'ADMIN':
                redirectUrl = '/admin/dashboard';
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
                user_type_code: user.user_type_code
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

// Vérification du token
app.get('/api/auth/verify', authenticateToken, (req, res) => {
    res.json({ valid: true, user: req.user });
});

// Déconnexion
app.post('/api/auth/logout', authenticateToken, (req, res) => {
    res.json({ message: 'Déconnexion réussie' });
});

// =============================
// APIS GESTION UTILISATEURS
// =============================

// Profil utilisateur
app.get('/api/user/profile', authenticateToken, async (req, res) => {
    const client = await pool.connect();
    try {
        const userResult = await client.query(
            `SELECT u.*, ut.type_name, hc.center_name
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
        logger.error('Erreur lors de la récupération du profil:', error);
        res.status(500).json({ error: 'Erreur interne du serveur' });
    } finally {
        client.release();
    }
});

// Mettre à jour le profil
app.put('/api/user/profile', authenticateToken, async (req, res) => {
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
        logger.error('Erreur lors de la mise à jour du profil:', error);
        res.status(500).json({ error: 'Erreur interne du serveur' });
    } finally {
        client.release();
    }
});

// =============================
// APIS GESTION FAMILLE
// =============================

// Ajouter un membre de famille
app.post('/api/family/add-member', authenticateToken, async (req, res) => {
    const client = await pool.connect();
    try {
        const {
            first_name,
            last_name,
            date_of_birth,
            gender,
            relationship,
            cin
        } = req.body;

        // Validation
        if (!first_name || !last_name || !date_of_birth || !gender || !relationship) {
            return res.status(400).json({ error: 'Données manquantes' });
        }

        // Insérer le membre de famille
        const memberResult = await client.query(
            `INSERT INTO vaccination.family_members 
             (user_id, first_name, last_name, date_of_birth, gender, relationship, cin)
             VALUES ($1, $2, $3, $4, $5, $6, $7)
             RETURNING *`,
            [req.user.userId, first_name, last_name, date_of_birth, gender, relationship, cin]
        );

        const member = memberResult.rows[0];

        // Créer un carnet de vaccination pour ce membre
        await client.query(
            'SELECT vaccination.create_vaccination_card(NULL, $1)',
            [member.id]
        );

        res.status(201).json({
            message: 'Membre de famille ajouté avec succès',
            member
        });

    } catch (error) {
        logger.error('Erreur lors de l\'ajout du membre de famille:', error);
        res.status(500).json({ error: 'Erreur interne du serveur' });
    } finally {
        client.release();
    }
});

// Lister les membres de famille
app.get('/api/family/members', authenticateToken, async (req, res) => {
    const client = await pool.connect();
    try {
        const result = await client.query(
            `SELECT fm.*, vc.card_number, vc.qr_code
             FROM vaccination.family_members fm
             LEFT JOIN vaccination.vaccination_cards vc ON fm.id = vc.family_member_id
             WHERE fm.user_id = $1 AND fm.is_active = true
             ORDER BY fm.created_at DESC`,
            [req.user.userId]
        );

        res.json({ members: result.rows });

    } catch (error) {
        logger.error('Erreur lors de la récupération des membres de famille:', error);
        res.status(500).json({ error: 'Erreur interne du serveur' });
    } finally {
        client.release();
    }
});

// Supprimer un membre de famille
app.delete('/api/family/member/:id', authenticateToken, async (req, res) => {
    const client = await pool.connect();
    try {
        const { id } = req.params;

        // Vérifier que le membre appartient à l'utilisateur
        const memberResult = await client.query(
            'SELECT id FROM vaccination.family_members WHERE id = $1 AND user_id = $2',
            [id, req.user.userId]
        );

        if (memberResult.rows.length === 0) {
            return res.status(404).json({ error: 'Membre de famille non trouvé' });
        }

        // Désactiver le membre (soft delete)
        await client.query(
            'UPDATE vaccination.family_members SET is_active = false WHERE id = $1',
            [id]
        );

        res.json({ message: 'Membre de famille supprimé avec succès' });

    } catch (error) {
        logger.error('Erreur lors de la suppression du membre de famille:', error);
        res.status(500).json({ error: 'Erreur interne du serveur' });
    } finally {
        client.release();
    }
});

// =============================
// APIS CARNETS DE VACCINATION
// =============================

// Obtenir le carnet de vaccination
app.get('/api/vaccination/card/:cardId?', authenticateToken, async (req, res) => {
    const client = await pool.connect();
    try {
        const { cardId } = req.params;
        let query;
        let params;

        if (cardId) {
            // Carnet spécifique
            query = `
                SELECT vc.*, 
                       COALESCE(u.first_name, fm.first_name) as first_name,
                       COALESCE(u.last_name, fm.last_name) as last_name,
                       COALESCE(u.date_of_birth, fm.date_of_birth) as date_of_birth,
                       COALESCE(u.gender, fm.gender) as gender
                FROM vaccination.vaccination_cards vc
                LEFT JOIN vaccination.users u ON vc.user_id = u.id
                LEFT JOIN vaccination.family_members fm ON vc.family_member_id = fm.id
                WHERE vc.id = $1 AND vc.is_active = true
            `;
            params = [cardId];
        } else {
            // Carnet principal de l'utilisateur
            query = `
                SELECT vc.*, u.first_name, u.last_name, u.date_of_birth, u.gender
                FROM vaccination.vaccination_cards vc
                JOIN vaccination.users u ON vc.user_id = u.id
                WHERE vc.user_id = $1 AND vc.is_active = true
            `;
            params = [req.user.userId];
        }

        const cardResult = await client.query(query, params);

        if (cardResult.rows.length === 0) {
            return res.status(404).json({ error: 'Carnet de vaccination non trouvé' });
        }

        const card = cardResult.rows[0];

        // Récupérer les vaccinations
        const vaccinationsResult = await client.query(
            `SELECT v.*, vac.vaccine_name, vac.manufacturer, hc.center_name
             FROM vaccination.vaccinations v
             JOIN vaccination.vaccines vac ON v.vaccine_id = vac.id
             JOIN vaccination.health_centers hc ON v.health_center_id = hc.id
             WHERE v.vaccination_card_id = $1
             ORDER BY v.vaccination_date DESC`,
            [card.id]
        );

        // Récupérer les vaccinations dues
        const dueVaccinationsResult = await client.query(
            'SELECT * FROM vaccination.get_due_vaccinations($1)',
            [card.id]
        );

        res.json({
            card,
            vaccinations: vaccinationsResult.rows,
            due_vaccinations: dueVaccinationsResult.rows
        });

    } catch (error) {
        logger.error('Erreur lors de la récupération du carnet:', error);
        res.status(500).json({ error: 'Erreur interne du serveur' });
    } finally {
        client.release();
    }
});

// Générer un QR code pour le carnet
app.get('/api/vaccination/qr-code/:cardId', authenticateToken, async (req, res) => {
    const client = await pool.connect();
    try {
        const { cardId } = req.params;

        const cardResult = await client.query(
            'SELECT qr_code FROM vaccination.vaccination_cards WHERE id = $1',
            [cardId]
        );

        if (cardResult.rows.length === 0) {
            return res.status(404).json({ error: 'Carnet non trouvé' });
        }

        const qrCode = cardResult.rows[0].qr_code;
        const qrCodeImage = await QRCode.toDataURL(qrCode);

        res.json({ qr_code: qrCodeImage });

    } catch (error) {
        logger.error('Erreur lors de la génération du QR code:', error);
        res.status(500).json({ error: 'Erreur interne du serveur' });
    } finally {
        client.release();
    }
});

// =============================
// APIS VACCINATION (PROFESSIONNELS)
// =============================

// Enregistrer une vaccination
app.post('/api/vaccination/record', authenticateToken, authorizeRole(['HEALTH_PROF', 'COMMUNITY_AGENT']), async (req, res) => {
    const client = await pool.connect();
    try {
        const {
            card_id,
            vaccine_id,
            health_center_id,
            vaccination_date,
            dose_number,
            batch_number,
            expiry_date,
            notes
        } = req.body;

        // Validation
        if (!card_id || !vaccine_id || !health_center_id || !vaccination_date || !dose_number) {
            return res.status(400).json({ error: 'Données manquantes' });
        }

        // Enregistrer la vaccination
        const vaccinationResult = await client.query(
            'SELECT vaccination.record_vaccination($1, $2, $3, $4, $5, $6, $7, $8, $9)',
            [card_id, vaccine_id, health_center_id, req.user.userId, vaccination_date, dose_number, batch_number, expiry_date, notes]
        );

        const vaccinationId = vaccinationResult.rows[0].record_vaccination;

        res.status(201).json({
            message: 'Vaccination enregistrée avec succès',
            vaccination_id: vaccinationId
        });

    } catch (error) {
        logger.error('Erreur lors de l\'enregistrement de la vaccination:', error);
        if (error.message.includes('Stock insuffisant')) {
            return res.status(400).json({ error: 'Stock insuffisant pour ce vaccin' });
        }
        res.status(500).json({ error: 'Erreur interne du serveur' });
    } finally {
        client.release();
    }
});

// Rechercher un patient par QR code
app.get('/api/vaccination/patient/:qrCode', authenticateToken, authorizeRole(['HEALTH_PROF', 'COMMUNITY_AGENT']), async (req, res) => {
    const client = await pool.connect();
    try {
        const { qrCode } = req.params;

        const result = await client.query(
            `SELECT vc.*, 
                    COALESCE(u.first_name, fm.first_name) as first_name,
                    COALESCE(u.last_name, fm.last_name) as last_name,
                    COALESCE(u.date_of_birth, fm.date_of_birth) as date_of_birth,
                    COALESCE(u.gender, fm.gender) as gender,
                    COALESCE(u.phone, (SELECT phone FROM vaccination.users WHERE id = fm.user_id)) as phone
             FROM vaccination.vaccination_cards vc
             LEFT JOIN vaccination.users u ON vc.user_id = u.id
             LEFT JOIN vaccination.family_members fm ON vc.family_member_id = fm.id
             WHERE vc.qr_code = $1 AND vc.is_active = true`,
            [qrCode]
        );

        if (result.rows.length === 0) {
            return res.status(404).json({ error: 'Patient non trouvé' });
        }

        res.json({ patient: result.rows[0] });

    } catch (error) {
        logger.error('Erreur lors de la recherche du patient:', error);
        res.status(500).json({ error: 'Erreur interne du serveur' });
    } finally {
        client.release();
    }
});

// =============================
// APIS STOCKS
// =============================

// Obtenir les stocks d'un centre
app.get('/api/stocks/center/:centerId', authenticateToken, authorizeRole(['HEALTH_PROF', 'HEALTH_AUTHORITY']), async (req, res) => {
    const client = await pool.connect();
    try {
        const { centerId } = req.params;

        const result = await client.query(
            `SELECT vs.*, v.vaccine_name, v.manufacturer
             FROM vaccination.vaccine_stocks vs
             JOIN vaccination.vaccines v ON vs.vaccine_id = v.id
             WHERE vs.health_center_id = $1`,
            [centerId]
        );

        res.json({ stocks: result.rows });

    } catch (error) {
        logger.error('Erreur lors de la récupération des stocks:', error);
        res.status(500).json({ error: 'Erreur interne du serveur' });
    } finally {
        client.release();
    }
});

// =============================
// EXPORT SERVEUR
// =============================

const PORT = process.env.PORT || 3000;
app.listen(PORT, () => {
    console.log(`Serveur API Vaccination en cours d'exécution sur le port ${PORT}`);
});

