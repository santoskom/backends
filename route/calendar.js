const express = require('express');
const router = express.Router();
const { pool } = require('../db');
const authenticateToken = require('../middleware/authenticateToken');
const { v4: uuidv4 } = require('uuid');

// Helper pour calculer l'âge
const calculateAge = (birthDate) => {
  const today = new Date();
  const birth = new Date(birthDate);
  let age = today.getFullYear() - birth.getFullYear();
  const monthDiff = today.getMonth() - birth.getMonth();
  if (monthDiff < 0 || (monthDiff === 0 && today.getDate() < birth.getDate())) age--;
  return age;
};

router.get('/test', (req, res) => {
  res.json({ message: 'API calendar OK' });
});
// GET /api/calendar/events - Récupère tous les événements
router.get('/events', authenticateToken, async (req, res) => {
  try {
    // Récupère à la fois les rendez-vous individuels et les campagnes
    const query = `
      (
       SELECT 
  v.id,
  'individual' AS type,
  CONCAT(u.first_name, ' ', u.last_name) AS title,
  NULL AS description,
  v.vaccination_date AS date,
  vac.vaccine_name AS vaccine, -- ✅ correction ici
  NULL AS location,
  hc.center_name AS health_center,
  v.status,
  v.dose_number,
  v.batch_number,
  v.notes,
  v.is_verified,
  v.verification_date,
  CASE 
    WHEN v.vaccination_date < CURRENT_DATE THEN 'overdue'
    ELSE 'scheduled'
  END AS display_status
FROM vaccination.vaccinations v
JOIN vaccination.vaccines vac ON v.vaccine_id = vac.id -- ✅ ajouté
JOIN vaccination.vaccination_cards vc ON v.vaccination_card_id = vc.id
LEFT JOIN vaccination.users u ON vc.user_id = u.id OR vc.family_member_id IN (
  SELECT id FROM vaccination.family_members WHERE user_id = u.id
)
LEFT JOIN vaccination.health_centers hc ON v.health_center_id = hc.id
      )
      UNION ALL
      (
        SELECT 
          c.id,
          'campaign' AS type,
          c.title,
          c.description,
          c.start_date AS date,
          NULL AS vaccine,
          c.location,
          NULL AS health_center,
          c.status,
          NULL AS dose_number,
          NULL AS batch_number,
          NULL AS notes,
          NULL AS is_verified,
          NULL AS verification_date,
          CASE 
            WHEN c.end_date < CURRENT_DATE THEN 'completed'
            WHEN c.start_date > CURRENT_DATE THEN 'scheduled'
            ELSE 'active'
          END AS display_status
        FROM vaccination.campaigns c
      )
      ORDER BY date DESC
    `;

    const { rows } = await pool.query(query);

    // Formater pour le frontend
    const formattedEvents = rows.map(event => ({
      id: event.id,
      type: event.type,
      title: event.title,
      description: event.description,
      date: event.date,
      time: event.time || '08:00', // Valeur par défaut
      vaccine: event.vaccine,
      location: event.location,
      healthCenter: event.health_center,
      status: event.display_status,
      ...(event.type === 'individual' ? {
        patientName: event.title,
        doseNumber: event.dose_number,
        batchNumber: event.batch_number
      } : {
        targetPopulation: event.description?.match(/population cible: (.*)/i)?.[1] || ''
      })
    }));

    res.json({ success: true, data: formattedEvents });
  } catch (error) {
    console.error(error);
    res.status(500).json({ success: false, error: 'Erreur serveur' });
  }
});

// GET /api/calendar/stats - Statistiques pour le dashboard
// GET /api/calendar/stats - Statistiques pour le dashboard
router.get('/stats', authenticateToken, async (req, res) => {
  try {
    const today = new Date().toISOString().split('T')[0];

    const queries = {
      today: `
        SELECT COUNT(*) FROM vaccination.vaccinations 
        WHERE vaccination_date = $1
      `,
      week: `
        SELECT COUNT(*) FROM vaccination.vaccinations 
        WHERE vaccination_date BETWEEN $1 AND (DATE($1) + INTERVAL '7 days')
      `,
      overdue: `
        SELECT COUNT(*) FROM vaccination.vaccinations 
        WHERE vaccination_date < $1 AND status != 'completed'
      `,
      campaigns: `
        SELECT COUNT(*) FROM vaccination.campaigns 
        WHERE end_date >= $1 OR status = 'active'
      `
    };

    const results = {};
    for (const [key, sql] of Object.entries(queries)) {
      const { rows } = await pool.query(sql, [today]);
      results[key] = parseInt(rows[0].count);
    }

    res.json({ success: true, data: results });
  } catch (error) {
    console.error(error);
    res.status(500).json({ success: false, error: 'Erreur serveur' });
  }
});


