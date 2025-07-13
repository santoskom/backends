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

// 🔍 Recherche de patients
router.get('/patients/search', authenticateToken, async (req, res) => {
  const { query } = req.query;
  try {
    const result = await pool.query(
      `SELECT u.id, u.first_name, u.last_name, u.date_of_birth AS birthDate, 
              u.gender, u.cin AS nationalId, u.phone,
              (SELECT vaccine_name FROM vaccination.vaccines v
               JOIN vaccination.vaccinations vv ON vv.vaccine_id = v.id
               WHERE vv.vaccination_card_id = vc.id 
               ORDER BY vaccination_date DESC LIMIT 1) AS lastVaccine
       FROM vaccination.users u
       LEFT JOIN vaccination.vaccination_cards vc ON u.id = vc.user_id
       WHERE u.cin ILIKE $1 OR u.phone ILIKE $1 OR u.first_name ILIKE $1 OR u.last_name ILIKE $1
       LIMIT 10`,
      [`%${query}%`]
    );
    res.json(result.rows);
  } catch (error) {
    console.error(error);
    res.status(500).json({ error: 'Erreur lors de la recherche' });
  }
});

// 📡 Scan QR
router.get('/patients/qr/:qrCode', authenticateToken, async (req, res) => {
  const { qrCode } = req.params;
  try {
    const result = await pool.query(
      `SELECT vc.id as card_id, u.id, u.first_name, u.last_name, u.date_of_birth AS birthDate, 
              u.gender, u.cin AS nationalId, u.phone,
              (SELECT vaccine_name FROM vaccination.vaccines v
               JOIN vaccination.vaccinations vv ON vv.vaccine_id = v.id
               WHERE vv.vaccination_card_id = vc.id 
               ORDER BY vaccination_date DESC LIMIT 1) AS lastVaccine
       FROM vaccination.vaccination_cards vc
       LEFT JOIN vaccination.users u ON vc.user_id = u.id
       WHERE vc.qr_code = $1`,
      [qrCode]
    );
    if (result.rows.length === 0) return res.status(404).json({ error: 'Carnet non trouvé' });
    res.json(result.rows[0]);
  } catch (error) {
    console.error(error);
    res.status(500).json({ error: 'Erreur lors de la recherche QR' });
  }
});

// ✅ Liste des vaccins actifs
router.get('/vaccines', authenticateToken, async (req, res) => {
  try {
    const result = await pool.query(
      `SELECT id, vaccine_name AS name, description FROM vaccination.vaccines WHERE is_active = TRUE`
    );
    res.json(result.rows);
  } catch (error) {
    res.status(500).json({ error: 'Erreur chargement vaccins' });
  }
});

// 📦 Lots de vaccins
router.get('/vaccine-lots', authenticateToken, async (req, res) => {
  const { vaccineId } = req.query;
  try {
    const result = await pool.query(
      `SELECT id, batch_number AS numero, expiry_date AS date_expiration, vaccine_id AS type_vaccin_id
       FROM vaccination.vaccine_stocks
       WHERE vaccine_id = $1 AND expiry_date > CURRENT_DATE AND quantity > 0
       ORDER BY expiry_date ASC`,
      [vaccineId]
    );
    res.json(result.rows);
  } catch (error) {
    res.status(500).json({ error: 'Erreur chargement lots' });
  }
});

// 🏥 Centres de santé
router.get('/hospitals', authenticateToken, async (_req, res) => {
  try {
    const result = await pool.query(
      `SELECT id, center_name AS name FROM vaccination.health_centers WHERE is_active = TRUE`
    );
    res.json(result.rows);
  } catch (error) {
    res.status(500).json({ error: 'Erreur chargement hôpitaux' });
  }
});

// 👩‍⚕️ Professionnels de santé
router.get('/professionals', authenticateToken, async (_req, res) => {
  try {
    const result = await pool.query(
      `SELECT id, first_name || ' ' || last_name AS name
       FROM vaccination.users 
       WHERE user_type_id = (SELECT id FROM vaccination.user_types WHERE type_code = 'HEALTH_PROF')`
    );
    res.json(result.rows);
  } catch (error) {
    res.status(500).json({ error: 'Erreur chargement professionnels' });
  }
});

// 💉 Enregistrement de la vaccination
router.post('/vaccinate', authenticateToken, async (req, res) => {
    const {
      citoyen_id, type_vaccin_id, lot_vaccin_id, hopital_id, professionnel_id,
      date_vaccination, heure_vaccination, dose_numero, poids_enfant, bras_vaccine,
      statut, observations
    } = req.body;
  
    try {
      await pool.query('BEGIN');
  
      // Récupération du carnet
      const cardResult = await pool.query(
        `SELECT id FROM vaccination.vaccination_cards 
         WHERE user_id = $1 OR family_member_id = $1 LIMIT 1`,
        [citoyen_id]
      );
      if (cardResult.rows.length === 0) throw new Error('Carnet non trouvé');
      const vaccination_card_id = cardResult.rows[0].id;
  
      // Insertion vaccination
      const insertResult = await pool.query(
        `INSERT INTO vaccination.vaccinations (
          vaccination_card_id, vaccine_id, health_center_id, administered_by,
          vaccination_date, vaccination_time, dose_number, vaccine_stock_id,
          child_weight, arm_vaccinated, status, notes
        ) VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12)
        RETURNING id`,
        [
          vaccination_card_id, type_vaccin_id, hopital_id, professionnel_id,
          date_vaccination, heure_vaccination, dose_numero, lot_vaccin_id,
          poids_enfant, bras_vaccine, statut, observations
        ]
      );
  
      // Mise à jour du stock
      await pool.query(
        `UPDATE vaccination.vaccine_stocks 
         SET quantity = quantity - 1 
         WHERE id = $1`,
        [lot_vaccin_id]
      );
  
      await pool.query('COMMIT');
      res.status(201).json({ success: true, vaccinationId: insertResult.rows[0].id });
    } catch (error) {
      await pool.query('ROLLBACK');
      console.error(error);
      res.status(500).json({ error: 'Erreur enregistrement vaccination', details: error.message });
    }
  });
  

module.exports = router;
