// CLEAN: linear-time engine + type guard + input length cap.
const RE2 = require('re2');
const RE = new RE2(/^\w[\w ]{0,200}$/);
module.exports = (input) => typeof input === 'string' && input.length <= 256 && RE.test(input);
