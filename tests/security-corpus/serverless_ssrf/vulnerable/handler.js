// VULNERABLE: Lambda event.body URL fetched server-side → SSRF.
exports.handler = async (event) => {
  const { url } = JSON.parse(event.body);
  const r = await fetch(url);                 // attacker-controlled URL
  return { statusCode: 200, body: await r.text() };
};
