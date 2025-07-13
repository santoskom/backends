// services/smsService.js

const africastalking = require('africastalking')({
  apiKey: process.env.AT_API_KEY,     // à ajouter dans ton .env
  username: process.env.AT_USERNAME   // souvent 'sandbox' en dev
});

const sms = africastalking.SMS;

async function sendSMS(to, message) {
  try {
    const response = await sms.send({
      to: [`+237${to}`],
      message,
      from: 'VaccinApp' // peut être personnalisé dans le dashboard AT
    });
    console.log('SMS envoyé:', response);
    return { success: true, response };
  } catch (err) {
    console.error('Erreur envoi SMS:', err);
    return { success: false, error: err.message };
  }
}

module.exports = { sendSMS };
