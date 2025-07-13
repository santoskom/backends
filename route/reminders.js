// routes/reminders.js
const express = require("express");
const router = express.Router();
const { pool } = require("../db");
const authenticateToken = require("../middleware/authenticateToken");
const { sendEmail } = require("../services/mailer");
const cron = require("node-cron");

/**
 * @swagger
 * /api/reminders:
 *   get:
 *     summary: Récupérer les rappels pour l'utilisateur connecté et sa famille
 *     tags: [Reminders]
 *     security:
 *       - bearerAuth: []
 *     responses:
 *       200:
 *         description: Liste des rappels
 *         content:
 *           application/json:
 *             schema:
 *               type: array
 *               items:
 *                 $ref: '#/components/schemas/Reminder'
 */
router.get("/", authenticateToken, async (req, res) => {
  try {
    const reminders = await pool.query(`
      SELECT 
        r.id,
        v.vaccine_name as "vaccineName",
        CASE 
          WHEN vc.user_id = $1 THEN u.first_name || ' ' || u.last_name
          ELSE fm.first_name || ' ' || fm.last_name
        END as "userName",
        vc.card_number as "cardNumber",
        r.reminder_date as "dueDate",
        r.message,
        r.is_sent as "isRead",
        r.is_archived as "isArchived"
      FROM vaccination.reminders r
      JOIN vaccination.vaccines v ON r.vaccine_id = v.id
      JOIN vaccination.vaccination_cards vc ON r.vaccination_card_id = vc.id
      LEFT JOIN vaccination.users u ON vc.user_id = u.id
      LEFT JOIN vaccination.family_members fm ON vc.family_member_id = fm.id
      WHERE (vc.user_id = $1 OR vc.family_member_id IN (
        SELECT id FROM vaccination.family_members WHERE user_id = $1
      ))
      AND r.reminder_date >= NOW()
      AND r.is_archived = false
      ORDER BY r.reminder_date ASC
    `, [req.user.userId]);

    res.json(reminders.rows);
  } catch (err) {
    console.error("Erreur récupération rappels:", err);
    res.status(500).json({ error: "Erreur serveur" });
  }
});

/**
 * @swagger
 * /api/reminders/generate:
 *   post:
 *     summary: Générer les rappels pour les vaccins à venir
 *     tags: [Reminders]
 *     security:
 *       - bearerAuth: []
 *     responses:
 *       200:
 *         description: Rappels générés avec succès
 */
router.post("/generate", authenticateToken, async (req, res) => {
  try {
    // 1. Récupérer les carnets de vaccination
    const cards = await pool.query(`
      SELECT id FROM vaccination.vaccination_cards
      WHERE user_id = $1 OR family_member_id IN (
        SELECT id FROM vaccination.family_members WHERE user_id = $1
      )
    `, [req.user.userId]);

    // 2. Pour chaque carnet, générer les rappels
    for (const card of cards.rows) {
      await pool.query(`
        INSERT INTO vaccination.reminders (
          vaccination_card_id, 
          vaccine_id, 
          reminder_date, 
          message
        )
        SELECT 
          $1 as vaccination_card_id,
          vs.vaccine_id,
          (vc.user_dob + vs.age_in_days * INTERVAL '1 day' - INTERVAL '7 days') as reminder_date,
          'Rappel: Vaccination ' || v.vaccine_name || ' prévue dans 7 jours' as message
        FROM vaccination.vaccination_schedules vs
        JOIN vaccination.vaccines v ON vs.vaccine_id = v.id
        JOIN vaccination.vaccination_cards vc ON vc.id = $1
        LEFT JOIN vaccination.vaccinations vac ON (
          vac.vaccination_card_id = $1 
          AND vac.vaccine_id = vs.vaccine_id 
          AND vac.dose_number = vs.dose_number
        )
        LEFT JOIN vaccination.reminders r ON (
          r.vaccination_card_id = $1 
          AND r.vaccine_id = vs.vaccine_id
        )
        WHERE vac.id IS NULL
        AND r.id IS NULL
        AND (vc.user_dob + vs.age_in_days * INTERVAL '1 day') > NOW()
      `, [card.id]);
    }

    res.json({ message: "Rappels générés avec succès" });
  } catch (err) {
    console.error("Erreur génération rappels:", err);
    res.status(500).json({ error: "Erreur serveur" });
  }
});

