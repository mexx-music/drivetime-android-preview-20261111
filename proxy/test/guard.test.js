/* Tests fuer den Schutz der kostenpflichtigen Endpunkte (guard.js).
 *
 * Braucht keine Datenbank. Jeder Test zaehlt die Aufrufe beim Fake-Google
 * und beweist so, dass eine abgewiesene Anfrage nichts gekostet haette.
 *
 * Hier ist TRUST_PROXY=1 gesetzt: der Testclient spielt den einen Proxy vor
 * der App und schreibt die Client-IP in X-Forwarded-For. Das Verhalten ohne
 * TRUST_PROXY steht in guard_default.test.js (eigener Prozess).
 */
const test = require('node:test');
const assert = require('node:assert');
const { startFakeGoogle } = require('./fake_google');
const guard = require('../guard');

const WEB_APP = 'https://mexx-music.github.io';
const LIMIT = 5;

let google;
let app;
let server;
let base;
let clientNo = 0;

// Jeder Test bekommt eine eigene Client-IP und damit ein eigenes Rate-Limit.
const nextClient = () => `10.0.${Math.floor(++clientNo / 250)}.${clientNo % 250}`;

async function boot() {
  google = await startFakeGoogle();
  Object.assign(process.env, {
    GOOGLE_MAPS_API_KEY: 'testschluessel',
    GOOGLE_MAPS_BASE: google.base,
    GOOGLE_PLACES_BASE: google.base,
    // Unerreichbar: der Not-Aus darf davon nicht abhaengen.
    CONTROL_CENTER_DATABASE_URL: 'postgresql://x:y@127.0.0.1:1/cc?sslmode=disable',
    TRUST_PROXY: '1',
    RATE_LIMIT_PER_MINUTE: String(LIMIT),
    GOOGLE_TIMEOUT_MS: '300',
    PORT: '0',
  });
  delete process.env.PAID_CALLS_DISABLED;
  delete process.env.ALLOW_REQUESTS_WITHOUT_ORIGIN;
  ({ app, server } = require('../server'));
  await new Promise((r) => (server.listening ? r() : server.once('listening', r)));
  base = `http://127.0.0.1:${server.address().port}`;
}

/** Alle registrierten Routen unter /api - auch kuenftige. */
function apiRoutes() {
  const out = [];
  for (const layer of app._router.stack) {
    const route = layer.route;
    if (!route || !String(route.path).startsWith('/api')) continue;
    for (const method of Object.keys(route.methods)) {
      out.push({ method: method.toUpperCase(), path: route.path });
    }
  }
  return out;
}

/** Kostenpflichtige Routen: alles unter /api ausser den ausdruecklich
 * ausgenommenen. Eine neue Route ist damit automatisch kostenpflichtig. */
function paidRoutes() {
  return apiRoutes().filter((r) => !guard.NON_PAID_PATHS.has(r.path.replace(/^\/api/, '')));
}

/** Die Maps-Routen, die heute ohne Anmeldung Google aufrufen. */
function mapsRoutes() {
  return paidRoutes().filter((r) => BODIES[r.path] !== undefined);
}

const BODIES = {
  '/api/directions': { origin: 'A', destination: 'B' },
  '/api/geocode': { address: 'A' },
  '/api/autocomplete': { input: 'Lam' },
};

async function call(method, path, { origin = WEB_APP, client = nextClient(), headers = {}, body } = {}) {
  const h = { 'X-Forwarded-For': client, ...headers };
  if (origin !== null) h.Origin = origin;
  let url = `${base}${path}`;
  const init = { method, headers: h };
  if (method === 'GET') {
    url += '?origin=A&destination=B';
  } else if (method !== 'OPTIONS') {
    h['Content-Type'] = 'application/json';
    init.body = body !== undefined ? body : JSON.stringify(BODIES[path] || {});
  }
  const before = google.calls.total;
  const res = await fetch(url, init);
  const text = await res.text();
  return {
    status: res.status,
    text,
    json: (() => { try { return JSON.parse(text); } catch (_) { return null; } })(),
    acao: res.headers.get('access-control-allow-origin'),
    retryAfter: res.headers.get('retry-after'),
    googleCalls: google.calls.total - before,
  };
}

