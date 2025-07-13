const express = require('express');
const router = express.Router();
const {pool} = require('../db');
const authenticateHealthProfessional = require('../middleware/authenticateToken');

// Middleware pour vérifier que l'utilisateur est un professionnel de santé
router.use(authenticateHealthProfessional);

/**
 * @swagger
 * /dashboard/summary:
 *   get:
 *     summary: Récupère les statistiques résumées pour le dashboard
 *     tags: [Dashboard]
 *     responses:
 *       200:
 *         description: Statistiques du dashboard
 *         content:
 *           application/json:
 *             schema:
 *               type: object
 *               properties:
 *                 todayVaccinations:
 *                   type: number
 *                 monthlyPatients:
 *                   type: number
 *                 upcomingReminders:
 *                   type: number
 *                 stockAlerts:
 *                   type: number
 */
router.get('/summary', async (req, res) => {
    try {
        const healthCenterId = req.user.health_center_id;
        const today = new Date().toISOString().split('T')[0];

        // Requêtes en parallèle pour optimiser les performances
        const [todayVaccinations, monthlyPatients, upcomingReminders, stockAlerts] = await Promise.all([
            pool.query(`
                SELECT COUNT(*) 
                FROM vaccination.vaccinations 
                WHERE health_center_id = $1 
                AND vaccination_date = $2
            `, [healthCenterId, today]),
            
            pool.query(`
                SELECT COUNT(DISTINCT vaccination_card_id) 
                FROM vaccination.vaccinations 
                WHERE health_center_id = $1 
                AND vaccination_date BETWEEN $2 AND $3
            `, [healthCenterId, getFirstDayOfMonth(), today]),
            
            pool.query(`
                SELECT COUNT(*) 
                FROM vaccination.reminders r
                JOIN vaccination.vaccination_cards vc ON r.vaccination_card_id = vc.id
                WHERE r.reminder_date BETWEEN $1 AND $2
                AND r.is_sent = false
                AND vc.health_center_id = $3
            `, [today, getDateInDays(7), healthCenterId]),
            
            pool.query(`
                SELECT COUNT(*) 
                FROM vaccination.vaccine_stocks 
                WHERE health_center_id = $1 
                AND (quantity < 10 OR expiry_date < $2)
            `, [healthCenterId, getDateInDays(30)])
        ]);

        res.json({
            todayVaccinations: parseInt(todayVaccinations.rows[0].count),
            monthlyPatients: parseInt(monthlyPatients.rows[0].count),
            upcomingReminders: parseInt(upcomingReminders.rows[0].count),
            stockAlerts: parseInt(stockAlerts.rows[0].count)
        });
    } catch (err) {
        console.error(err);
        res.status(500).json({ error: 'Erreur serveur' });
    }
});

/**
 * @swagger
 * /dashboard/today-vaccinations:
 *   get:
 *     summary: Liste des vaccinations prévues aujourd'hui
 *     tags: [Dashboard]
 *     responses:
 *       200:
 *         description: Liste des vaccinations
 *         content:
 *           application/json:
 *             schema:
 *               type: array
 *               items:
 *                 type: object
 *                 properties:
 *                   id:
 *                     type: string
 *                   name:
 *                     type: string
 *                   vaccine:
 *                     type: string
 *                   method:
 *                     type: string
 *                   time:
 *                     type: string
 *                   status:
 *                     type: string
 */
router.get('/today-vaccinations', async (req, res) => {
    try {
      const today = new Date().toISOString().split('T')[0]; // YYYY-MM-DD
  
      const query = `
        SELECT 
          vac.id AS vaccination_id,
          vac.vaccination_date,
          vac.dose_number,
          vac.batch_number,
          v.vaccine_name,
          hc.center_name,
          COALESCE(
            CONCAT(u.first_name, ' ', u.last_name),
            CONCAT(fm.first_name, ' ', fm.last_name)
          ) AS patient_name,
          COALESCE(u.id, fm.id) AS patient_id,
          COALESCE(u.cin, fm.cin) AS cin,
          COALESCE(vcard.qr_code, fm.qr_code) AS qr_code
        FROM vaccination.vaccinations vac
        JOIN vaccination.vaccines v ON vac.vaccine_id = v.id
        JOIN vaccination.vaccination_cards vcard ON vac.vaccination_card_id = vcard.id
        JOIN vaccination.health_centers hc ON vac.health_center_id = hc.id
        LEFT JOIN vaccination.users u ON vcard.user_id = u.id
        LEFT JOIN vaccination.family_members fm ON vcard.family_member_id = fm.id
        WHERE vac.vaccination_date = $1
        ORDER BY vac.vaccination_date DESC
      `;
  
      const result = await pool.query(query, [today]);
      res.json(result.rows);
    } catch (err) {
      console.error('Erreur lors de la récupération des vaccinations du jour:', err);
      res.status(500).json({ error: 'Erreur serveur' });
    }
  });

