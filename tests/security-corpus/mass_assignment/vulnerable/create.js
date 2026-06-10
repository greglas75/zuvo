// VULNERABLE: whole request body bound to model → over-post role/isAdmin.
module.exports = (User, req) => User.create(req.body);
