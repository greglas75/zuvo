// CLEAN: explicit field allowlist (DTO pick).
module.exports = (User, req) => {
  const { name, email } = req.body;            // only safe fields
  return User.create({ name, email });
};
