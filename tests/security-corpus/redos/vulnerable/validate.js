// VULNERABLE: nested quantifier on user input → catastrophic backtracking.
const RE = /^(\w+\s?)+$/;                          // (x+)+ class
module.exports = (input) => RE.test(input);