// POST /api/calendar/appointments - Créer un nouveau rendez-vous
router.post('/appointments', authenticateToken, async (req, res) => {
  console.log("POST /appointments reçu", req.body);
  const { patientId, vaccineId, date, time, healthCenterId, notes } = req.body;

  try {
    // 1. Vérifier que le patient existe
    const patientQuery = `
      SELECT id FROM vaccination.vaccination_cards 
      WHERE user_id = $1 OR family_member_id = $1
    `;
    const { rows: [card] } = await pool.query(patientQuery, [patientId]);

    if (!card) {
      return res.status(404).json({ success: false, error: 'Patient non trouvé' });
    }

    // 2. Créer le rendez-vous
    const insertQuery = `
      INSERT INTO vaccination.vaccinations (
        id, vaccination_card_id, vaccine_id, health_center_id,
        vaccination_date, vaccination_time, notes,dose_number, status
      ) VALUES ($1, $2, $3, $4, $5, $6, $7,$8, 'scheduled')
      RETURNING *
    `;
    const newAppointment = await pool.query(insertQuery, [
      uuidv4(),
      card.id,
      vaccineId,
      healthCenterId,
      date,
      time,
      notes,
      doseNumber
    ]);

    // 3. Programmer un rappel (optionnel)
    if (req.body.setReminder) {
      await pool.query(
        `INSERT INTO vaccination.reminders (vaccination_id, reminder_date) 
         VALUES ($1, (DATE($2) - INTERVAL '2 days'))`,
        [newAppointment.rows[0].id, date]
      );
    }

    res.json({ success: true, data: newAppointment.rows[0] });
  } catch (error) {
    console.error(error);
    res.status(500).json({ success: false, error: 'Échec de la création' });
  }
});

// GET /api/calendar/reminders - Récupère les rappels à venir
// GET /api/calendar/reminders - Récupère les rappels à venir
router.get('/reminders', authenticateToken, async (req, res) => {
  try {
    const query = `
      SELECT 
        r.id,
        v.vaccination_date,
        v.vaccination_time,
        vac.vaccine_name,
        COALESCE(CONCAT(u.first_name, ' ', u.last_name), CONCAT(fm.first_name, ' ', fm.last_name)) AS patient_name,
        hc.center_name,
        DATE(v.vaccination_date) - CURRENT_DATE AS days_until
      FROM vaccination.reminders r
      JOIN vaccination.vaccinations v ON r.vaccination_id = v.id
      JOIN vaccination.vaccines vac ON v.vaccine_id = vac.id
      JOIN vaccination.vaccination_cards vc ON v.vaccination_card_id = vc.id
      LEFT JOIN vaccination.users u ON vc.user_id = u.id
      LEFT JOIN vaccination.family_members fm ON vc.family_member_id = fm.id
      JOIN vaccination.health_centers hc ON v.health_center_id = hc.id
      WHERE r.is_sent = FALSE
      AND v.vaccination_date >= CURRENT_DATE
      ORDER BY days_until ASC
      LIMIT 10
    `;

    const { rows } = await pool.query(query);
    res.json({ success: true, data: rows });
  } catch (error) {
    console.error(error);
    res.status(500).json({ success: false, error: 'Erreur serveur' });
  }
});


// Programme EPI (statique)
router.get('/epi-program', authenticateToken, async (req, res) => {
  try {
    const result = await pool.query(`
      SELECT id, vaccine_name, vaccine_code, dose_number
      FROM vaccination.vaccines
      WHERE is_active = TRUE
      ORDER BY id
    `);

    const epiProgram = result.rows.map(vaccine => ({
      id: vaccine.id, // 🔹 Ajouté ici
      vaccine_name: vaccine.vaccine_name,
      code: vaccine.vaccine_code,
      doses: vaccine.dose_number || 1,
      schedule: 'À définir',
      color: 'bg-gray-500'
    }));

    res.json({ success: true, data: epiProgram });
  } catch (err) {
    console.error(err);
    res.status(500).json({ success: false, error: 'Erreur serveur' });
  }
});

 
// Gestion des campagnes
router.post('/campaigns', authenticateToken, async (req, res) => {
  const { title, description, startDate, endDate, location, targetPopulation } = req.body;

  try {
    const { rows } = await pool.query(
      `INSERT INTO vaccination.campaigns (
        id, title, description, start_date, end_date, 
        location, target_population, status
      ) VALUES ($1, $2, $3, $4, $5, $6, $7, 'scheduled')
      RETURNING *`,
      [uuidv4(), title, description, startDate, endDate, location, targetPopulation]
    );

    res.json({ success: true, data: rows[0] });
  } catch (error) {
    res.status(500).json({ success: false, error: 'Échec de la création' });
  }
});

module.exports = router;