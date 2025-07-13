const nodemailer = require('nodemailer');

async function test() {
  let transporter = nodemailer.createTransport({
    host: 'localhost',
    port: 1025,
    secure: false,
    tls: { rejectUnauthorized: false }
  });

  let info = await transporter.sendMail({
    from: '"Test" <test@localhost>',
    to: 'test@example.com',
    subject: 'Hello ✔',
    text: 'Hello world?'
  });

  console.log('Message sent: %s', info.messageId);
}

test().catch(console.error);
