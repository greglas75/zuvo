const jwt = require('jsonwebtoken');
// CLEAN: verify signature with explicit algorithm allowlist (no 'none').
module.exports = (token) => jwt.verify(token, process.env.JWT_SECRET, { algorithms: ['HS256'] });
