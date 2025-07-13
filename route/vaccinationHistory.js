const express = require("express");
const router = express.Router();
const { Pool } = require("pg");
const authenticateToken = require("../middleware/authenticateToken");

const pool = new Pool({
  host: process.env.DB_HOST || "localhost",
  port: process.env.DB_PORT || 5432,
  database: process.env.DB_NAME || "vaccination_db",
  user: process.env.DB_USER || "postgres",
  password: process.env.DB_PASSWORD || "password",
  ssl: false,
});

// Récupérer les vaccinations du citoyen connecté
router.get("/", authenticateToken, async (req, res) => {
  const userId = req.user.userId;

  try {
    const result = await pool.query(
        `SELECT 
            vac.id,
            v.vaccine_name,
            v.manufacturer,
            vac.vaccination_date AS date,
            vac.batch_number,
            vac.notes AS side_effects,
            NULL AS status,  -- à adapter si besoin
            NULL AS nextDue, -- idem
            CONCAT(admin.first_name, ' ', admin.last_name) AS administered_by,
            hc.center_name AS center
        FROM vaccination.vaccinations vac
        JOIN vaccination.vaccination_cards vc ON vac.vaccination_card_id = vc.id
        JOIN vaccination.vaccines v ON vac.vaccine_id = v.id
        JOIN vaccination.health_centers hc ON vac.health_center_id = hc.id
        LEFT JOIN vaccination.users admin ON vac.administered_by = admin.id
        WHERE vc.user_id = $1
        ORDER BY vac.vaccination_date DESC;`,
        [userId]
      );
      
      

    res.json(result.rows);
  } catch (error) {
    console.error("Erreur récupération historique vaccinal:", error);
    res.status(500).json({ error: "Erreur serveur" });
  }
});

module.exports = router;
