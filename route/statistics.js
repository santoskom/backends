// backend/api/statistics_citizen.js
const express = require('express');
const router = express.Router();
const { pool } = require("../db");

// Endpoint statistique du citoyen (nécessite son user_id dans les headers)
router.get('/citizen-dashboard/:userId', async (req, res) => {
  const { userId } = req.params;

  try {
    // Nombre total de vaccins reçus (user ou membres)
    const { rows: totalVaccinations } = await pool.query(`
      SELECT COUNT(*) AS total
      FROM vaccination.vaccinations vac
      JOIN vaccination.vaccination_cards vc ON vac.vaccination_card_id = vc.id
      WHERE vc.user_id = $1 OR vc.family_member_id IN (
        SELECT id FROM vaccination.family_members WHERE user_id = $1
      )
    `, [userId]);

    // Nombre total attendu (en se basant sur le calendrier vaccinal + âge) → Simplifié
    const { rows: totalExpected } = await pool.query(`
      SELECT COUNT(*) AS expected
      FROM vaccination.vaccination_cards vc
      JOIN vaccination.get_due_vaccinations(vc.id) AS due(vaccine_name, due_date, dose_number)
        ON TRUE
      WHERE vc.user_id = $1 OR vc.family_member_id IN (
        SELECT id FROM vaccination.family_members WHERE user_id = $1
      )
    `, [userId]);

    // Prochain rappel (dans reminders)
    const { rows: nextReminder } = await pool.query(`
      SELECT reminder_date
      FROM vaccination.reminders
      WHERE (vaccination_card_id IN (
        SELECT id FROM vaccination.vaccination_cards
        WHERE user_id = $1 OR family_member_id IN (
          SELECT id FROM vaccination.family_members WHERE user_id = $1
        )
      )) AND is_sent = FALSE
      ORDER BY reminder_date ASC
      LIMIT 1
    `, [userId]);

    const total = parseInt(totalVaccinations[0]?.total || 0);
    const expected = parseInt(totalExpected[0]?.expected || 1); // éviter division par 0
    const percent = Math.round((total * 100) / expected);
    const reminderIn = nextReminder[0]
      ? Math.ceil((new Date(nextReminder[0].reminder_date) - new Date()) / (1000 * 3600 * 24))
      : null;

    res.json({
      totalVaccins: total,
      pourcentage: percent,
      prochainRappel: reminderIn,
    });
  } catch (err) {
    console.error('Erreur statistique citoyen:', err);
    res.status(500).json({ error: 'Erreur serveur' });
  }
});

module.exports = router;
