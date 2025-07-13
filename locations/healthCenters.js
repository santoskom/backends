const express = require('express');
const router = express.Router();
const bcrypt = require('bcrypt');
const jwt = require('jsonwebtoken');
const pool = require('../db');
const logger = require('../logger');

router.get('/api/auth/health-centers', async (req, res) => {
    const client = await pool.connect();
    try {
        const result = await client.query(
            `SELECT hc.id, hc.center_name, hc.address, d.district_name, r.region_name
             FROM vaccination.health_centers hc
             JOIN vaccination.districts d ON hc.district_id = d.id
             JOIN vaccination.regions r ON d.region_id = r.id
             WHERE hc.is_active = true
             ORDER BY r.region_name, d.district_name, hc.center_name`
        );
        res.json({ health_centers: result.rows });
    } catch (error) {
        logger.error('Erreur lors de la récupération des centres de santé:', error);
        res.status(500).json({ error: 'Erreur interne du serveur' });
    } finally {
        client.release();
    }
});


module.exports = router;