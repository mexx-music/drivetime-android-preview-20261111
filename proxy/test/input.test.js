/* Tests fuer das Tagesbudget der Adresseingabe (cc.try_input_call).
 *
 * Angemeldete Autocomplete-/Geocoding-Aufrufe ausserhalb einer Tour zaehlen
 * gegen input_calls_per_day des Kontos. Jeder Test zaehlt die Aufrufe beim
 * Ersatz-Google: abgelehnte Anfragen duerfen dort nie ankommen.
 *
 * Braucht CONTROL_CENTER_TEST_URL (Wegwerf-DB mit allen Migrationen).
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

test('Tagesbudget der Adresseingabe', { skip, concurrency: false }, async (t) => {
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
    RATE_LIMIT_PER_MINUTE: '1000',
    PORT: '0',
  });
  delete process.env.TOURS_REQUIRED;
  delete process.env.PAID_CALLS_DISABLED;

  const { server, telemetry } = require('../server');
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
    if (users.length) {
      await q(`delete from cc.counters where scope = 'account' and scope_key in
                 (select id::text from cc.accounts where personal_owner = any($1::uuid[]))`, [users]);
      await q('delete from auth.users where id = any($1::uuid[])', [users]);
    }
    await pg.end();
    await ccdb._reset();
    await telemetry._reset();
    await new Promise((r) => server.close(r));
    await google.close();
    await new Promise((r) => jwks.close(r));
  });

  async function setQuota(inputPerDay, { tours = 5 } = {}) {
    await q(`insert into cc.plan_quotas (project_id, plan_key, tours_per_period, max_calls_per_tour,
                                         tour_ttl, input_calls_per_day, active)
             select id, 'free', $1, 4, interval '10 minutes', $2, true from cc.projects where key = 'drivetime'
             on conflict (project_id, plan_key) do update
               set tours_per_period = excluded.tours_per_period, max_calls_per_tour = excluded.max_calls_per_tour,
                   tour_ttl = excluded.tour_ttl, input_calls_per_day = excluded.input_calls_per_day,
                   active = true`,
      [tours, inputPerDay]);
  }

  async function tokenFor(sub) {
    const now = Math.floor(Date.now() / 1000);
    return new SignJWT({ role: 'authenticated', is_anonymous: false })
      .setProtectedHeader({ alg: 'ES256', kid: 'k1' })
      .setIssuer(`${supabaseUrl}/auth/v1`).setAudience('authenticated').setSubject(sub)
      .setIssuedAt(now).setExpirationTime(now + 600).sign(privateKey);
  }

  async function post(path, { token, body = {} } = {}) {
    const h = { 'Content-Type': 'application/json', Origin: WEB_APP };
    if (token) h.Authorization = `Bearer ${token}`;
    const before = google.calls.total;
    const res = await fetch(`${base}${path}`, { method: 'POST', headers: h, body: JSON.stringify(body) });
    const text = await res.text();
    let json = null;
    try { json = JSON.parse(text); } catch (_) { /* leer */ }
    return { status: res.status, json, google: google.calls.total - before };
  }

  async function newUser() {
    const id = randomUUID();
    users.push(id);
    await q('insert into auth.users (id) values ($1)', [id]);
    const token = await tokenFor(id);
    assert.strictEqual((await post('/api/account/bootstrap', { token })).status, 200);
    return { id, token };
  }

  const used = async (u) => Number((await q(
    `select coalesce(sum(c.quantity), 0) as n from cc.counters c join cc.accounts a on a.id::text = c.scope_key
      where a.personal_owner = $1 and c.scope = 'account'
        and c.period = to_char(now() at time zone 'UTC', 'YYYY-MM-DD')`, [u.id]))[0].n);
  const tourCount = async () => Number((await q('select count(*) as n from cc.tours'))[0].n);

  const autocomplete = (u, extra = {}) =>
    post('/api/autocomplete', { token: u && u.token, body: { input: 'Lam', ...extra } });
  const geocode = (u, extra = {}) =>
    post('/api/geocode', { token: u && u.token, body: { address: 'Lambach', ...extra } });

  // ------------------------------------------------------ öffentlich
  await t.test('ohne Token: öffentlicher Weg wie bisher, kein Zähler', async () => {
    await setQuota(1);
    const a = await autocomplete(null);
    const g = await geocode(null);
    assert.deepStrictEqual([a.status, g.status, a.google, g.google], [200, 200, 1, 1]);
    const c = await q(`select count(*)::int as n from cc.counters where scope = 'account'`);
    assert.strictEqual(c[0].n, 0);
  });

  // ------------------------------------------------------ angemeldet
  await t.test('angemeldetes Autocomplete: genau ein Input-Call', async () => {
    await setQuota(5);
    const u = await newUser();
    const r = await autocomplete(u);
    assert.deepStrictEqual([r.status, r.google], [200, 1]);
    assert.strictEqual(await used(u), 1);
  });

  await t.test('angemeldetes Geocoding (Adresse und Rückwärts): je ein Input-Call', async () => {
    await setQuota(5);
    const u = await newUser();
    assert.strictEqual((await geocode(u)).google, 1);
    const rev = await post('/api/geocode', { token: u.token, body: { lat: 48.09, lng: 13.87 } });
    assert.deepStrictEqual([rev.status, rev.google], [200, 1]);
    assert.strictEqual(await used(u), 2);
  });

  await t.test('gemeinsames Tagesbudget: am Limit Ablehnung vor Google', async () => {
    await setQuota(3);
    const u = await newUser();
    assert.strictEqual((await autocomplete(u)).google, 1);
    assert.strictEqual((await geocode(u)).google, 1);
    assert.strictEqual((await autocomplete(u)).google, 1);
    // Clientfelder versuchen, Plan und Limit zu überschreiben.
    const manipulated = { plan_key: 'fleet', input_calls_per_day: 999, limit: 999, used: 0 };
    const a = await autocomplete(u, manipulated);
    const g = await geocode(u, manipulated);
    assert.deepStrictEqual([a.status, a.json], [429, { error: 'input_budget_exhausted' }]);
    assert.deepStrictEqual([g.status, g.json], [429, { error: 'input_budget_exhausted' }]);
    assert.deepStrictEqual([a.google, g.google], [0, 0]);
    assert.strictEqual(await used(u), 3);
  });

  await t.test('manipulierte Nutzer-/Kontofelder zählen trotzdem beim eigenen Konto', async () => {
    await setQuota(5);
    const u = await newUser();
    const other = await newUser();
    const otherAccount = (await q('select id from cc.accounts where personal_owner = $1', [other.id]))[0].id;
    const r = await autocomplete(u, { user_id: other.id, account_id: otherAccount, sub: other.id });
    assert.strictEqual(r.status, 200);
    assert.strictEqual(await used(u), 1);
    assert.strictEqual(await used(other), 0);
  });

  await t.test('12 gleichzeitige, gemischte Aufrufe bei Limit 5: genau 5 bei Google (5 Runden)', async () => {
    await setQuota(5);
    for (let round = 0; round < 5; round++) {
      const u = await newUser();
      const before = google.calls.total;
      const results = await Promise.all(Array.from({ length: 12 }, (_, i) =>
        (i % 2 === 0 ? autocomplete(u) : geocode(u))));
      const ok = results.filter((r) => r.status === 200).length;
      const denied = results.filter((r) => r.status === 429).length;
      assert.deepStrictEqual([ok, denied], [5, 7], `Runde ${round}`);
      assert.strictEqual(google.calls.total - before, 5, `Runde ${round}`);
      assert.strictEqual(await used(u), 5, `Runde ${round}`);
    }
  });

  // ------------------------------------------------------ fail closed
  await t.test('ungültiges Token: 401, kein Google, kein öffentlicher Ersatz', async () => {
    await setQuota(5);
    const r = await post('/api/autocomplete', { token: 'aaa.bbb.ccc', body: { input: 'Lam' } });
    assert.deepStrictEqual([r.status, r.google], [401, 0]);
    const g = await post('/api/geocode', { token: 'aaa.bbb.ccc', body: { address: 'Lambach' } });
    assert.deepStrictEqual([g.status, g.google], [401, 0]);
  });

  await t.test('ohne Eingabe-Kontingent (NULL): 403, kein Google', async () => {
    await setQuota(null);
    const u = await newUser();
    const r = await autocomplete(u);
    assert.deepStrictEqual([r.status, r.json, r.google], [403, { error: 'input_quota_not_configured' }, 0]);
  });

  await t.test('Datenbank nicht erreichbar: 503, kein Google', async () => {
    await setQuota(5);
    const u = await newUser();
    await ccdb._reset();
    process.env.CONTROL_CENTER_DATABASE_URL = 'postgresql://x:y@127.0.0.1:1/cc?sslmode=disable';
    try {
      const a = await autocomplete(u);
      const g = await geocode(u);
      assert.deepStrictEqual([a.status, g.status, a.google, g.google], [503, 503, 0, 0]);
    } finally {
      await ccdb._reset();
      process.env.CONTROL_CENTER_DATABASE_URL = DB_URL;
    }
  });

  // ------------------------------------------------------ Touren getrennt
  await t.test('Eingabe-Budget reserviert keine Tour und berührt das Tour-Kontingent nicht', async () => {
    await setQuota(2, { tours: 1 });
    const u = await newUser();
    const toursBefore = await tourCount();
    await autocomplete(u);
    await geocode(u);
    assert.strictEqual(await autocomplete(u).then((r) => r.status), 429);
    assert.strictEqual(await tourCount(), toursBefore);
    const res = await post('/api/tours', { token: u.token, body: { idempotency_key: randomUUID() } });
    assert.strictEqual(res.status, 201, 'Tour trotz erschöpftem Eingabe-Budget möglich');
  });

  await t.test('mit tour_id läuft Geocoding im Tour-Budget, nicht im Eingabe-Budget', async () => {
    await setQuota(5);
    const u = await newUser();
    const tour = (await post('/api/tours', { token: u.token, body: { idempotency_key: randomUUID() } })).json.tour_id;
    const r = await geocode(u, { tour_id: tour });
    assert.deepStrictEqual([r.status, r.google], [200, 1]);
    assert.strictEqual(await used(u), 0);
    const row = (await q('select calls_used from cc.tours where id = $1', [tour]))[0];
    assert.strictEqual(row.calls_used, 1);
  });
});
