const express = require("express");
const router = express.Router();
const { Pool } = require("pg");
const authenticateToken = require("../middleware/authenticateToken");

const pool = new Pool({
  host: process.env.DB_HOST,
  port: process.env.DB_PORT,
  user: process.env.DB_USER,
  password: process.env.DB_PASSWORD,
  database: process.env.DB_NAME,
});

// Route : /api/stats/:user_id
router.get("/:user_id", authenticateToken, async (req, res) => {
  const userId = req.params.user_id;
  console.log("Appel à /api/stats avec userId =", userId);

  try {
    // Total des vaccinations effectuées
    const totalRes = await pool.query(
      `SELECT COUNT(*) AS total
       FROM vaccination.vaccinations v
       JOIN vaccination.vaccination_cards vc ON v.vaccination_card_id = vc.id
       WHERE vc.user_id = $1
          OR vc.family_member_id IN (
              SELECT id FROM vaccination.family_members WHERE user_id = $1
          )`,
      [userId]
    );

    // Séries vaccinales complètes depuis la vue
    const completedRes = await pool.query(
      `SELECT COUNT(*) AS completed_series
       FROM vaccination.series_completion sc
       WHERE sc.user_id = $1
         AND sc.is_series_complete = true`,
      [userId]
    );

    // Vaccinations à venir
    const upcomingRes = await pool.query(
      `SELECT COUNT(*) AS upcoming_count
       FROM vaccination.get_due_vaccinations($1::uuid)`,
      [userId]
    );

    res.status(200).json({
      totalVaccinations: parseInt(totalRes.rows[0].total, 10) || 0,
      completedSeries: parseInt(completedRes.rows[0].completed_series, 10) || 0,
      upcomingVaccinations: parseInt(upcomingRes.rows[0].upcoming_count, 10) || 0,
    });
  } catch (err) {
    console.error("Erreur récupération stats:", err);
    res.status(500).json({ error: "Erreur serveur" });
  }
});

module.exports = router;