/**
 * @swagger
 * /dashboard/vaccine-stocks:
 *   get:
 *     summary: État des stocks de vaccins
 *     tags: [Dashboard]
 *     responses:
 *       200:
 *         description: Liste des stocks
 *         content:
 *           application/json:
 *             schema:
 *               type: array
 *               items:
 *                 type: object
 *                 properties:
 *                   name:
 *                     type: string
 *                   stock:
 *                     type: number
 *                   threshold:
 *                     type: number
 *                   status:
 *                     type: string
 */
router.get('/vaccine-stocks', async (req, res) => {
    try {
        const result = await pool.query(`
            SELECT 
                v.vaccine_name as name,
                SUM(vs.quantity) as stock,
                CASE 
                    WHEN v.vaccine_code = 'BCG' THEN 25
                    WHEN v.vaccine_code = 'POLIO' THEN 20
                    WHEN v.vaccine_code = 'ROR' THEN 60
                    ELSE 15
                END as threshold,
                CASE 
                    WHEN SUM(vs.quantity) < 5 THEN 'critical'
                    WHEN SUM(vs.quantity) < 10 THEN 'low'
                    ELSE 'normal'
                END as status
            FROM vaccination.vaccine_stocks vs
            JOIN vaccination.vaccines v ON vs.vaccine_id = v.id
            WHERE vs.health_center_id = $1
            GROUP BY v.vaccine_name, v.vaccine_code
            ORDER BY status DESC
        `, [req.user.health_center_id]);

        res.json(result.rows);
    } catch (err) {
        console.error(err);
        res.status(500).json({ error: 'Erreur serveur' });
    }
});

/**
 * @swagger
 * /dashboard/alerts:
 *   get:
 *     summary: Alertes prioritaires
 *     tags: [Dashboard]
 *     responses:
 *       200:
 *         description: Liste des alertes
 *         content:
 *           application/json:
 *             schema:
 *               type: array
 *               items:
 *                 type: object
 *                 properties:
 *                   type:
 *                     type: string
 *                   message:
 *                     type: string
 *                   severity:
 *                     type: string
 */
router.get('/alerts', async (req, res) => {
    try {
        const alerts = [];
        const healthCenterId = req.user.health_center_id;

        // Alertes de stock critique
        const criticalStock = await pool.query(`
            SELECT v.vaccine_name, SUM(vs.quantity) as quantity
            FROM vaccination.vaccine_stocks vs
            JOIN vaccination.vaccines v ON vs.vaccine_id = v.id
            WHERE vs.health_center_id = $1
            GROUP BY v.vaccine_name
            HAVING SUM(vs.quantity) < 5
        `, [healthCenterId]);

        criticalStock.rows.forEach(row => {
            alerts.push({
                type: 'stock',
                message: `Stock ${row.vaccine_name} critique (${row.quantity} doses restantes)`,
                severity: 'critical'
            });
        });

        // Alertes de stock faible
        const lowStock = await pool.query(`
            SELECT v.vaccine_name, SUM(vs.quantity) as quantity
            FROM vaccination.vaccine_stocks vs
            JOIN vaccination.vaccines v ON vs.vaccine_id = v.id
            WHERE vs.health_center_id = $1
            GROUP BY v.vaccine_name
            HAVING SUM(vs.quantity) BETWEEN 5 AND 10
        `, [healthCenterId]);

        lowStock.rows.forEach(row => {
            alerts.push({
                type: 'stock',
                message: `Stock ${row.vaccine_name} faible (${row.quantity} doses restantes)`,
                severity: 'warning'
            });
        });

        // Alertes de vaccins expirant bientôt
        const expiringSoon = await pool.query(`
            SELECT v.vaccine_name, MIN(vs.expiry_date) as expiry_date
            FROM vaccination.vaccine_stocks vs
            JOIN vaccination.vaccines v ON vs.vaccine_id = v.id
            WHERE vs.health_center_id = $1
            AND vs.expiry_date BETWEEN CURRENT_DATE AND (CURRENT_DATE + INTERVAL '30 days')
            GROUP BY v.vaccine_name
        `, [healthCenterId]);

        expiringSoon.rows.forEach(row => {
            alerts.push({
                type: 'expiry',
                message: `${row.vaccine_name} expire le ${new Date(row.expiry_date).toLocaleDateString()}`,
                severity: 'warning'
            });
        });

        res.json(alerts);
    } catch (err) {
        console.error(err);
        res.status(500).json({ error: 'Erreur serveur' });
    }
});

/**
 * @swagger
 * /dashboard/patient-tracking:
 *   get:
 *     summary: Suivi des patients
 *     tags: [Dashboard]
 *     responses:
 *       200:
 *         description: Statistiques de suivi
 *         content:
 *           application/json:
 *             schema:
 *               type: object
 *               properties:
 *                 reminders:
 *                   type: object
 *                   properties:
 *                     count:
 *                       type: number
 *                     nextPatient:
 *                       type: string
 *                     nextDate:
 *                       type: string
 *                 coverageRate:
 *                   type: number
 */
