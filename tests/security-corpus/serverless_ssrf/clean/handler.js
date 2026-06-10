// CLEAN: allowlist host before fetch.
const ALLOW = new Set(['api.internal.example.com']);
exports.handler = async (event) => {
  const { url } = JSON.parse(event.body);
  if (!ALLOW.has(new URL(url).host)) return { statusCode: 400, body: 'blocked' };
  const r = await fetch(url);
  return { statusCode: 200, body: await r.text() };
};
