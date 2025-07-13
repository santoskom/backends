const express = require("express");
const router = express.Router();
const { pool } = require("../db"); // Utilisez votre configuration de pool existante
const authenticateToken = require("../middleware/authenticateToken");

/**
 * @swagger
 * tags:
 *   name: Family Members
 *   description: Gestion des membres de famille
 */

/**
 * @swagger
 * /api/family-members:
 *   post:
 *     summary: Ajouter un nouveau membre de famille
 *     tags: [Family Members]
 *     security:
 *       - bearerAuth: []
 *     requestBody:
 *       required: true
 *       content:
 *         application/json:
 *           schema:
 *             type: object
 *             required:
 *               - first_name
 *               - last_name
 *               - date_of_birth
 *               - gender
 *               - relationship
 *             properties:
 *               first_name:
 *                 type: string
 *               last_name:
 *                 type: string
 *               date_of_birth:
 *                 type: string
 *                 format: date
 *               gender:
 *                 type: string
 *                 enum: [M, F]
 *               relationship:
 *                 type: string
 *               cin:
 *                 type: string
 *     responses:
 *       201:
 *         description: Membre de famille créé avec succès
 *       400:
 *         description: Données manquantes ou invalides
 *       500:
 *         description: Erreur serveur
 */
router.post("/", authenticateToken, async (req, res) => {
  const client = await pool.connect();
  try {
    const { first_name, last_name, date_of_birth, gender, relationship, cin } = req.body;

    // Validation des données
    if (!first_name || !last_name || !date_of_birth || !gender || !relationship) {
      return res.status(400).json({ error: "Tous les champs obligatoires doivent être renseignés" });
    }

    if (!["M", "F"].includes(gender)) {
      return res.status(400).json({ error: "Le genre doit être M ou F" });
    }

    // Insertion du membre de famille
    const insertQuery = `
      INSERT INTO vaccination.family_members 
        (user_id, first_name, last_name, date_of_birth, gender, relationship, cin)
      VALUES ($1, $2, $3, $4, $5, $6, $7)
      RETURNING *`;
    
    const values = [
      req.user.userId, 
      first_name, 
      last_name, 
      date_of_birth, 
      gender, 
      relationship, 
      cin || null
    ];

    const result = await client.query(insertQuery, values);
    const newMember = result.rows[0];

    // Création automatique du carnet de vaccination
    await client.query(
      "SELECT vaccination.create_vaccination_card(NULL, $1)",
      [newMember.id]
    );

    res.status(201).json(newMember);
  } catch (error) {
    console.error("Erreur lors de l'ajout du membre de famille:", error);
    res.status(500).json({ error: "Erreur lors de l'ajout du membre de famille" });
  } finally {
    client.release();
  }
});

/**
 * @swagger
 * /api/family-members:
 *   get:
 *     summary: Lister tous les membres de famille d'un utilisateur
 *     tags: [Family Members]
 *     security:
 *       - bearerAuth: []
 *     responses:
 *       200:
 *         description: Liste des membres de famille
 *         content:
 *           application/json:
 *             schema:
 *               type: array
 *               items:
 *                 $ref: '#/components/schemas/FamilyMember'
 *       500:
 *         description: Erreur serveur
 */
router.get("/", authenticateToken, async (req, res) => {
  const client = await pool.connect();
  try {
    const query = `
      SELECT 
        fm.*, 
        vc.card_number,
        vc.qr_code,
        (SELECT COUNT(*) FROM vaccination.vaccinations v 
         JOIN vaccination.vaccination_cards vc2 ON v.vaccination_card_id = vc2.id
         WHERE vc2.family_member_id = fm.id) as vaccination_count
      FROM vaccination.family_members fm
      LEFT JOIN vaccination.vaccination_cards vc ON fm.id = vc.family_member_id
      WHERE fm.user_id = $1 AND fm.is_active = true
      ORDER BY fm.created_at DESC`;
    
    const result = await client.query(query, [req.user.userId]);
    res.json(result.rows);
  } catch (error) {
    console.error("Erreur lors de la récupération des membres de famille:", error);
    res.status(500).json({ error: "Erreur lors de la récupération des membres de famille" });
  } finally {
    client.release();
  }
});

/**
 * @swagger
 * /api/family-members/{id}:
 *   get:
 *     summary: Obtenir les détails d'un membre de famille spécifique
 *     tags: [Family Members]
 *     security:
 *       - bearerAuth: []
 *     parameters:
 *       - in: path
 *         name: id
 *         required: true
 *         schema:
 *           type: string
 *         description: ID du membre de famille
 *     responses:
 *       200:
 *         description: Détails du membre de famille
 *         content:
 *           application/json:
 *             schema:
 *               $ref: '#/components/schemas/FamilyMember'
 *       404:
 *         description: Membre de famille non trouvé
 *       500:
 *         description: Erreur serveur
 */
