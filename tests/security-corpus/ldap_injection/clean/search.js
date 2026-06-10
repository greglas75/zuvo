// CLEAN: RFC4515 filter-value escaping before building the filter.
const { escapeFilter } = require('ldap-escape');
module.exports = (client, username) =>
  client.search('ou=users,dc=corp', { filter: escapeFilter`(uid=${username})` });