/**
 * @swagger
 * /api/reminders/send-emails:
 *   post:
 *     summary: Envoyer les rappels par email
 *     tags: [Reminders]
 *     security:
 *       - bearerAuth: []
 *     responses:
 *       200:
 *         description: Emails envoyés avec succès
 */
router.post("/send-emails", authenticateToken, async (req, res) => {
  try {
    // 1. Récupérer l'email de l'utilisateur
    const user = await pool.query(
      "SELECT email, first_name, last_name FROM vaccination.users WHERE id = $1",
      [req.user.userId]
    );

    if (user.rows.length === 0) {
      return res.status(404).json({ error: "Utilisateur non trouvé" });
    }

    // 2. Récupérer les rappels non envoyés
    const reminders = await pool.query(`
      SELECT 
        r.id,
        v.vaccine_name,
        r.reminder_date,
        CASE 
          WHEN vc.user_id = $1 THEN 'Vous'
          ELSE fm.first_name || ' ' || fm.last_name
        END as member_name
      FROM vaccination.reminders r
      JOIN vaccination.vaccines v ON r.vaccine_id = v.id
      JOIN vaccination.vaccination_cards vc ON r.vaccination_card_id = vc.id
      LEFT JOIN vaccination.family_members fm ON vc.family_member_id = fm.id
      WHERE (vc.user_id = $1 OR vc.family_member_id IN (
        SELECT id FROM vaccination.family_members WHERE user_id = $1
      ))
      AND r.reminder_date BETWEEN NOW() AND NOW() + INTERVAL '7 days'
      AND r.is_sent = false
    `, [req.user.userId]);

    // 3. Envoyer les emails
    for (const reminder of reminders.rows) {
      const emailContent = `
        <div style="font-family: Arial, sans-serif; max-width: 600px; margin: 0 auto;">
          <h2 style="color: #6c63ff;">Rappel de vaccination</h2>
          <p>Bonjour ${user.rows[0].first_name},</p>
          <p>Vous avez un rappel pour la vaccination <strong>${reminder.vaccine_name}</strong> 
          pour <strong>${reminder.member_name}</strong> prévue le 
          ${new Date(reminder.reminder_date).toLocaleDateString('fr-FR')}.</p>
          <div style="margin-top: 20px;">
            <a href="https://votre-app.com/carnet" style="background-color: #6c63ff; color: white; padding: 10px 20px; text-decoration: none; border-radius: 5px;">
              Voir le carnet de vaccination
            </a>
          </div>
        </div>
      `;

      await sendEmail(
        user.rows[0].email,
        `Rappel: Vaccination ${reminder.vaccine_name}`,
        emailContent
      );

      // Marquer comme envoyé
      await pool.query(
        "UPDATE vaccination.reminders SET is_sent = true, sent_at = NOW() WHERE id = $1",
        [reminder.id]
      );
    }

    res.json({ message: `${reminders.rows.length} emails envoyés avec succès` });
  } catch (err) {
    console.error("Erreur envoi emails:", err);
    res.status(500).json({ error: "Erreur serveur" });
  }
});

// Planification CRON pour l'envoi automatique
cron.schedule('0 9 * * *', async () => {
  console.log('Exécution de l\'envoi automatique des rappels...');
  try {
    // Implémentez ici la logique d'envoi automatique
  } catch (err) {
    console.error('Erreur CRON:', err);
  }
});

module.exports = router;