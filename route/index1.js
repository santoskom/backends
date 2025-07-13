const express = require("express");
const router = express.Router();
const { pool } = require("../db");
const authenticateToken = require("../middleware/authenticateToken");

/**
 * @route GET /api/statistics/upcoming
 * @description Récupère les vaccinations à venir pour l'utilisateur connecté
 * @access Privé
 */
router.get('/upcoming', authenticateToken, async (req, res) => {
  try {
    // Récupérer tous les carnets de l'utilisateur
    const cards = await pool.query(
      `SELECT id FROM vaccination.vaccination_cards 
       WHERE user_id = $1 OR family_member_id IN (
         SELECT id FROM vaccination.family_members WHERE user_id = $1
       )`,
      [req.user.userId]
    );

    if (cards.rows.length === 0) {
      return res.json([]);
    }

    // Pour chaque carnet, récupérer les vaccinations à venir
    const upcomingVaccines = [];
    
    for (const card of cards.rows) {
      const dueVaccines = await pool.query(
        `SELECT 
           v.vaccine_name as name,
           (fm.date_of_birth + vs.age_in_days)::DATE as due_date,
           fm.first_name || ' ' || fm.last_name as person,
           CASE 
             WHEN (fm.date_of_birth + vs.age_in_days)::DATE < CURRENT_DATE THEN 'overdue'
             ELSE 'pending'
           END as status,
           (fm.date_of_birth + vs.age_in_days)::DATE - CURRENT_DATE as days_until,
           v.id as vaccine_id,
           vc.id as card_id
         FROM vaccination.get_due_vaccinations($1) vs
         JOIN vaccination.vaccines v ON vs.vaccine_id = v.id
         JOIN vaccination.vaccination_cards vc ON vc.id = $1
         LEFT JOIN vaccination.users u ON vc.user_id = u.id
         LEFT JOIN vaccination.family_members fm ON vc.family_member_id = fm.id
         WHERE v.is_active = TRUE
         ORDER BY due_date`,
        [card.id]
      );

      upcomingVaccines.push(...dueVaccines.rows);
    }

    // Ajouter aussi les vaccinations déjà programmées mais pas encore effectuées
    const scheduledVaccines = await pool.query(
      `SELECT 
         v.vaccine_name as name,
         r.reminder_date as due_date,
         COALESCE(fm.first_name || ' ' || fm.last_name, u.first_name || ' ' || u.last_name) as person,
         'pending' as status,
         r.reminder_date - CURRENT_DATE as days_until,
         v.id as vaccine_id,
         vc.id as card_id
       FROM vaccination.reminders r
       JOIN vaccination.vaccines v ON r.vaccine_id = v.id
       JOIN vaccination.vaccination_cards vc ON r.vaccination_card_id = vc.id
       LEFT JOIN vaccination.users u ON vc.user_id = u.id
       LEFT JOIN vaccination.family_members fm ON vc.family_member_id = fm.id
       WHERE (vc.user_id = $1 OR vc.family_member_id IN (
         SELECT id FROM vaccination.family_members WHERE user_id = $1
       ))
       AND r.reminder_date >= CURRENT_DATE
       AND NOT EXISTS (
         SELECT 1 FROM vaccination.vaccinations vac 
         WHERE vac.vaccination_card_id = vc.id 
         AND vac.vaccine_id = v.id
       )
       ORDER BY r.reminder_date`,
      [req.user.userId]
    );

    // Fusionner et trier les résultats
    const allVaccines = [...upcomingVaccines, ...scheduledVaccines.rows]
      .sort((a, b) => new Date(a.due_date) - new Date(b.due_date));

    res.json(allVaccines);
  } catch (err) {
    console.error('Error in /upcoming:', err.message);
    res.status(500).json({ 
      error: 'Erreur serveur',
      details: process.env.NODE_ENV === 'development' ? err.message : undefined
    });
  }
});

/**
 * @route GET /api/statistics/completed
 * @description Récupère l'historique des vaccinations complétées
 * @access Privé
 */
router.get('/completed', authenticateToken, async (req, res) => {
  try {
    const completedVaccines = await pool.query(
      `SELECT 
         v.vaccine_name as name,
         vac.vaccination_date as date,
         COALESCE(fm.first_name || ' ' || fm.last_name, u.first_name || ' ' || u.last_name) as person,
         hc.center_name as location,
         vac.dose_number as dose,
         v.id as vaccine_id,
         vc.id as card_id
       FROM vaccination.vaccinations vac
       JOIN vaccination.vaccines v ON vac.vaccine_id = v.id
       JOIN vaccination.health_centers hc ON vac.health_center_id = hc.id
       JOIN vaccination.vaccination_cards vc ON vac.vaccination_card_id = vc.id
       LEFT JOIN vaccination.users u ON vc.user_id = u.id
       LEFT JOIN vaccination.family_members fm ON vc.family_member_id = fm.id
       WHERE (vc.user_id = $1 OR vc.family_member_id IN (
         SELECT id FROM vaccination.family_members WHERE user_id = $1
       ))
       ORDER BY vac.vaccination_date DESC`,
      [req.user.userId]
    );

    res.json(completedVaccines.rows);
  } catch (err) {
    console.error('Error in /completed:', err.message);
    res.status(500).json({ 
      error: 'Erreur serveur',
      details: process.env.NODE_ENV === 'development' ? err.message : undefined
    });
  }
});

/**
 * @route GET /api/statistics/summary
 * @description Récupère un résumé des statistiques vaccinales
 * @access Privé
 */
router.get('/summary', authenticateToken, async (req, res) => {
  try {
    // Statistiques globales
    const stats = await pool.query(
      `WITH user_cards AS (
         SELECT id FROM vaccination.vaccination_cards 
         WHERE user_id = $1 OR family_member_id IN (
           SELECT id FROM vaccination.family_members WHERE user_id = $1
         )
       )
       SELECT
         (SELECT COUNT(*) FROM user_cards) as total_cards,
         (SELECT COUNT(*) FROM vaccination.vaccinations WHERE vaccination_card_id IN (SELECT id FROM user_cards)) as total_vaccinations,
         (SELECT COUNT(*) FROM vaccination.reminders 
          WHERE vaccination_card_id IN (SELECT id FROM user_cards)
          AND reminder_date >= CURRENT_DATE) as upcoming_reminders,
         (SELECT COUNT(*) FROM vaccination.get_due_vaccinations(
           (SELECT id FROM user_cards LIMIT 1)
         ) WHERE age_in_days <= 0) as overdue_vaccinations`,
      [req.user.userId]
    );

    // Dernières vaccinations
    const recentVaccinations = await pool.query(
      `SELECT 
         v.vaccine_name as name,
         vac.vaccination_date as date
       FROM vaccination.vaccinations vac
       JOIN vaccination.vaccines v ON vac.vaccine_id = v.id
       WHERE vac.vaccination_card_id IN (
         SELECT id FROM vaccination.vaccination_cards 
         WHERE user_id = $1 OR family_member_id IN (
           SELECT id FROM vaccination.family_members WHERE user_id = $1
         )
       )
       ORDER BY vac.vaccination_date DESC
       LIMIT 3`,
      [req.user.userId]
    );

    res.json({
      summary: stats.rows[0],
      recent: recentVaccinations.rows
    });
  } catch (err) {
    console.error('Error in /summary:', err.message);
    res.status(500).json({ 
      error: 'Erreur serveur',
      details: process.env.NODE_ENV === 'development' ? err.message : undefined
    });
  }
});

module.exports = router;