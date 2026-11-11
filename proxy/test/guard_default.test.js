/* Verhalten ohne TRUST_PROXY - so, wie der Proxy ohne weitere Einstellung
 * startet. X-Forwarded-For wird dann nicht beachtet: alle Anfragen, die ueber
 * denselben vorgeschalteten Proxy kommen, teilen sich ein Rate-Limit.
 * Eigene Datei, weil "trust proxy" beim Laden des Servers gesetzt wird.
 */
const test = require('node:test');
const assert = require('node:assert');
const { startFakeGoogle } = require('./fake_google');

test('ohne TRUST_PROXY wird X-Forwarded-For ignoriert', async () => {
  const google = await startFakeGoogle();
  Object.assign(process.env, {
    GOOGLE_MAPS_API_KEY: 'testschluessel',
    GOOGLE_MAPS_BASE: google.base,
    GOOGLE_PLACES_BASE: google.base,
    RATE_LIMIT_PER_MINUTE: '3',
    PORT: '0',
  });
  delete process.env.TRUST_PROXY;
  delete process.env.CONTROL_CENTER_DATABASE_URL;
  const { app, server } = require('../server');
  await new Promise((r) => (server.listening ? r() : server.once('listening', r)));
  const base = `http://127.0.0.1:${server.address().port}`;
  try {
    assert.strictEqual(app.get('trust proxy'), false);
    const statuses = [];
    for (let i = 0; i < 4; i++) {
      const res = await fetch(`${base}/api/geocode`, {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          Origin: 'https://mexx-music.github.io',
          'X-Forwarded-For': `198.51.100.${i}`,
        },
        body: JSON.stringify({ address: 'A' }),
      });
      statuses.push(res.status);
    }
    // Wechselnde X-Forwarded-For-Werte umgehen das Limit nicht.
    assert.deepStrictEqual(statuses, [200, 200, 200, 429]);
    assert.strictEqual(google.calls.total, 3);
  } finally {
    await new Promise((r) => server.close(r));
    await google.close();
  }
});
