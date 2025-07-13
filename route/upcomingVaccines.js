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

// Vaccins à venir pour un carnet donné
// Route : /api/upcoming/:user_id
router.get("/:user_id", authenticateToken, async (req, res) => {
    const userId = req.params.user_id;
    console.log("Appel à /api/upcoming avec userId =", userId);
  
    try {
      const cardsResult = await pool.query(`
        SELECT id FROM vaccination.vaccination_cards
        WHERE user_id = $1
           OR family_member_id IN (
             SELECT id FROM vaccination.family_members WHERE user_id = $1
           )
      `, [userId]);
      console.log("Carnets trouvés :", cardsResult.rows);
  
      const cardIds = cardsResult.rows.map(row => row.id);
      if (cardIds.length === 0) {
        return res.status(200).json([]);
      }
  
      const upcomingVaccines = [];
      for (const cardId of cardIds) {
        console.log("Récupération vaccins à venir pour carnet :", cardId);
        const dueVaccinesResult = await pool.query(`
          SELECT *, (SELECT center_name FROM vaccination.health_centers WHERE id = health_center_id) AS center
          FROM vaccination.get_due_vaccinations($1)
        `, [cardId]);
        console.log("Vaccins à venir :", dueVaccinesResult.rows);
  
        dueVaccinesResult.rows.forEach(vaccine => {
          upcomingVaccines.push({
            id: `${cardId}-${vaccine.vaccine_name}-${vaccine.dose_number}`,
            vaccineName: vaccine.vaccine_name,
            scheduledDate: vaccine.due_date,
            doseNumber: vaccine.dose_number,
            center: vaccine.center || "Centre non spécifié"
          });
        });
      }
  
      res.status(200).json(upcomingVaccines);
    } catch (err) {
      console.error("Erreur lors de la récupération des vaccins à venir:", err);
      res.status(500).json({ error: "Erreur serveur" });
    }
  });
  
  


module.exports = router;
