const nodemailer = require('nodemailer');
require('dotenv').config();

const transporter = nodemailer.createTransport({
  host: 'localhost',
  port: 1025,
  secure: false,
  tls: { rejectUnauthorized: false }
});

async function sendEmail(to, subject, text) {
  return transporter.sendMail({
    from: process.env.EMAIL_USER || 'no-reply@localhost',
    to,
    subject,
    text
  });
}

module.exports = { sendEmail };
