const express = require("express");
const router = express.Router();
const { pool } = require("../db");
const authenticateToken = require("../middleware/authenticateToken");

// GET /api/family-members
router.get('/', authenticateToken, async (req, res) => {
  try {
    const result = await pool.query(
      `SELECT 
         fm.id,
         fm.first_name || ' ' || fm.last_name as name,
         fm.relationship as role,
         EXTRACT(YEAR FROM AGE(fm.date_of_birth))::int as age,
         fm.first_name,
         fm.last_name,
         fm.date_of_birth,
         (
           SELECT COUNT(*) 
           FROM vaccination.vaccinations v
           JOIN vaccination.vaccination_cards vc ON v.vaccination_card_id = vc.id
           WHERE vc.family_member_id = fm.id
         ) as vaccines_up_to_date,
         (
           SELECT COUNT(*) 
           FROM vaccination.vaccination_schedules vs
           JOIN vaccination.vaccines v ON vs.vaccine_id = v.id
           WHERE vs.age_in_days <= (CURRENT_DATE - fm.date_of_birth)
           AND v.is_active = TRUE
         ) as total_vaccines,
         TO_CHAR(fm.updated_at, 'YYYY-MM-DD') as last_updated
       FROM vaccination.family_members fm
       WHERE fm.user_id = $1
       ORDER BY fm.created_at DESC`,
      [req.user.userId]
    );

    res.json(result.rows.map(member => ({
      ...member,
      avatar: member.first_name.charAt(0) + member.last_name.charAt(0)
    })));
  } catch (err) {
    console.error('Error fetching family members:', err);
    res.status(500).json({ error: 'Erreur serveur' });
  }
});

module.exports = router;