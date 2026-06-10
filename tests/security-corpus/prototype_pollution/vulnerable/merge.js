// VULNERABLE: recursive merge of untrusted body pollutes Object.prototype.
function merge(target, src) {
  for (const k in src) {
    if (typeof src[k] === 'object') { target[k] = target[k] || {}; merge(target[k], src[k]); }
    else target[k] = src[k];                       // no __proto__ guard
  }
  return target;
}
module.exports = (req) => merge({}, req.body);
