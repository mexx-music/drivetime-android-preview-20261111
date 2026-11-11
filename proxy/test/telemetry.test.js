/* Tests fuer die Control-Center-Telemetrie.
 *
 * Voraussetzung: eine erreichbare PostgreSQL-Datenbank mit dem cc-Schema,
 * Adresse in CONTROL_CENTER_TEST_URL. Ohne sie werden die Tests uebersprungen
 * statt fehlzuschlagen, damit ein Klon ohne Docker nicht rot wird.
 *
 * Ausfuehren:  npm test   (im Ordner proxy)
 */
const test = require('node:test');
const assert = require('node:assert');
const { startFakeGoogle } = require('./fake_google');

const DB_URL = process.env.CONTROL_CENTER_TEST_URL;
const skip = DB_URL ? false : 'CONTROL_CENTER_TEST_URL nicht gesetzt';

let google;
let telemetry;
let server;
let base;
let pg;

const uuid = () => require('crypto').randomUUID();

// So wie die Web-App fragt: der Browser setzt den Origin selbst.
const WEB_APP_HEADERS = {
  'Content-Type': 'application/json',
  Origin: 'https://mexx-music.github.io',
};

async function boot() {
  google = await startFakeGoogle();
  process.env.GOOGLE_MAPS_API_KEY = 'testschluessel';
  process.env.GOOGLE_MAPS_BASE = google.base;
  process.env.GOOGLE_PLACES_BASE = google.base;
  process.env.CONTROL_CENTER_DATABASE_URL = DB_URL;
  process.env.CONTROL_CENTER_TEST = '1';
  process.env.PORT = '0';

  const mod = require('../server');
  server = mod.server;
  telemetry = mod.telemetry;
  await new Promise((r) => (server.listening ? r() : server.once('listening', r)));
  base = `http://127.0.0.1:${server.address().port}`;

  const { Client } = require('pg');
  pg = new Client({
    connectionString: DB_URL,
    ssl: DB_URL.includes('sslmode=disable') ? false : { rejectUnauthorized: false },
  });
  await pg.connect();
}

async function post(path, body) {
  const res = await fetch(`${base}${path}`, {
    method: 'POST',
    headers: WEB_APP_HEADERS,
    body: JSON.stringify(body),
  });
  return { status: res.status, body: await res.text() };
}

async function eventsFor(workUnitId) {
  const r = await pg.query(
    `select s.key as service, u.quantity, u.unit, u.cache_hit, u.ok,
            u.cost_estimate, u.work_unit_id
       from cc.usage_events u join cc.services s on s.id = u.service_id
      where u.work_unit_id = $1 order by u.ts, u.id`,
    [workUnitId],
  );
  return r.rows;
}

