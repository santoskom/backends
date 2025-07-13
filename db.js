const { Pool } = require('pg');
require('dotenv').config();

const pool = new Pool({
  host: process.env.DB_HOST,
  port: process.env.DB_PORT,
  database: process.env.DB_NAME,
  user: process.env.DB_USER,
  password: process.env.DB_PASSWORD,
});

async function testConnection() {
  try {
    const res = await pool.query('SELECT NOW()');
    return { success: true, time: res.rows[0].now };
  } catch (error) {
    return { success: false, error: error.message };
  }
}

module.exports = {
  pool,
  testConnection,
};
