/* Tests fuer die verbindliche Kostenkontrolle (tours.js) im Proxy.
 *
 * Jeder Test zaehlt die Aufrufe beim Ersatz-Google: abgewiesene Anfragen
 * duerfen dort NIE ankommen. Die Touren laufen gegen die echten
 * Datenbankfunktionen aus Migration 0007.
 *
 * Braucht CONTROL_CENTER_TEST_URL (lokale Wegwerf-Datenbank mit
 * auth_stub.sql und allen Migrationen). Setzt dort fuer drivetime/free ein
 * Test-Kontingent und nimmt es am Ende wieder heraus.
 */
const test = require('node:test');
const assert = require('node:assert');
const http = require('http');
const { randomUUID } = require('crypto');
const { generateKeyPair, exportJWK, SignJWT } = require('jose');
const { startFakeGoogle } = require('./fake_google');

const DB_URL = process.env.CONTROL_CENTER_TEST_URL;
const skip = DB_URL ? false : 'CONTROL_CENTER_TEST_URL nicht gesetzt';
const WEB_APP = 'https://mexx-music.github.io';

test('Touren und Aufrufbudget im Proxy', { skip, concurrency: false }, async (t) => {
  // ------------------------------------------------------------- Aufbau
  const { publicKey, privateKey } = await generateKeyPair('ES256', { extractable: true });
  const jwk = { ...(await exportJWK(publicKey)), kid: 'k1', alg: 'ES256', use: 'sig' };
  const jwks = http.createServer((req, res) => {
    res.writeHead(200, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify({ keys: [jwk] }));
  });
  await new Promise((r) => jwks.listen(0, '127.0.0.1', r));
  const supabaseUrl = `http://127.0.0.1:${jwks.address().port}`;

  const google = await startFakeGoogle();
  Object.assign(process.env, {
    SUPABASE_URL: supabaseUrl,
    GOOGLE_MAPS_API_KEY: 'testschluessel',
    GOOGLE_MAPS_BASE: google.base,
    GOOGLE_PLACES_BASE: google.base,
    CONTROL_CENTER_DATABASE_URL: DB_URL,
    CONTROL_CENTER_TEST: '1',
    GOOGLE_TIMEOUT_MS: '400',
    PORT: '0',
  });
  delete process.env.TOURS_REQUIRED;
  delete process.env.PAID_CALLS_DISABLED;

  const mod = require('../server');
  const { server, telemetry } = mod;
  const ccdb = require('../ccdb');
  await new Promise((r) => (server.listening ? r() : server.once('listening', r)));
  const base = `http://127.0.0.1:${server.address().port}`;

  const { Client } = require('pg');
  const pg = new Client({ connectionString: DB_URL,
    ssl: DB_URL.includes('sslmode=disable') ? false : { rejectUnauthorized: false } });
  await pg.connect();
  const q = async (sql, params) => (await pg.query(sql, params)).rows;
  const users = [];

  t.after(async () => {
    await telemetry._drain();
    await q(`delete from cc.plan_quotas where plan_key = 'free'
               and project_id = (select id from cc.projects where key = 'drivetime')`);
    if (users.length) await q('delete from auth.users where id = any($1::uuid[])', [users]);
    await pg.end();
    await ccdb._reset();
    await telemetry._reset();
    await new Promise((r) => server.close(r));
    await google.close();
    await new Promise((r) => jwks.close(r));
  });

  // ------------------------------------------------------------- Hilfen
  async function setQuota(tours, calls, active = true) {
    await q(`insert into cc.plan_quotas (project_id, plan_key, tours_per_period, max_calls_per_tour,
                                         tour_ttl, active)
             select id, 'free', $1, $2, interval '10 minutes', $3 from cc.projects where key = 'drivetime'
             on conflict (project_id, plan_key) do update
               set tours_per_period = excluded.tours_per_period,
                   max_calls_per_tour = excluded.max_calls_per_tour,
                   tour_ttl = excluded.tour_ttl, active = excluded.active`,
      [tours, calls, active]);
  }

  async function tokenFor(sub) {
    const now = Math.floor(Date.now() / 1000);
    return new SignJWT({ role: 'authenticated', is_anonymous: false })
      .setProtectedHeader({ alg: 'ES256', kid: 'k1' })
      .setIssuer(`${supabaseUrl}/auth/v1`).setAudience('authenticated').setSubject(sub)
      .setIssuedAt(now).setExpirationTime(now + 600)
      .sign(privateKey);
  }

  async function post(path, { token, body = {}, headers = {} } = {}) {
    const h = { 'Content-Type': 'application/json', Origin: WEB_APP, ...headers };
    if (token) h.Authorization = `Bearer ${token}`;
    const before = google.calls.total;
    const res = await fetch(`${base}${path}`, { method: 'POST', headers: h, body: JSON.stringify(body) });
    const text = await res.text();
    let json = null;
    try { json = JSON.parse(text); } catch (_) { /* leer */ }
    return { status: res.status, json, google: google.calls.total - before };
  }

  // Ein neuer, angemeldeter Nutzer mit Konto und Free-Entitlement.
  async function newUser() {
    const id = randomUUID();
    users.push(id);
    await q('insert into auth.users (id) values ($1)', [id]);
    const token = await tokenFor(id);
    const b = await post('/api/account/bootstrap', { token });
    assert.strictEqual(b.status, 200);
    return { id, token };
  }

  const reserve = (u, key = randomUUID(), extra = {}) =>
    post('/api/tours', { token: u.token, body: { idempotency_key: key, ...extra } });
  const directions = (u, tourId, extra = {}) =>
    post('/api/directions', { token: u && u.token,
      body: { origin: 'Lambach', destination: 'Hamburg', ...(tourId ? { tour_id: tourId } : {}), ...extra } });
  const tourRow = async (id) => (await q(
    `select state, calls_used, calls_in_flight, call_budget, user_id, plan_key,
            completed_at is not null as completed
       from cc.tours where id = $1`, [id]))[0];

  // ------------------------------------------------ bestehender Betrieb
  await t.test('ohne Tour und ohne Anmeldung: Maps wie bisher (Live-App)', async () => {
    const r = await directions(null, null);
    assert.strictEqual(r.status, 200);
    assert.strictEqual(r.google, 1);
  });

  // --------------------------------------------- kein Google ohne Recht
  await t.test('tour_id ohne JWT: 401, kein Google-Aufruf', async () => {
    const r = await directions(null, randomUUID());
    assert.strictEqual(r.status, 401);
    assert.strictEqual(r.google, 0);
  });

  await t.test('angemeldet, Directions ohne Tour: 428, kein Google-Aufruf', async () => {
    const u = await newUser();
    const r = await directions(u, null);
    assert.strictEqual(r.status, 428);
    assert.deepStrictEqual(r.json, { error: 'tour_required' });
    assert.strictEqual(r.google, 0);
  });

  await t.test('TOURS_REQUIRED: Directions ohne Tour 428, auch ohne Anmeldung', async () => {
    process.env.TOURS_REQUIRED = '1';
    try {
      const r = await directions(null, null);
      assert.strictEqual(r.status, 428);
      assert.strictEqual(r.google, 0);
      const g = await post('/api/directions', { body: { origin: 'A', destination: 'B', tour_id: 'kein-uuid' } });
      assert.strictEqual(g.status, 428);
      assert.strictEqual(g.google, 0);
    } finally {
      delete process.env.TOURS_REQUIRED;
    }
  });

  await t.test('unbekannte oder fremde Tour: 404, kein Google-Aufruf', async () => {
    await setQuota(5, 4);
    const a = await newUser();
    const b = await newUser();
    const tourA = (await reserve(a)).json.tour_id;
    let r = await directions(b, tourA);
    assert.strictEqual(r.status, 404);
    assert.deepStrictEqual(r.json, { error: 'tour_not_found' });
    assert.strictEqual(r.google, 0);
    r = await directions(a, randomUUID());
    assert.strictEqual(r.status, 404);
    assert.strictEqual(r.google, 0);
    assert.strictEqual((await tourRow(tourA)).calls_used, 0);
  });

  await t.test('ohne Kontingent-Konfiguration: Reservierung 403, fail closed', async () => {
    await setQuota(5, 4, false);
    const u = await newUser();
    const r = await reserve(u);
    assert.strictEqual(r.status, 403);
    assert.deepStrictEqual(r.json, { error: 'quota_not_configured' });
  });

  // -------------------------------------------------------- Normalfall
  await t.test('Reservieren und rechnen: ein Aufruf, Tour verbraucht, Telemetrie an der Tour', async () => {
    await setQuota(5, 4);
    const u = await newUser();
    const res = await reserve(u);
    assert.strictEqual(res.status, 201);
    assert.deepStrictEqual(Object.keys(res.json).sort(),
      ['call_budget', 'calls_used', 'completed', 'expires_at', 'period_end', 'state',
       'tour_id', 'tours_limit', 'tours_used']);
    const tour = res.json.tour_id;
    const r = await directions(u, tour, { cc_work_unit: randomUUID() }); // falsche Zuordnung vom Client
    assert.strictEqual(r.status, 200);
    assert.strictEqual(r.google, 1);
    assert.strictEqual(r.json.status, 'OK');
    const row = await tourRow(tour);
    assert.deepStrictEqual([row.state, row.calls_used, row.calls_in_flight], ['consumed', 1, 0]);
    await telemetry._drain();
    const ev = await q('select count(*)::int as n from cc.usage_events where work_unit_id = $1', [tour]);
    assert.strictEqual(ev[0].n, 1, 'Telemetrie haengt an der Tour, nicht an der Client-Kennung');
  });

  await t.test('Faehrroute: mehrere Directions in derselben Tour', async () => {
    await setQuota(5, 8);
    const u = await newUser();
    const tour = (await reserve(u)).json.tour_id;
    const legs = [
      { origin: 'Lambach', destination: 'Oslo', alternatives: true },
      { origin: 'Lambach', destination: 'Oslo', avoid: 'ferries' },
      { origin: 'Lambach', destination: 'Kiel', avoid: 'ferries' },
      { origin: 'Oslo', destination: 'Oslo', avoid: 'ferries' },
    ];
    for (const leg of legs) {
      const r = await directions(u, tour, { ...leg, cc_work_kind: 'route_ferry' });
      assert.strictEqual(r.status, 200);
      assert.strictEqual(r.google, 1);
    }
    const row = await tourRow(tour);
    assert.deepStrictEqual([row.state, row.calls_used, row.calls_in_flight], ['consumed', 4, 0]);
    await telemetry._drain();
    const wu = await q('select kind from cc.work_units where id = $1', [tour]);
    assert.strictEqual(wu[0].kind, 'route_ferry');
    // Eine Tour, egal wie viele Aufrufe.
    const count = await q(`select count(*)::int as n from cc.tours t
                             join cc.accounts a on a.id = t.account_id where a.personal_owner = $1`, [u.id]);
    assert.strictEqual(count[0].n, 1);
  });

  await t.test('Geocoding und Autocomplete mit tour_id gehen ins Budget derselben Tour', async () => {
    await setQuota(5, 4);
    const u = await newUser();
    const tour = (await reserve(u)).json.tour_id;
    let r = await post('/api/geocode', { token: u.token, body: { address: 'Lambach', tour_id: tour } });
    assert.strictEqual(r.status, 200);
    r = await post('/api/autocomplete', { token: u.token, body: { input: 'Lam', tour_id: tour } });
    assert.strictEqual(r.status, 200);
    assert.strictEqual((await tourRow(tour)).calls_used, 2);
    // Ohne tour_id bleibt die Adresseingabe wie bisher (Eingabe-Limits: eigener Schritt).
    r = await post('/api/geocode', { body: { address: 'Lambach' } });
    assert.strictEqual(r.status, 200);
  });

  // ------------------------------------------------------------ Grenzen
  await t.test('Aufrufbudget erschoepft: 429, kein Google-Aufruf', async () => {
    await setQuota(5, 2);
    const u = await newUser();
    const tour = (await reserve(u)).json.tour_id;
    assert.strictEqual((await directions(u, tour)).google, 1);
    assert.strictEqual((await directions(u, tour)).google, 1);
    const r = await directions(u, tour);
    assert.strictEqual(r.status, 429);
    assert.deepStrictEqual(r.json, { error: 'call_budget_exhausted' });
    assert.strictEqual(r.google, 0);
    assert.strictEqual((await tourRow(tour)).calls_used, 2);
  });

  await t.test('Tour-Kontingent erschoepft: 402, keine neue Tour, kein Google-Aufruf', async () => {
    await setQuota(2, 4);
    const u = await newUser();
    assert.strictEqual((await reserve(u)).status, 201);
    assert.strictEqual((await reserve(u)).status, 201);
    const r = await reserve(u);
    assert.strictEqual(r.status, 402);
    assert.strictEqual(r.json.error, 'quota_exhausted');
    assert.strictEqual(r.json.tours_used, 2);
    assert.strictEqual(r.json.tours_limit, 2);
    assert.strictEqual(r.google, 0);
  });

  await t.test('manipulierte Clientdaten werden ignoriert', async () => {
    await setQuota(5, 3);
    const u = await newUser();
    const other = await newUser();
    const r = await reserve(u, randomUUID(), {
      user_id: other.id, account_id: randomUUID(), plan_key: 'fleet',
      call_budget: 999, tours_per_period: 999, state: 'consumed',
    });
    assert.strictEqual(r.status, 201);
    assert.strictEqual(r.json.call_budget, 3);
    const row = await tourRow(r.json.tour_id);
    assert.strictEqual(row.user_id, u.id);
    assert.strictEqual(row.plan_key, 'free');
    assert.strictEqual(row.call_budget, 3);
    const d = await directions(u, r.json.tour_id, { user_id: other.id, call_budget: 999, calls_used: 0 });
    assert.strictEqual(d.status, 200);
    assert.strictEqual((await tourRow(r.json.tour_id)).calls_used, 1);
    const otherTours = await q(`select count(*)::int as n from cc.tours t join cc.accounts a on a.id = t.account_id
                                 where a.personal_owner = $1`, [other.id]);
    assert.strictEqual(otherTours[0].n, 0);
  });

  await t.test('Idempotenz: gleicher Schluessel liefert dieselbe Tour', async () => {
    await setQuota(5, 3);
    const u = await newUser();
    const key = randomUUID();
    const a = await reserve(u, key);
    const b = await reserve(u, key);
    assert.deepStrictEqual([a.status, b.status], [201, 200]);
    assert.strictEqual(a.json.tour_id, b.json.tour_id);
  });

  // ---------------------------------------------------------- Parallelitaet
  await t.test('10 gleichzeitige Aufrufe bei Budget 4: genau 4 bei Google', async () => {
    await setQuota(5, 4);
    const u = await newUser();
    const tour = (await reserve(u)).json.tour_id;
    const before = google.calls.total;
    const results = await Promise.all(Array.from({ length: 10 }, () => directions(u, tour)));
    const ok = results.filter((r) => r.status === 200).length;
    const denied = results.filter((r) => r.status === 429).length;
    assert.deepStrictEqual([ok, denied], [4, 6]);
    assert.strictEqual(google.calls.total - before, 4);
    const row = await tourRow(tour);
    assert.deepStrictEqual([row.calls_used, row.calls_in_flight], [4, 0]);
  });

  await t.test('letzter freier Platz, 6 gleichzeitige Reservierungen: genau eine', async () => {
    await setQuota(1, 3);
    const u = await newUser();
    const results = await Promise.all(Array.from({ length: 6 }, () => reserve(u)));
    assert.strictEqual(results.filter((r) => r.status === 201).length, 1);
    assert.strictEqual(results.filter((r) => r.status === 402).length, 5);
  });

  await t.test('gleicher Schluessel, 6 gleichzeitige Reservierungen: eine Tour', async () => {
    await setQuota(5, 3);
    const u = await newUser();
    const key = randomUUID();
    const results = await Promise.all(Array.from({ length: 6 }, () => reserve(u, key)));
    assert.ok(results.every((r) => r.status === 200 || r.status === 201));
    assert.strictEqual(new Set(results.map((r) => r.json.tour_id)).size, 1);
  });

  // ------------------------------------------------- Fehler und Abschluss
  await t.test('Google-Fehler: Aufruf abgeschlossen, Tour bleibt freigebbar', async () => {
    await setQuota(5, 4);
    const u = await newUser();
    const tour = (await reserve(u)).json.tour_id;
    google.setMode('http_error');
    try {
      const r = await directions(u, tour);
      assert.strictEqual(r.google, 1);
    } finally {
      google.setMode('ok');
    }
    const row = await tourRow(tour);
    assert.deepStrictEqual([row.state, row.calls_used, row.calls_in_flight], ['reserved', 1, 0]);
    const rel = await post(`/api/tours/${tour}/release`, { token: u.token });
    assert.strictEqual(rel.status, 200);
    assert.strictEqual((await tourRow(tour)).state, 'released');
    const again = await directions(u, tour);
    assert.strictEqual(again.status, 409);
    assert.strictEqual(again.google, 0);
  });

  await t.test('Google-Timeout: Aufruf wird trotzdem abgeschlossen', async () => {
    await setQuota(5, 4);
    const u = await newUser();
    const tour = (await reserve(u)).json.tour_id;
    google.setMode('hang');
    try {
      const r = await directions(u, tour);
      assert.strictEqual(r.status, 500);
    } finally {
      google.setMode('ok');
    }
    const row = await tourRow(tour);
    assert.deepStrictEqual([row.state, row.calls_used, row.calls_in_flight], ['reserved', 1, 0]);
    // Retry in derselben Tour, keine neue Tour.
    const retry = await directions(u, tour);
    assert.strictEqual(retry.status, 200);
    assert.strictEqual((await tourRow(tour)).state, 'consumed');
  });

  await t.test('Timeout NACH erstem Erfolg: Tour bleibt verbraucht, Retry in derselben Tour', async () => {
    await setQuota(5, 4);
    const u = await newUser();
    const tour = (await reserve(u)).json.tour_id;
    assert.strictEqual((await directions(u, tour)).status, 200);
    google.setMode('hang');
    try {
      assert.strictEqual((await directions(u, tour)).status, 500);
    } finally {
      google.setMode('ok');
    }
    const rel = await post(`/api/tours/${tour}/release`, { token: u.token });
    assert.strictEqual(rel.status, 409);
    assert.deepStrictEqual(rel.json, { error: 'consumed' });
    assert.strictEqual((await directions(u, tour)).status, 200);
    const row = await tourRow(tour);
    assert.deepStrictEqual([row.state, row.calls_used, row.calls_in_flight], ['consumed', 3, 0]);
  });

  await t.test('Abschliessen: danach keine Aufrufe mehr', async () => {
    await setQuota(5, 4);
    const u = await newUser();
    const tour = (await reserve(u)).json.tour_id;
    const early = await post(`/api/tours/${tour}/complete`, { token: u.token });
    assert.strictEqual(early.status, 409);
    await directions(u, tour);
    const done = await post(`/api/tours/${tour}/complete`, { token: u.token });
    assert.strictEqual(done.status, 200);
    assert.strictEqual(done.json.status, 'completed');
    const r = await directions(u, tour);
    assert.strictEqual(r.status, 409);
    assert.deepStrictEqual(r.json, { error: 'tour_completed' });
    assert.strictEqual(r.google, 0);
    const foreign = await post(`/api/tours/${tour}/complete`, { token: (await newUser()).token });
    assert.strictEqual(foreign.status, 404);
  });

  await t.test('Datenbank nicht erreichbar: 503, kein Google-Aufruf', async () => {
    await setQuota(5, 4);
    const u = await newUser();
    const tour = (await reserve(u)).json.tour_id;
    await ccdb._reset();
    process.env.CONTROL_CENTER_DATABASE_URL = 'postgresql://x:y@127.0.0.1:1/cc?sslmode=disable';
    try {
      const r = await directions(u, tour);
      assert.strictEqual(r.status, 503);
      assert.deepStrictEqual(r.json, { error: 'quota_unavailable' });
      assert.strictEqual(r.google, 0);
      const res = await reserve(u);
      assert.strictEqual(res.status, 503);
      assert.strictEqual(res.google, 0);
    } finally {
      await ccdb._reset();
      process.env.CONTROL_CENTER_DATABASE_URL = DB_URL;
    }
    assert.strictEqual((await tourRow(tour)).calls_used, 0);
  });

  await t.test('Not-Aus schlaegt auch im Tour-Modus vor allem anderen zu', async () => {
    await setQuota(5, 4);
    const u = await newUser();
    const tour = (await reserve(u)).json.tour_id;
    process.env.PAID_CALLS_DISABLED = '1';
    try {
      const r = await directions(u, tour);
      assert.strictEqual(r.status, 503);
      assert.strictEqual(r.google, 0);
    } finally {
      delete process.env.PAID_CALLS_DISABLED;
    }
    assert.strictEqual((await tourRow(tour)).calls_used, 0);
  });
});
