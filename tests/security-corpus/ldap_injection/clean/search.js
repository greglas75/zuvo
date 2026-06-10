// CLEAN: validate input is a non-empty string, then RFC4515-escape the filter value.
const { escapeFilter } = require('ldap-escape');
module.exports = (client, username) => {
  if (typeof username !== 'string' || username.length === 0) throw new Error('invalid username');
  return client.search('ou=users,dc=corp', { filter: escapeFilter`(uid=${username})` });
};
