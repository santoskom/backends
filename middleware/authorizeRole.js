module.exports = (roles) => {
    return (req, res, next) => {
        if (!roles.includes(req.user.user_type_code)) {
            return res.status(403).json({ error: 'Accès interdit pour ce rôle' });
        }
        next();
    };
};