test('Proxy-Schutz', { concurrency: false }, async (t) => {
  await boot();
  t.after(async () => {
    await new Promise((r) => server.close(r));
    await google.close();
  });

  await t.test('nur der Konto-Bootstrap ist vom Not-Aus ausgenommen', () => {
    assert.deepStrictEqual([...guard.NON_PAID_PATHS], ['/account/bootstrap']);
    const all = apiRoutes().map((r) => `${r.method} ${r.path}`);
    assert.ok(all.includes('POST /api/account/bootstrap'));
  });

  await t.test('alle kostenpflichtigen Routen sind bekannt', () => {
    const paths = paidRoutes().map((r) => `${r.method} ${r.path}`).sort();
    assert.deepStrictEqual(paths, [
      'GET /api/directions',
      'POST /api/autocomplete',
      'POST /api/directions',
      'POST /api/geocode',
      'POST /api/tours',
      'POST /api/tours/:id/complete',
      'POST /api/tours/:id/release',
    ]);
  });

  // ------------------------------------------------------------ Not-Aus
  await t.test('Not-Aus ist ohne Einstellung aus', async () => {
    const r = await call('POST', '/api/directions');
    assert.strictEqual(r.status, 200);
    assert.strictEqual(r.googleCalls, 1);
  });

  for (const value of ['1', 'true', 'ON', 'yes']) {
    await t.test(`Not-Aus (${value}): jede /api-Route 503, kein Google-Aufruf`, async () => {
      process.env.PAID_CALLS_DISABLED = value;
      try {
        for (const { method, path } of paidRoutes()) {
          const r = await call(method, path);
          assert.strictEqual(r.status, 503, `${method} ${path}`);
          assert.strictEqual(r.json.error, 'paid_calls_disabled');
          assert.strictEqual(r.retryAfter, '600');
          // Die Web-App kann die Antwort lesen.
          assert.strictEqual(r.acao, WEB_APP);
          assert.strictEqual(r.googleCalls, 0, `${method} ${path}`);
        }
        // Auch ohne Origin und mit fremdem Origin: nichts geht zu Google.
        assert.strictEqual((await call('POST', '/api/directions', { origin: null })).googleCalls, 0);
        assert.strictEqual((await call('POST', '/api/geocode', { origin: 'https://evil.example' })).googleCalls, 0);
      } finally {
        delete process.env.PAID_CALLS_DISABLED;
      }
    });
  }

  await t.test('Not-Aus sperrt den Konto-Bootstrap nicht', async () => {
    process.env.PAID_CALLS_DISABLED = '1';
    try {
      // Ohne Token: 401 von der Anmeldung, nicht 503 vom Not-Aus.
      const r = await call('POST', '/api/account/bootstrap');
      assert.strictEqual(r.status, 401);
      assert.strictEqual(r.googleCalls, 0);
    } finally {
      delete process.env.PAID_CALLS_DISABLED;
    }
  });

  await t.test('Not-Aus: Preflight und /health bleiben erreichbar', async () => {
    process.env.PAID_CALLS_DISABLED = '1';
    try {
      const pre = await call('OPTIONS', '/api/directions', {
        headers: { 'Access-Control-Request-Method': 'POST' },
      });
      assert.strictEqual(pre.status, 204);
      assert.strictEqual(pre.acao, WEB_APP);
      const health = await fetch(`${base}/health`);
      assert.strictEqual(health.status, 200);
    } finally {
      delete process.env.PAID_CALLS_DISABLED;
    }
  });

  await t.test('Not-Aus: andere Werte schalten nicht ab', async () => {
    for (const value of ['', '0', 'false', 'off', 'nein']) {
      process.env.PAID_CALLS_DISABLED = value;
      const r = await call('POST', '/api/directions');
      assert.strictEqual(r.status, 200, `Wert "${value}"`);
    }
    delete process.env.PAID_CALLS_DISABLED;
  });

  // ------------------------------------------------------------- Herkunft
  await t.test('ohne Origin: 403, kein Google-Aufruf', async () => {
    for (const { method, path } of apiRoutes()) {
      const r = await call(method, path, { origin: null });
      assert.strictEqual(r.status, 403, `${method} ${path}`);
      assert.strictEqual(r.json.error, 'origin_not_allowed');
      assert.strictEqual(r.googleCalls, 0);
    }
  });

  await t.test('fremde und vorgetaeuschte Origins: 403, keine CORS-Freigabe', async () => {
    for (const origin of [
      'https://evil.example',
      'http://localhost.evil.example',
      'http://127.0.0.1.nip.io',
      'https://mexx-music.github.io.evil.example',
      'http://mexx-music.github.io',
      'https://localhost',
      'null',
    ]) {
      const r = await call('POST', '/api/directions', { origin });
      assert.strictEqual(r.status, 403, origin);
      assert.strictEqual(r.acao, null, origin);
      assert.strictEqual(r.googleCalls, 0, origin);
      // Knappes JSON statt HTML-Fehlerseite mit Stacktrace.
      assert.deepStrictEqual(r.json, { error: 'origin_not_allowed' });
    }
  });

  await t.test('fremder Origin: Preflight ohne Freigabe, kein Google-Aufruf', async () => {
    const r = await call('OPTIONS', '/api/directions', {
      origin: 'https://evil.example',
      headers: { 'Access-Control-Request-Method': 'POST' },
    });
    assert.strictEqual(r.acao, null);
    assert.strictEqual(r.googleCalls, 0);
  });

  await t.test('Web-App und lokale Entwicklung funktionieren weiter', async () => {
    for (const origin of [
      WEB_APP,
      'http://localhost',
      'http://localhost:5000',
      'http://127.0.0.1:8080',
      'http://localhost:61234',
    ]) {
      for (const { method, path } of mapsRoutes()) {
        const r = await call(method, path, { origin });
        assert.strictEqual(r.status, 200, `${origin} ${method} ${path}`);
        assert.strictEqual(r.acao, origin);
        assert.strictEqual(r.googleCalls, 1);
      }
    }
  });

  await t.test('ALLOW_REQUESTS_WITHOUT_ORIGIN laesst Anfragen ohne Origin zu', async () => {
    process.env.ALLOW_REQUESTS_WITHOUT_ORIGIN = '1';
    try {
      const ok = await call('POST', '/api/directions', { origin: null });
      assert.strictEqual(ok.status, 200);
      // Ein fremder Origin bleibt trotzdem gesperrt.
      const evil = await call('POST', '/api/directions', { origin: 'https://evil.example' });
      assert.strictEqual(evil.status, 403);
    } finally {
      delete process.env.ALLOW_REQUESTS_WITHOUT_ORIGIN;
    }
  });

  await t.test('/health braucht keinen Origin', async () => {
    const r = await fetch(`${base}/health`);
    assert.strictEqual(r.status, 200);
  });

  // ------------------------------------------------------------ Rate-Limit
  await t.test('Rate-Limit je Client-IP, 429 lesbar, kein Google-Aufruf', async () => {
    const a = nextClient();
    for (let i = 0; i < LIMIT; i++) {
      assert.strictEqual((await call('POST', '/api/geocode', { client: a })).status, 200);
    }
    const blocked = await call('POST', '/api/geocode', { client: a });
    assert.strictEqual(blocked.status, 429);
    assert.deepStrictEqual(blocked.json, { error: 'rate_limited' });
    assert.strictEqual(blocked.acao, WEB_APP);
    assert.strictEqual(blocked.googleCalls, 0);

    // Ein anderer Client ist davon nicht betroffen.
    const b = await call('POST', '/api/geocode');
    assert.strictEqual(b.status, 200);
  });

  await t.test('Rate-Limit: vorangestelltes X-Forwarded-For hilft nicht', async () => {
    // Der Proxy haengt die echte IP hinten an; was der Client vorne
    // mitschickt, wechselt bei jedem Versuch.
    const real = nextClient();
    const statuses = [];
    for (let i = 0; i < LIMIT + 2; i++) {
      const r = await call('POST', '/api/geocode', { client: `203.0.113.${i}, ${real}` });
      statuses.push(r.status);
    }
    assert.deepStrictEqual(statuses.slice(LIMIT), [429, 429]);
  });

  await t.test('/health zaehlt nicht zum Rate-Limit', async () => {
    const c = nextClient();
    for (let i = 0; i < LIMIT * 3; i++) {
      const r = await fetch(`${base}/health`, { headers: { 'X-Forwarded-For': c } });
      assert.strictEqual(r.status, 200);
    }
    assert.strictEqual((await call('POST', '/api/geocode', { client: c })).status, 200);
  });

  // ------------------------------------------------ Google-Fehler und Key
  await t.test('Google-Timeout: API-Key und Adressen weder im Log noch in der Antwort', async () => {
    const logged = [];
    const orig = { error: console.error, warn: console.warn, log: console.log };
    for (const k of Object.keys(orig)) console[k] = (...a) => logged.push(a.map(String).join(' '));
    google.setMode('hang');
    try {
      for (const [path, body] of [
        ['/api/geocode', { address: 'Geheimgasse 7, Lambach' }],
        ['/api/directions', { origin: 'Geheimgasse 7, Lambach', destination: 'Hamburg' }],
        ['/api/autocomplete', { input: 'Geheimgasse' }],
      ]) {
        const r = await call('POST', path, { body: JSON.stringify(body) });
        assert.strictEqual(r.status, 500, path);
        assert.ok(!r.text.includes('testschluessel'), `API-Key in Antwort: ${path}`);
        assert.ok(!r.text.includes('Geheimgasse'), `Adresse in Antwort: ${path}`);
      }
    } finally {
      google.setMode('ok');
      Object.assign(console, orig);
    }
    const all = logged.join('\n');
    assert.match(all, /Aufruf fehlgeschlagen \(request-timeout\)/);
    assert.ok(!all.includes('testschluessel'), 'API-Key im Log');
    assert.ok(!all.includes('Geheimgasse'), 'Adresse im Log');
  });

  // --------------------------------------------------------------- Fehler
  await t.test('Geocoding fragt lesbare Namen an: language=de, nur de/en erlaubt', async () => {
    const lang = async (body) => {
      const r = await call('POST', '/api/geocode', { body: JSON.stringify(body) });
      assert.strictEqual(r.status, 200);
      assert.strictEqual(r.googleCalls, 1); // kein zusätzlicher Aufruf
      return google.last.params.language;
    };
    assert.strictEqual(await lang({ address: 'Thessaloniki' }), 'de');
    assert.strictEqual(await lang({ lat: 40.64, lng: 22.94 }), 'de'); // auch rückwärts
    assert.strictEqual(await lang({ address: 'Thessaloniki', language: 'en' }), 'en');
    assert.strictEqual(await lang({ address: 'Thessaloniki', language: 'el' }), 'de');
    assert.strictEqual(await lang({ address: 'X', language: 'de&key=fremd' }), 'de');
    assert.ok(!('key' in google.last.params));
  });

  await t.test('kaputtes JSON: 400 als JSON, kein Stacktrace, kein Google-Aufruf', async () => {
    const r = await call('POST', '/api/directions', { body: '{kaputt' });
    assert.strictEqual(r.status, 400);
    assert.deepStrictEqual(r.json, { error: 'bad_request' });
    assert.strictEqual(r.googleCalls, 0);
  });
});

test('trustProxySetting', () => {
  // Ohne Angabe: siehe guard_default.test.js.
  assert.strictEqual(guard.trustProxySetting(''), false);
  assert.strictEqual(guard.trustProxySetting('  '), false);
  assert.strictEqual(guard.trustProxySetting('2'), 2);
  assert.strictEqual(guard.trustProxySetting('loopback'), 'loopback');
  // "true" wuerde jeder vom Client gesetzten Adresse glauben.
  assert.strictEqual(guard.trustProxySetting('true'), false);
});
