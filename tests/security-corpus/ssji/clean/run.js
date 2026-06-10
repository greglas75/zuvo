// CLEAN: no dynamic code execution at all. Accept only a constrained numeric
// value — never evaluate attacker-supplied expressions. (mathjs.evaluate and
// vm/Function are deliberately avoided: they are not safe sandboxes for untrusted input.)
module.exports = (expr) => {
  const n = Number(String(expr).trim());
  if (!Number.isFinite(n)) throw new Error('not a number');
  return n;
};
