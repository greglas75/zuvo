const vm = require('vm');
// VULNERABLE: executes attacker input as code.
module.exports = (expr) => vm.runInNewContext(expr);