router.get("/:id", authenticateToken, async (req, res) => {
  const client = await pool.connect();
  try {
    const query = `
      SELECT 
        fm.*, 
        vc.card_number,
        vc.qr_code
      FROM vaccination.family_members fm
      LEFT JOIN vaccination.vaccination_cards vc ON fm.id = vc.family_member_id
      WHERE fm.id = $1 AND fm.user_id = $2 AND fm.is_active = true`;
    
    const result = await client.query(query, [req.params.id, req.user.userId]);
    
    if (result.rows.length === 0) {
      return res.status(404).json({ error: "Membre de famille non trouvé" });
    }
    
    res.json(result.rows[0]);
  } catch (error) {
    console.error("Erreur lors de la récupération du membre de famille:", error);
    res.status(500).json({ error: "Erreur lors de la récupération du membre de famille" });
  } finally {
    client.release();
  }
});

/**
 * @swagger
 * /api/family-members/{id}:
 *   put:
 *     summary: Mettre à jour un membre de famille
 *     tags: [Family Members]
 *     security:
 *       - bearerAuth: []
 *     parameters:
 *       - in: path
 *         name: id
 *         required: true
 *         schema:
 *           type: string
 *         description: ID du membre de famille
 *     requestBody:
 *       required: true
 *       content:
 *         application/json:
 *           schema:
 *             type: object
 *             properties:
 *               first_name:
 *                 type: string
 *               last_name:
 *                 type: string
 *               date_of_birth:
 *                 type: string
 *                 format: date
 *               gender:
 *                 type: string
 *                 enum: [M, F]
 *               relationship:
 *                 type: string
 *               cin:
 *                 type: string
 *     responses:
 *       200:
 *         description: Membre de famille mis à jour
 *       400:
 *         description: Données invalides
 *       404:
 *         description: Membre de famille non trouvé
 *       500:
 *         description: Erreur serveur
 */
router.put("/:id", authenticateToken, async (req, res) => {
  const client = await pool.connect();
  try {
    const { id } = req.params;
    const { first_name, last_name, date_of_birth, gender, relationship, cin } = req.body;

    // Vérifier que le membre appartient à l'utilisateur
    const checkQuery = `
      SELECT id FROM vaccination.family_members 
      WHERE id = $1 AND user_id = $2 AND is_active = true`;
    
    const checkResult = await client.query(checkQuery, [id, req.user.userId]);
    
    if (checkResult.rows.length === 0) {
      return res.status(404).json({ error: "Membre de famille non trouvé" });
    }

    // Mise à jour
    const updateQuery = `
      UPDATE vaccination.family_members
      SET 
        first_name = COALESCE($1, first_name),
        last_name = COALESCE($2, last_name),
        date_of_birth = COALESCE($3, date_of_birth),
        gender = COALESCE($4, gender),
        relationship = COALESCE($5, relationship),
        cin = COALESCE($6, cin),
        updated_at = NOW()
      WHERE id = $7
      RETURNING *`;
    
    const values = [
      first_name || null,
      last_name || null,
      date_of_birth || null,
      gender || null,
      relationship || null,
      cin || null,
      id
    ];

    const result = await client.query(updateQuery, values);
    res.json(result.rows[0]);
  } catch (error) {
    console.error("Erreur lors de la mise à jour du membre de famille:", error);
    res.status(500).json({ error: "Erreur lors de la mise à jour du membre de famille" });
  } finally {
    client.release();
  }
});

/**
 * @swagger
 * /api/family-members/{id}:
 *   delete:
 *     summary: Supprimer un membre de famille (soft delete)
 *     tags: [Family Members]
 *     security:
 *       - bearerAuth: []
 *     parameters:
 *       - in: path
 *         name: id
 *         required: true
 *         schema:
 *           type: string
 *         description: ID du membre de famille
 *     responses:
 *       200:
 *         description: Membre de famille supprimé
 *       404:
 *         description: Membre de famille non trouvé
 *       500:
 *         description: Erreur serveur
 */
router.delete("/:id", authenticateToken, async (req, res) => {
  const client = await pool.connect();
  try {
    const { id } = req.params;

    // Vérifier que le membre appartient à l'utilisateur
    const checkQuery = `
      SELECT id FROM vaccination.family_members 
      WHERE id = $1 AND user_id = $2 AND is_active = true`;
    
    const checkResult = await client.query(checkQuery, [id, req.user.userId]);
    
    if (checkResult.rows.length === 0) {
      return res.status(404).json({ error: "Membre de famille non trouvé" });
    }

    // Soft delete
    await client.query(
      "UPDATE vaccination.family_members SET is_active = false WHERE id = $1",
      [id]
    );

    res.json({ message: "Membre de famille supprimé avec succès" });
  } catch (error) {
    console.error("Erreur lors de la suppression du membre de famille:", error);
    res.status(500).json({ error: "Erreur lors de la suppression du membre de famille" });
  } finally {
    client.release();
  }
});

module.exports = router;