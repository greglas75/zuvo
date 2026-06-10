// VULNERABLE: user input concatenated straight into the LDAP filter.
module.exports = (client, username) =>
  client.search('ou=users,dc=corp', { filter: '(uid=' + username + ')' });
