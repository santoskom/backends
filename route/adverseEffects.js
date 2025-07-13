const express = require('express');
const router = express.Router();
const { Pool } = require('pg');
const authenticateToken = require('../middleware/authenticateToken');

const pool = new Pool({
  host: process.env.DB_HOST || 'localhost',
  port: process.env.DB_PORT || 5432,
  database: process.env.DB_NAME || 'vaccination',
  user: process.env.DB_USER || 'postgres',
  password: process.env.DB_PASSWORD || 'password',
  ssl: false,
});

const allowedSeverities = ['mild', 'moderate', 'severe'];

router.post('/', authenticateToken, async (req, res) => {
    const {
        vaccinationId,
        effectDescription,
        severity,
        onsetDate,
        resolutionDate,
        actionTaken,
        isSerious
    } = req.body;

    // 1. Validation des données
    if (!allowedSeverities.includes(severity)) {
        return res.status(400).json({
            success: false,
            message: `Gravité invalide. Valeurs autorisées: ${allowedSeverities.join(', ')}`
        });
    }

    // 2. Vérification des champs obligatoires
    const requiredFields = ['vaccinationId', 'effectDescription', 'severity', 'onsetDate'];
    const missingFields = requiredFields.filter(field => !req.body[field]);
    
    if (missingFields.length > 0) {
        return res.status(400).json({
            success: false,
            message: `Champs manquants: ${missingFields.join(', ')}`
        });
    }

    try {
        // 3. Formatage des dates
        const formatDate = (dateString) => {
            if (!dateString) return null;
            return new Date(dateString).toISOString();
        };

        const query = `
            INSERT INTO vaccination.side_effects (
                vaccination_id,
                reported_by,
                effect_description,
                severity,
                onset_date,
                resolution_date,
                action_taken,
                is_serious
            ) VALUES ($1, $2, $3, $4, $5, $6, $7, $8)
            RETURNING *
        `;

        const values = [
            vaccinationId,
            req.user.id, // UUID de l'utilisateur authentifié
            effectDescription,
            severity,
            formatDate(onsetDate),
            formatDate(resolutionDate), // Peut être null
            actionTaken || null, // Permet les valeurs nulles
            isSerious || false // Valeur par défaut false
        ];

        // 4. Exécution de la requête
        const result = await pool.query(query, values);

        // 5. Réponse réussie
        return res.status(201).json({
            success: true,
            message: 'Effet indésirable enregistré avec succès',
            data: result.rows[0]
        });

    } catch (error) {
        console.error('Erreur:', error);
        
        // 6. Gestion des erreurs spécifiques
        if (error.code === '23503') { // Violation de clé étrangère
            return res.status(400).json({
                success: false,
                message: 'Vaccination ID invalide'
            });
        }

        return res.status(500).json({
            success: false,
            message: 'Erreur interne du serveur',
            error: error.message
        });
    }
});


// ✅ GET /api/adverse-effects - Liste des effets indésirables
router.get('/', authenticateToken, async (req, res) => {
  try {
    const query = `
      SELECT se.*, 
        c.first_name || ' ' || c.last_name AS citoyen_nom,
        v.vaccine_id,
        v.date_administration
      FROM vaccination.side_effects se
      JOIN vaccination.vaccinations v ON se.vaccination_id = v.id
      JOIN vaccination.citoyens c ON v.citoyen_id = c.id
      ORDER BY se.created_at DESC
    `;

    const result = await pool.query(query);

    res.json({
      success: true,
      data: result.rows
    });

  } catch (error) {
    console.error('Erreur lors de la récupération des effets indésirables:', error);
    res.status(500).json({
      success: false,
      message: 'Erreur lors de la récupération',
      error: error.message
    });
  }
});


// GET /api/adverse-effects/vaccinations - Récupérer la liste des vaccinations
router.get('/vaccinations', authenticateToken, async (req, res) => {
    try {
      const query = `
        SELECT 
          v.id, 
          v.vaccine_id, 
          COALESCE(u.first_name || ' ' || u.last_name, fm.first_name || ' ' || fm.last_name) AS citoyen_nom,
          v.vaccination_date
        FROM vaccination.vaccinations v
        JOIN vaccination.vaccination_cards vc ON v.vaccination_card_id = vc.id
        LEFT JOIN vaccination.users u ON vc.user_id = u.id
        LEFT JOIN vaccination.family_members fm ON vc.family_member_id = fm.id
        ORDER BY v.vaccination_date DESC
      `;
  
      const result = await pool.query(query);
      res.json({ success: true, data: result.rows });
    } catch (error) {
      console.error("Erreur lors de la récupération des vaccinations :", error);
      res.status(500).json({ success: false, message: "Erreur serveur", error: error.message });
    }
  });
  
  

module.exports = router;
