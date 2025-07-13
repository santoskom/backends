// routes/sendMail.js
const express = require('express');
const router = express.Router();
const { sendEmail } = require('../services/mailer');

router.post('/', async (req, res) => {
  const { to, subject, message } = req.body;
  try {
    await sendEmail(to, subject, message);
    res.status(200).json({ success: true, message: 'Email envoyé avec succès' });
  } catch (error) {
    console.error('Erreur envoi mail:', error);
    res.status(500).json({ success: false, error: error.message });
  }
});

module.exports = router;
