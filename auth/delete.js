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
      return res.status(401).json({ error: 'Mot de passe incorrect' });
    }

    await pool.query('BEGIN');

    await pool.query('DELETE FROM vaccination.side_effects WHERE reported_by = $1', [userId]);
    await pool.query(`
      DELETE FROM vaccination.vaccinations 
      WHERE vaccination_card_id IN (
        SELECT id FROM vaccination.vaccination_cards 
        WHERE user_id = $1 OR family_member_id IN (
          SELECT id FROM vaccination.family_members WHERE user_id = $1
        )
      )`, [userId]);

    await pool.query(`
      DELETE FROM vaccination.reminders 
      WHERE vaccination_card_id IN (
        SELECT id FROM vaccination.vaccination_cards WHERE user_id = $1
      )`, [userId]);

    await pool.query('DELETE FROM vaccination.vaccination_cards WHERE user_id = $1 OR family_member_id IN (SELECT id FROM vaccination.family_members WHERE user_id = $1)', [userId]);

    await pool.query('DELETE FROM vaccination.family_members WHERE user_id = $1', [userId]);
    await pool.query('DELETE FROM vaccination.audit_logs WHERE changed_by = $1', [userId]);
    await pool.query('DELETE FROM vaccination.users WHERE id = $1', [userId]);

    await pool.query('COMMIT');

    res.status(200).json({ message: 'Compte supprimé avec succès' });
  } catch (error) {
    await pool.query('ROLLBACK');
    console.error('Erreur suppression compte:', error);
    res.status(500).json({ error: 'Erreur suppression compte', details: error.message });
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