test('Telemetrie', { skip, concurrency: false }, async (t) => {
  await boot();
  t.after(async () => {
    await telemetry._drain();
    await pg.end();
    await new Promise((r) => server.close(r));
    await google.close();
    await telemetry._reset();
  });

  await t.test('1) normale Route: eine Arbeitseinheit, zwei Directions-Ereignisse',
    async () => {
      const wu = uuid();
      const before = google.calls.total;
      for (let i = 0; i < 2; i += 1) {
        const r = await post('/api/directions', {
          origin: 'A', destination: 'B', cc_work_unit: wu, cc_work_kind: 'route',
        });
        assert.strictEqual(r.status, 200);
      }
      await telemetry._drain();

      const rows = await eventsFor(wu);
      assert.strictEqual(rows.length, 2, 'zwei Ereignisse erwartet');
      for (const row of rows) {
        assert.strictEqual(row.service, 'directions');
        assert.strictEqual(Number(row.quantity), 1);
        assert.strictEqual(row.unit, 'request');
        assert.strictEqual(row.cache_hit, false);
        assert.strictEqual(row.ok, true);
        assert.strictEqual(row.cost_estimate, null, 'ohne Preis bleibt die Schaetzung leer');
      }
      const wuRow = await pg.query('select kind from cc.work_units where id = $1', [wu]);
      assert.strictEqual(wuRow.rowCount, 1, 'genau eine Arbeitseinheit');
      assert.strictEqual(wuRow.rows[0].kind, 'route');
      assert.strictEqual(google.calls.total - before, 2, 'genau zwei Google-Aufrufe');
    });

  await t.test('2) Geocoding wird als eigene Leistung erfasst', async () => {
    const wu = uuid();
    await post('/api/geocode', { address: 'Musterstrasse 1', cc_work_unit: wu });
    await telemetry._drain();
    const rows = await eventsFor(wu);
    assert.strictEqual(rows.length, 1);
    assert.strictEqual(rows[0].service, 'geocode');
    assert.strictEqual(rows[0].ok, true);
  });

  await t.test('3) Autocomplete wird als places-autocomplete erfasst', async () => {
    const wu = uuid();
    await post('/api/autocomplete', { input: 'Wien', cc_work_unit: wu });
    await telemetry._drain();
    const rows = await eventsFor(wu);
    assert.strictEqual(rows.length, 1);
    assert.strictEqual(rows[0].service, 'places-autocomplete');
    assert.strictEqual(rows[0].ok, true);
  });

  await t.test('4) Faehrroute: alle Landwege in derselben Arbeitseinheit', async () => {
    const wu = uuid();
    // Wie FerryLegPlan: Landweg zur Faehre, Landweg ab Faehre, dazu die
    // Adressaufloesung der beiden Haefen.
    await post('/api/directions', {
      origin: 'A', destination: 'Hafen1', avoid: 'ferries',
      cc_work_unit: wu, cc_work_kind: 'route_ferry',
    });
    await post('/api/directions', {
      origin: 'Hafen2', destination: 'B', avoid: 'ferries',
      cc_work_unit: wu, cc_work_kind: 'route_ferry',
    });
    await post('/api/geocode', { address: 'Hafen1', cc_work_unit: wu, cc_work_kind: 'route_ferry' });
    await telemetry._drain();

    const rows = await eventsFor(wu);
    assert.strictEqual(rows.length, 3, 'drei Aufrufe, eine Arbeitseinheit');
    assert.deepStrictEqual(
      rows.map((r) => r.service).sort(),
      ['directions', 'directions', 'geocode'],
    );
    const wuRow = await pg.query('select kind from cc.work_units where id = $1', [wu]);
    assert.strictEqual(wuRow.rows[0].kind, 'route_ferry', 'als Faehrroute gekennzeichnet');
  });

  await t.test('4b) Lambach-Oslo: Faehre wird erst waehrend der Berechnung erkannt',
    async () => {
      const wu = uuid();
      // So laeuft es wirklich: die Routenplanung fragt zuerst zweimal, um
      // ueberhaupt herauszufinden, ob eine Faehre im Weg liegt. Erst danach
      // steht die Einstufung fest - die Arbeitseinheit ist da laengst da.
      await post('/api/directions', {
        origin: 'Lambach', destination: 'Oslo',
        cc_work_unit: wu, cc_work_kind: 'route',
      });
      await post('/api/directions', {
        origin: 'Lambach', destination: 'Oslo', avoid: 'ferries',
        cc_work_unit: wu, cc_work_kind: 'route',
      });
      await telemetry._drain();

      let w = await pg.query('select kind from cc.work_units where id = $1', [wu]);
      assert.strictEqual(w.rows[0].kind, 'route',
        'vor der Erkennung ist es eine gewoehnliche Route');

      // Ab jetzt weiss die App von der Faehre: die Landwege vor und nach der
      // Ueberfahrt werden getrennt gerechnet.
      for (let i = 0; i < 6; i += 1) {
        await post('/api/directions', {
          origin: 'Lambach', destination: 'Hafen',
          cc_work_unit: wu, cc_work_kind: 'route_ferry',
        });
      }
      await telemetry._drain();

      w = await pg.query('select kind from cc.work_units where id = $1', [wu]);
      assert.strictEqual(w.rows[0].kind, 'route_ferry',
        'die Einstufung wird nachgezogen');

      const rows = await eventsFor(wu);
      assert.strictEqual(rows.length, 8, 'alle acht Aufrufe in einer Arbeitseinheit');
      const anzahl = await pg.query(
        'select count(*) as n from cc.work_units where id = $1', [wu]);
      assert.strictEqual(Number(anzahl.rows[0].n), 1, 'und nur eine Arbeitseinheit');
    });

  await t.test('4c) eine erkannte Faehrroute wird nie zurueckgestuft', async () => {
    const wu = uuid();
    await post('/api/directions', {
      origin: 'A', destination: 'B', cc_work_unit: wu, cc_work_kind: 'route_ferry',
    });
    await telemetry._drain();
    // Ein Nachzuegler ohne Faehrkennzeichen darf nichts kaputtmachen.
    await post('/api/geocode', {
      address: 'A', cc_work_unit: wu, cc_work_kind: 'route',
    });
    await telemetry._drain();

    const w = await pg.query('select kind from cc.work_units where id = $1', [wu]);
    assert.strictEqual(w.rows[0].kind, 'route_ferry');
  });

  await t.test('4d) eine reine Strassenroute bleibt route', async () => {
    const wu = uuid();
    for (let i = 0; i < 2; i += 1) {
      await post('/api/directions', {
        origin: 'Lambach', destination: 'Hamburg',
        cc_work_unit: wu, cc_work_kind: 'route',
      });
    }
    await telemetry._drain();
    const w = await pg.query('select kind from cc.work_units where id = $1', [wu]);
    assert.strictEqual(w.rows[0].kind, 'route');
    assert.strictEqual((await eventsFor(wu)).length, 2);
  });

  await t.test('5) Google-Fehler ergibt ok=false', async () => {
    const wu = uuid();
    google.setMode('google_error');
    await post('/api/directions', { origin: 'A', destination: 'B', cc_work_unit: wu });
    google.setMode('http_error');
    await post('/api/geocode', { address: 'A', cc_work_unit: wu });
    google.setMode('ok');
    await telemetry._drain();

    const rows = await eventsFor(wu);
    assert.strictEqual(rows.length, 2, 'auch Fehlaufrufe werden gezaehlt');
    for (const row of rows) assert.strictEqual(row.ok, false, `${row.service} muss ok=false sein`);
  });

  await t.test('5b) ZERO_RESULTS gilt als gelungener Aufruf', async () => {
    const wu = uuid();
    google.setMode('zero_results');
    await post('/api/directions', { origin: 'A', destination: 'B', cc_work_unit: wu });
    google.setMode('ok');
    await telemetry._drain();
    const rows = await eventsFor(wu);
    assert.strictEqual(rows[0].ok, true, 'beantwortet und berechnet, nur ohne Route');
  });

  await t.test('7) Telemetrie erzeugt keinen zusaetzlichen Google-Aufruf', async () => {
    const wu = uuid();
    const before = google.calls.total;
    await post('/api/directions', { origin: 'A', destination: 'B', cc_work_unit: wu });
    await post('/api/geocode', { address: 'A', cc_work_unit: wu });
    await post('/api/autocomplete', { input: 'A', cc_work_unit: wu });
    await telemetry._drain();
    assert.strictEqual(google.calls.total - before, 3, 'genau drei, kein vierter');
    assert.strictEqual((await eventsFor(wu)).length, 3);
  });

  await t.test('8) keine Nutzinhalte in der Datenbank', async () => {
    const wu = uuid();
    const geheim = 'Bahnhofstrasse 42, 1010 Wien';
    await post('/api/directions', {
      origin: geheim, destination: geheim, cc_work_unit: wu,
    });
    await post('/api/autocomplete', { input: geheim, cc_work_unit: wu });
    await telemetry._drain();

    // Jede Textspalte der beiden Tabellen gegen den Suchtext pruefen.
    const r = await pg.query(
      `select u.*, w.kind from cc.usage_events u
         left join cc.work_units w on w.id = u.work_unit_id
        where u.work_unit_id = $1`,
      [wu],
    );
    assert.strictEqual(r.rowCount, 2);
    const alsText = JSON.stringify(r.rows);
    assert.ok(!alsText.includes('Bahnhofstrasse'), 'Adresse darf nicht gespeichert sein');
    assert.ok(!alsText.includes('Wien'), 'Ortsname darf nicht gespeichert sein');
  });
});