router.get('/patient-tracking', async (req, res) => {
    try {
        const healthCenterId = req.user.health_center_id;
        const today = new Date().toISOString().split('T')[0];
        const firstDayOfMonth = getFirstDayOfMonth();

        // Récupérer les rappels
        const reminders = await pool.query(`
            SELECT 
                COUNT(*) as count,
                MIN(r.reminder_date) as next_date,
                CONCAT(u.first_name, ' ', u.last_name) as next_patient
            FROM vaccination.reminders r
            JOIN vaccination.vaccination_cards vc ON r.vaccination_card_id = vc.id
            LEFT JOIN vaccination.users u ON vc.user_id = u.id
            LEFT JOIN vaccination.family_members fm ON vc.family_member_id = fm.id
            WHERE r.reminder_date BETWEEN $1 AND $2
            AND r.is_sent = false
            AND vc.health_center_id = $3
            GROUP BY u.first_name, u.last_name
            ORDER BY next_date
            LIMIT 1
        `, [today, getDateInDays(7), healthCenterId]);

        // Taux de couverture vaccinale
        const coverage = await pool.query(`
            WITH total_patients AS (
                SELECT COUNT(DISTINCT vc.id) as total
                FROM vaccination.vaccination_cards vc
                WHERE vc.health_center_id = $1
            ),
            vaccinated_patients AS (
                SELECT COUNT(DISTINCT v.vaccination_card_id) as vaccinated
                FROM vaccination.vaccinations v
                JOIN vaccination.vaccination_cards vc ON v.vaccination_card_id = vc.id
                WHERE vc.health_center_id = $1
                AND v.vaccination_date BETWEEN $2 AND $3
            )
            SELECT 
                total, 
                vaccinated,
                ROUND((vaccinated * 100.0) / NULLIF(total, 0), 2) as coverage_rate
            FROM total_patients, vaccinated_patients
        `, [healthCenterId, firstDayOfMonth, today]);

        res.json({
            reminders: {
                count: parseInt(reminders.rows[0]?.count || 0),
                nextPatient: reminders.rows[0]?.next_patient || 'Aucun',
                nextDate: reminders.rows[0]?.next_date || 'Aucune date'
            },
            coverageRate: parseFloat(coverage.rows[0]?.coverage_rate || 0)
        });
    } catch (err) {
        console.error(err);
        res.status(500).json({ error: 'Erreur serveur' });
    }
});

/**
 * @swagger
 * /dashboard/recent-activity:
 *   get:
 *     summary: Activité récente
 *     tags: [Dashboard]
 *     responses:
 *       200:
 *         description: Liste des activités récentes
 *         content:
 *           application/json:
 *             schema:
 *               type: array
 *               items:
 *                 type: object
 *                 properties:
 *                   type:
 *                     type: string
 *                   description:
 *                     type: string
 *                   time:
 *                     type: string
 */
router.get('/recent-activity', async (req, res) => {
    try {
      const healthCenterId = req.user.health_center_id;
      const today = new Date().toISOString().split('T')[0];
  
      const result = await pool.query(
        `
        (
          SELECT 
            'vaccination' AS type,
            CONCAT('Vaccination ', vc.vaccine_name, ' pour ', 
                   COALESCE(u.first_name || ' ' || u.last_name, 
                           fm.first_name || ' ' || fm.last_name)) AS description,
            TO_CHAR(v.vaccination_date, 'HH24:MI') AS time
          FROM vaccination.vaccinations v
          JOIN vaccination.vaccines vc ON v.vaccine_id = vc.id
          JOIN vaccination.vaccination_cards vcard ON v.vaccination_card_id = vcard.id
          LEFT JOIN vaccination.users u ON vcard.user_id = u.id
          LEFT JOIN vaccination.family_members fm ON vcard.family_member_id = fm.id
          WHERE v.health_center_id = $1
          AND v.vaccination_date = $2
          ORDER BY v.vaccination_date DESC
          LIMIT 3
        )
        UNION ALL
        (
          SELECT 
            'stock' AS type,
            CONCAT('Mise à jour stock ', v.vaccine_name) AS description,
            TO_CHAR(vs.last_updated, 'HH24:MI') AS time
          FROM vaccination.vaccine_stocks vs
          JOIN vaccination.vaccines v ON vs.vaccine_id = v.id
          WHERE vs.health_center_id = $1
          AND vs.last_updated::date = $2
          ORDER BY vs.last_updated DESC
          LIMIT 2
        )
        ORDER BY time DESC
        LIMIT 5
        `,
        [healthCenterId, today]
      );
  
      res.json(result.rows);
    } catch (err) {
      console.error(err);
      res.status(500).json({ error: 'Erreur serveur' });
    }
  });
  
// Fonctions utilitaires
function getFirstDayOfMonth() {
    const date = new Date();
    return new Date(date.getFullYear(), date.getMonth(), 1).toISOString().split('T')[0];
}

function getDateInDays(days) {
    const date = new Date();
    date.setDate(date.getDate() + days);
    return date.toISOString().split('T')[0];
}

module.exports = router;