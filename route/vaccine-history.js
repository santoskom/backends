const express = require('express');
const router = express.Router();
const pool = require('../db');
const authenticateToken = require('../middleware/authenticateToken');

// Helper functions
const isValidUUID = (uuid) => {
  return /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(uuid);
};

const calculateAge = (birthDate) => {
  const today = new Date();
  const birth = new Date(birthDate);
  let age = today.getFullYear() - birth.getFullYear();
  const monthDiff = today.getMonth() - birth.getMonth();
  
  if (monthDiff < 0 || (monthDiff === 0 && today.getDate() < birth.getDate())) {
    age--;
  }

  return age;
};

// GET /api/vaccine-history/:patientId
router.get('/vaccine-history/:patientId', authenticateToken, async (req, res) => {
    console.log('✅ Requête reçue sur /vaccine-history/:patientId');
  const { patientId } = req.params;
  const { page = 1, limit = 10 } = req.query;
  const offset = (page - 1) * limit;

  // 1. Validate UUID
  if (!isValidUUID(patientId)) {
    return res.status(400).json({ 
      success: false,
      error: "Format d'ID patient invalide" 
    });
  }

  try {
    // 2. Find patient (user or family member)
    const patientQuery = `
      SELECT 'user' AS type, id, first_name, last_name, date_of_birth, gender, cin
      FROM vaccination.users WHERE id = $1 AND is_active = TRUE
      UNION ALL
      SELECT 'family' AS type, id, first_name, last_name, date_of_birth, gender, cin
      FROM vaccination.family_members WHERE id = $1 AND is_active = TRUE`;
    
    const { rows: [patient] } = await pool.query(patientQuery, [patientId]);
    
    if (!patient) {
      return res.status(404).json({ 
        success: false,
        error: "Patient non trouvé ou compte désactivé" 
      });
    }

    // 3. Get vaccination card
    const { rows: [card] } = await pool.query(
      `SELECT id, qr_code FROM vaccination.vaccination_cards 
       WHERE ${patient.type === 'user' ? 'user_id' : 'family_member_id'} = $1`,
      [patient.id]
    );

    if (!card) {
      return res.status(404).json({ 
        success: false,
        error: "Carnet de vaccination introuvable" 
      });
    }

    // 4. Get vaccine history (paginated)
    const historyQuery = `
      SELECT 
        v.id,
        vac.vaccine_name,
        v.vaccination_date,
        v.dose_number,
        v.batch_number,
        v.expiry_date,
        CONCAT(u.first_name, ' ', u.last_name) AS administered_by,
        hc.center_name AS health_center,
        v.notes,
        v.is_verified,
        v.verification_date
      FROM vaccination.vaccinations v
      JOIN vaccination.vaccines vac ON v.vaccine_id = vac.id
      LEFT JOIN vaccination.users u ON v.administered_by = u.id
      LEFT JOIN vaccination.health_centers hc ON v.health_center_id = hc.id
      WHERE v.vaccination_card_id = $1
      ORDER BY v.vaccination_date DESC
      LIMIT $2 OFFSET $3`;

    const { rows: vaccines } = await pool.query(historyQuery, [card.id, limit, offset]);

    // 5. Get total count for pagination
    const { rows: [{ count }] } = await pool.query(
      `SELECT COUNT(*) FROM vaccination.vaccinations WHERE vaccination_card_id = $1`,
      [card.id]
    );

    // 6. Prepare response
    const response = {
      success: true,
      data: {
        patient: {
          id: patient.id,
          type: patient.type,
          fullName: `${patient.first_name} ${patient.last_name}`,
          cin: patient.cin,
          gender: patient.gender,
          birthDate: patient.date_of_birth,
          age: calculateAge(patient.date_of_birth),
          qrCode: card.qr_code
        },
        vaccines,
        pagination: {
          page: parseInt(page),
          limit: parseInt(limit),
          totalItems: parseInt(count),
          totalPages: Math.ceil(count / limit)
        }
      }
    };

    console.log('✔️ Données retournées par /vaccine-history/:patientId:', JSON.stringify(response, null, 2));

    res.json(response);
    

  } catch (error) {
    console.error('Erreur:', error);
    res.status(500).json({ 
      success: false,
      error: 'Erreur serveur interne',
      details: process.env.NODE_ENV === 'development' ? error.message : undefined
    });
  }
});

module.exports = router;