// Braucht keine Datenbank - das ist ja gerade der Punkt.
async function freePort() {
  const net = require('node:net');
  return new Promise((resolve) => {
    const s = net.createServer();
    s.listen(0, '127.0.0.1', () => {
      const p = s.address().port;
      s.close(() => resolve(p));
    });
  });
}

test('6) ohne erreichbares Control Center laeuft die Route weiter',
  { concurrency: false }, async (t) => {
    // Eigener Prozesszustand: hier zeigt die Adresse bewusst ins Leere.
    const g = await startFakeGoogle();
    const { spawn } = require('node:child_process');
    const path = require('node:path');

    const port = await freePort();
    const child = spawn(process.execPath, [path.join(__dirname, '..', 'server.js')], {
      env: {
        ...process.env,
        PORT: String(port),
        GOOGLE_MAPS_API_KEY: 'testschluessel',
        GOOGLE_MAPS_BASE: g.base,
        GOOGLE_PLACES_BASE: g.base,
        // Port, auf dem garantiert nichts lauscht.
        CONTROL_CENTER_DATABASE_URL: 'postgresql://x:y@127.0.0.1:1/leer',
        CONTROL_CENTER_TEST: '',
        NODE_PORT_ECHO: '1',
      },
      stdio: ['ignore', 'pipe', 'pipe'],
    });

    await new Promise((resolve, reject) => {
      const timer = setTimeout(() => reject(new Error('Proxy startete nicht')), 15000);
      child.stdout.on('data', (d) => {
        if (String(d).includes('Listening on port')) { clearTimeout(timer); resolve(); }
      });
    });

    t.after(async () => { child.kill(); await g.close(); });

    // Mehrfach, damit auch der Weg nach der Fehlersperre geprueft ist.
    for (let i = 0; i < 3; i += 1) {
      const res = await fetch(`http://127.0.0.1:${port}/api/directions`, {
        method: 'POST',
        headers: WEB_APP_HEADERS,
        body: JSON.stringify({ origin: 'A', destination: 'B', cc_work_unit: uuid() }),
      });
      assert.strictEqual(res.status, 200, 'Route muss trotz toter Datenbank antworten');
      const body = await res.json();
      assert.strictEqual(body.status, 'OK');
    }
    assert.strictEqual(g.calls.directions, 3, 'Google wurde normal befragt');
  });

