const express = require('express');
const router = express.Router();
const bcrypt = require('bcrypt');
const authenticateToken = require('../middleware/authenticateToken');
const { pool } = require('../db');  // Import du pool centralisé

// 🔒 Supprimer un compte utilisateur : DELETE /api/users/:userId
router.delete('/:userId', authenticateToken, async (req, res) => {
  const { userId } = req.params;
  const { currentPassword } = req.body;

  if (req.user.userId !== userId) {
    return res.status(403).json({ error: 'Non autorisé' });
  }

  const client = await pool.connect();

  try {
    const userRes = await client.query(
      `SELECT id, password_hash, user_type_id, health_center_id 
       FROM vaccination.users 
       WHERE id = $1`, [userId]
    );

    if (userRes.rows.length === 0) {
      return res.status(404).json({ error: 'Utilisateur non trouvé' });
    }

    const user = userRes.rows[0];

    const validPassword = await bcrypt.compare(currentPassword, user.password_hash);
    if (!validPassword) {
      return res.status(401).json({ error: 'Mot de passe incorrect' });
    }

    // Vérifie si c'est bien un professionnel de santé
    const typeCodeRes = await client.query(
      `SELECT type_code FROM vaccination.user_types WHERE id = $1`,
      [user.user_type_id]
    );

    const isHealthProfessional = typeCodeRes.rows[0]?.type_code === 'HEALTH_PROF';
    if (!isHealthProfessional) {
      return res.status(403).json({ error: 'Cette opération est réservée aux professionnels de santé' });
    }

    await client.query('BEGIN');

    // 🔄 Cherche un remplaçant
    const replacementRes = await client.query(
      `SELECT id FROM vaccination.users 
       WHERE health_center_id = $1 
       AND id != $2 
       AND user_type_id = $3 
       AND is_active = TRUE 
       LIMIT 1`,
      [user.health_center_id, userId, user.user_type_id]
    );

    if (replacementRes.rows.length > 0) {
      const replacementId = replacementRes.rows[0].id;

      // Réassignation des responsabilités
      await client.query(
        `UPDATE vaccination.vaccinations 
         SET administered_by = $1 
         WHERE administered_by = $2`,
        [replacementId, userId]
      );

      await client.query(
        `UPDATE vaccination.vaccine_stocks 
         SET updated_by = $1 
         WHERE updated_by = $2`,
        [replacementId, userId]
      );

      // Suppression du compte
      await client.query(`DELETE FROM vaccination.users WHERE id = $1`, [userId]);

      await client.query('COMMIT');
      return res.status(200).json({ message: 'Professionnel supprimé et ses données réassignées à un remplaçant' });
    } else {
      // Aucun remplaçant : on archive le compte
      await client.query(
        `UPDATE vaccination.users SET is_active = FALSE WHERE id = $1`,
        [userId]
      );

      await client.query('COMMIT');
      return res.status(200).json({
        message: 'Aucun remplaçant trouvé. Le compte a été désactivé (archivé).',
      });
    }

  } catch (error) {
    await client.query('ROLLBACK');
    console.error('Erreur suppression professionnel:', error);
    res.status(500).json({
      error: 'Erreur lors de la suppression du professionnel',
      details: error.message,
    });
  } finally {
    client.release();
  }
});


// 🔒 Modifier mot de passe : PUT /api/users/:userId/password
router.put('/:userId/password', authenticateToken, async (req, res) => {
  const { userId } = req.params;
  const { currentPassword, newPassword } = req.body;

  if (req.user.userId !== userId) {
    return res.status(403).json({ error: 'Non autorisé' });
  }

  try {
    const userResult = await pool.query(
      'SELECT password_hash FROM vaccination.users WHERE id = $1',
      [userId]
    );

    if (userResult.rows.length === 0) {
      return res.status(404).json({ error: 'Utilisateur non trouvé' });
    }

    const validPassword = await bcrypt.compare(
      currentPassword,
      userResult.rows[0].password_hash
    );

    if (!validPassword) {
      return res.status(401).json({ error: 'Mot de passe actuel incorrect' });
    }

    const newPasswordHash = await bcrypt.hash(newPassword, 10);

    await pool.query(
      'UPDATE vaccination.users SET password_hash = $1 WHERE id = $2',
      [newPasswordHash, userId]
    );

    res.status(200).json({ message: 'Mot de passe mis à jour avec succès' });
  } catch (error) {
    console.error('Erreur modification mot de passe:', error);
    res.status(500).json({ error: 'Erreur modification mot de passe', details: error.message });
  }
});

module.exports = router;
