// CLEAN: null-proto target + __proto__/constructor key denylist.
const BAD = new Set(['__proto__', 'constructor', 'prototype']);
function merge(target, src) {
  for (const k of Object.keys(src)) {                 // own enumerable keys only
    if (BAD.has(k)) continue;
    if (src[k] !== null && typeof src[k] === 'object') {
      target[k] = target[k] || Object.create(null); merge(target[k], src[k]);
    } else target[k] = src[k];
  }
  return target;
}
module.exports = (req) => merge(Object.create(null), req.body);