test('5c) Netzfehler zu Google ergibt ebenfalls ok=false',
  { skip, concurrency: false }, async (t) => {
    // Eigener Prozess, weil die Google-Adresse beim Laden festgelegt wird.
    const { spawn } = require('node:child_process');
    const path = require('node:path');
    const { Client } = require('pg');

    const port = await freePort();
    const wu = uuid();
    const child = spawn(process.execPath, [path.join(__dirname, '..', 'server.js')], {
      env: {
        ...process.env,
        PORT: String(port),
        GOOGLE_MAPS_API_KEY: 'testschluessel',
        // Hier lauscht nichts: der Aufruf scheitert beim Verbindungsaufbau.
        GOOGLE_MAPS_BASE: 'http://127.0.0.1:1',
        CONTROL_CENTER_DATABASE_URL: DB_URL,
        CONTROL_CENTER_TEST: '',
      },
      stdio: ['ignore', 'pipe', 'pipe'],
    });
    await new Promise((resolve, reject) => {
      const timer = setTimeout(() => reject(new Error('Proxy startete nicht')), 15000);
      child.stdout.on('data', (d) => {
        if (String(d).includes('Listening on port')) { clearTimeout(timer); resolve(); }
      });
    });
    t.after(() => child.kill());

    const res = await fetch(`http://127.0.0.1:${port}/api/directions`, {
      method: 'POST',
      headers: WEB_APP_HEADERS,
      body: JSON.stringify({ origin: 'A', destination: 'B', cc_work_unit: wu }),
    });
    assert.strictEqual(res.status, 500, 'der Fehler wird unveraendert weitergereicht');

    const db = new Client({
      connectionString: DB_URL,
      ssl: DB_URL.includes('sslmode=disable') ? false : { rejectUnauthorized: false },
    });
    await db.connect();
    // Der Schreibvorgang laeuft nachgelagert im anderen Prozess.
    let rows = [];
    for (let i = 0; i < 40 && rows.length === 0; i += 1) {
      const r = await db.query(
        'select ok from cc.usage_events where work_unit_id = $1', [wu],
      );
      rows = r.rows;
      if (rows.length === 0) await new Promise((r2) => setTimeout(r2, 100));
    }
    await db.end();

    assert.strictEqual(rows.length, 1, 'der gescheiterte Aufruf wird erfasst');
    assert.strictEqual(rows[0].ok, false);
  });
