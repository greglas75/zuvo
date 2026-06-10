const jwt = require('jsonwebtoken');
// VULNERABLE: decode without verifying signature; trusts attacker token.
module.exports = (token) => jwt.decode(token);
