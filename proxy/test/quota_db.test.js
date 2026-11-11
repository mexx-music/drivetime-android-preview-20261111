/* Parallelitaets- und Migrationstests fuer das Kontingent-Schema
 * (supabase/migrations/…0006_cc_identity.sql, …0007_cc_quota.sql).
 *
 * Die fachlichen Einzelfaelle stehen in supabase/tests/quota_test.sql. Hier
 * geht es um das, was eine einzelne Transaktion nicht beweisen kann: echte,
 * getrennte Datenbankverbindungen, die gleichzeitig um dieselbe Zeile
 * konkurrieren - und um den Migrationslauf selbst.
 *
 * Voraussetzung wie bei telemetry.test.js: CONTROL_CENTER_TEST_URL zeigt auf
 * eine lokale Wegwerf-Datenbank mit auth_stub.sql und allen Migrationen.
 * Ohne sie werden die Tests uebersprungen. Superuser-Rechte werden fuer die
 * Migrationstests gebraucht (sie legen Wegwerf-Datenbanken an).
 */
const test = require('node:test');
const assert = require('node:assert');
const fs = require('fs');
const path = require('path');
const { randomUUID } = require('crypto');

const DB_URL = process.env.CONTROL_CENTER_TEST_URL;
const skip = DB_URL ? false : 'CONTROL_CENTER_TEST_URL nicht gesetzt';

const REPO = path.resolve(__dirname, '..', '..');
const MIGRATIONS = path.join(REPO, 'supabase', 'migrations');
const AUTH_STUB = path.join(REPO, 'supabase', 'tests', 'auth_stub.sql');

function pgClient(url = DB_URL) {
  const { Client } = require('pg');
  return new Client({
    connectionString: url,
    ssl: String(url).includes('sslmode=disable') ? false : { rejectUnauthorized: false },
  });
}

async function connectMany(n) {
  const clients = Array.from({ length: n }, () => pgClient());
  await Promise.all(clients.map((c) => c.connect()));
  return clients;
}

async function endAll(clients) {
  await Promise.all(clients.map((c) => c.end().catch(() => {})));
}

const status = (row) => row.r.status;

/** Wartet, bis die Verbindung pid auf eine Sperre wartet. */
async function waitUntilBlocked(admin, pid) {
  for (let i = 0; i < 100; i++) {
    const r = await admin.query(
      'select wait_event_type from pg_stat_activity where pid = $1', [pid]);
    if (r.rows[0] && r.rows[0].wait_event_type === 'Lock') return;
    await new Promise((res) => setTimeout(res, 20));
  }
  throw new Error(`Verbindung ${pid} wartet nicht auf eine Sperre`);
}

// ------------------------------------------------------------------------
test('Kontingent unter echter Parallelitaet', { skip, concurrency: false }, async (t) => {
  const admin = pgClient();
  await admin.connect();

  const projectKey = `qrace-${randomUUID().slice(0, 8)}`;
  const createdUsers = [];
  let projectId;
  let directionsId;

  const q = async (sql, params) => (await admin.query(sql, params)).rows;

  // Ein neuer Nutzer mit persoenlichem Konto und Free-Entitlement.
  async function newUser() {
    const id = randomUUID();
    createdUsers.push(id);
    await q('insert into auth.users (id) values ($1)', [id]);
    const [{ a }] = await q('select cc.ensure_personal_account($1) as a', [id]);
    await q('select cc.ensure_default_entitlement($1, $2)', [a, projectKey]);
    return { user: id, account: a };
  }

  async function setQuota(tours, calls) {
    await q(
      `update cc.plan_quotas set tours_per_period = $2, max_calls_per_tour = $3,
              tour_ttl = interval '10 minutes', active = true
        where project_id = $1 and plan_key = 'free'`,
      [projectId, tours, calls]);
  }

  const reserve = (c, user, key = randomUUID()) =>
    c.query('select cc.reserve_tour($1, $2, $3) as r', [user, projectKey, key])
      .then((res) => res.rows[0]);

  t.after(async () => {
    // Aufraeumen: Loeschen der Auth-Nutzer nimmt Konten, Mitgliedschaften,
    // Entitlements und Touren per Kaskade mit.
    if (createdUsers.length) {
      await q('delete from auth.users where id = any($1::uuid[])', [createdUsers]);
    }
    if (projectId) {
      await q('delete from cc.counters where project_id = $1', [projectId]);
      await q('delete from cc.plan_quotas where project_id = $1', [projectId]);
      await q('delete from cc.project_settings where project_id = $1', [projectId]);
      await q('delete from cc.projects where id = $1', [projectId]);
    }
    await admin.end();
  });

  [{ id: projectId }] = await q(
    `insert into cc.projects (key, name) values ($1, 'Parallel-Test') returning id`, [projectKey]);
  await q('insert into cc.project_settings (project_id) values ($1)', [projectId]);
  await q(`insert into cc.plan_quotas (project_id, plan_key) values ($1, 'free')`, [projectId]);
  [{ id: directionsId }] = await q(`select id from cc.services where key = 'directions'`);

  await t.test('(8) letzter Platz, zwei Verbindungen: die zweite wartet und bekommt quota_exhausted',
    async () => {
      await setQuota(1, 3);
      const { user } = await newUser();
      const [a, b] = await connectMany(2);
      try {
        const [{ pid: pidB }] = (await b.query('select pg_backend_pid() as pid')).rows;
        await a.query('begin');
        const first = await reserve(a, user);
        assert.strictEqual(status(first), 'reserved');

        // B startet, solange A seine Transaktion offen hat.
        const second = reserve(b, user);
        await waitUntilBlocked(admin, pidB);
        await a.query('commit');

        assert.strictEqual(status(await second), 'quota_exhausted');
        const [{ n }] = await q('select count(*)::int as n from cc.tours where user_id = $1', [user]);
        assert.strictEqual(n, 1);
      } finally {
        await endAll([a, b]);
      }
    });

  await t.test('(8) bricht die erste Reservierung ab, bekommt die wartende den Platz', async () => {
    await setQuota(1, 3);
    const { user } = await newUser();
    const [a, b] = await connectMany(2);
    try {
      const [{ pid: pidB }] = (await b.query('select pg_backend_pid() as pid')).rows;
      await a.query('begin');
      assert.strictEqual(status(await reserve(a, user)), 'reserved');
      const second = reserve(b, user);
      await waitUntilBlocked(admin, pidB);
      await a.query('rollback');
      assert.strictEqual(status(await second), 'reserved');
      const [{ n }] = await q('select count(*)::int as n from cc.tours where user_id = $1', [user]);
      assert.strictEqual(n, 1);
    } finally {
      await endAll([a, b]);
    }
  });

  await t.test('(8) 12 gleichzeitige Reservierungen bei 3 freien Plaetzen: genau 3, fuenf Runden',
    async () => {
      await setQuota(3, 3);
      for (let round = 0; round < 5; round++) {
        const { user } = await newUser();
        const clients = await connectMany(12);
        try {
          const results = await Promise.all(clients.map((c) => reserve(c, user)));
          const counts = results.reduce((acc, r) => {
            acc[status(r)] = (acc[status(r)] || 0) + 1;
            return acc;
          }, {});
          assert.deepStrictEqual(counts, { reserved: 3, quota_exhausted: 9 }, `Runde ${round}`);
          const [{ n }] = await q('select count(*)::int as n from cc.tours where user_id = $1', [user]);
          assert.strictEqual(n, 3, `Runde ${round}`);
        } finally {
          await endAll(clients);
        }
      }
    });

  await t.test('(7) derselbe Idempotenzschluessel von 8 Verbindungen: eine Tour', async () => {
    await setQuota(5, 3);
    const { user } = await newUser();
    const key = randomUUID();
    const clients = await connectMany(8);
    try {
      const results = await Promise.all(clients.map((c) => reserve(c, user, key)));
      const ids = new Set(results.map((r) => r.r.tour_id));
      assert.strictEqual(ids.size, 1);
      const statuses = results.map(status).sort();
      assert.strictEqual(statuses.filter((s) => s === 'reserved').length, 1);
      assert.strictEqual(statuses.filter((s) => s === 'existing').length, 7);
      const [{ n }] = await q('select count(*)::int as n from cc.tours where user_id = $1', [user]);
      assert.strictEqual(n, 1);
    } finally {
      await endAll(clients);
    }
  });

  await t.test('Konten sperren sich nicht gegenseitig', async () => {
    await setQuota(1, 3);
    const x = await newUser();
    const y = await newUser();
    const [a, b] = await connectMany(2);
    try {
      await a.query('begin');
      assert.strictEqual(status(await reserve(a, x.user)), 'reserved');
      // A haelt seine Sperre; B arbeitet auf einem anderen Konto ungehindert.
      const other = await Promise.race([
        reserve(b, y.user),
        new Promise((_, rej) => setTimeout(() => rej(new Error('blockiert')), 3000)),
      ]);
      assert.strictEqual(status(other), 'reserved');
      await a.query('commit');
    } finally {
      await endAll([a, b]);
    }
  });

  await t.test('(16) 10 gleichzeitige Aufrufe bei Budget 3: genau 3', async () => {
    await setQuota(5, 3);
    const { user } = await newUser();
    const [{ r }] = await q('select cc.reserve_tour($1, $2, $3) as r', [user, projectKey, randomUUID()]);
    const clients = await connectMany(10);
    try {
      const results = await Promise.all(clients.map((c) =>
        c.query('select cc.use_tour_call($1, $2) as r', [r.tour_id, user]).then((x) => x.rows[0])));
      const ok = results.filter((x) => status(x) === 'ok').length;
      const exhausted = results.filter((x) => status(x) === 'budget_exhausted').length;
      assert.deepStrictEqual([ok, exhausted], [3, 7]);
      const [row] = await q('select calls_used, calls_in_flight from cc.tours where id = $1', [r.tour_id]);
      assert.deepStrictEqual(row, { calls_used: 3, calls_in_flight: 3 });
    } finally {
      await endAll(clients);
    }
  });

  await t.test('Freigabe gegen laufenden Aufruf: wer zuerst sperrt, gewinnt - nie beides', async () => {
    await setQuota(5, 3);
    const { user } = await newUser();

    // Aufruf zuerst: die Freigabe wartet und wird dann verweigert.
    let [{ r }] = await q('select cc.reserve_tour($1, $2, $3) as r', [user, projectKey, randomUUID()]);
    let [a, b] = await connectMany(2);
    try {
      const [{ pid: pidB }] = (await b.query('select pg_backend_pid() as pid')).rows;
      await a.query('begin');
      await a.query('select cc.use_tour_call($1, $2)', [r.tour_id, user]);
      const rel = b.query('select cc.release_tour($1, $2) as r', [r.tour_id, user]);
      await waitUntilBlocked(admin, pidB);
      await a.query('commit');
      assert.strictEqual((await rel).rows[0].r.status, 'call_in_flight');
    } finally {
      await endAll([a, b]);
    }

    // Freigabe zuerst: der Aufruf wartet und wird dann abgelehnt.
    [{ r }] = await q('select cc.reserve_tour($1, $2, $3) as r', [user, projectKey, randomUUID()]);
    [a, b] = await connectMany(2);
    try {
      const [{ pid: pidB }] = (await b.query('select pg_backend_pid() as pid')).rows;
      await a.query('begin');
      await a.query('select cc.release_tour($1, $2)', [r.tour_id, user]);
      const use = b.query('select cc.use_tour_call($1, $2) as r', [r.tour_id, user]);
      await waitUntilBlocked(admin, pidB);
      await a.query('commit');
      assert.strictEqual((await use).rows[0].r.status, 'released');
      const [row] = await q('select state, calls_used from cc.tours where id = $1', [r.tour_id]);
      assert.deepStrictEqual(row, { state: 'released', calls_used: 0 });
    } finally {
      await endAll([a, b]);
    }
  });

  await t.test('(20) Zaehler: 20 gleichzeitige Erhoehungen bei Grenze 7, neue Zeile', async () => {
    const clients = await connectMany(20);
    const scopeKey = randomUUID();
    try {
      const results = await Promise.all(clients.map((c) =>
        c.query(
          `select cc.counter_try_increment($1::smallint, $2, 'user', $3, '2026-09', 1, 7) as r`,
          [projectId, directionsId, scopeKey]).then((x) => x.rows[0].r)));
      assert.strictEqual(results.filter((r) => r.allowed).length, 7);
      assert.strictEqual(results.filter((r) => !r.allowed && r.reason === 'limit_reached').length, 13);
      const [{ quantity }] = await q(
        `select quantity::int as quantity from cc.counters
          where project_id = $1 and scope = 'user' and scope_key = $2`, [projectId, scopeKey]);
      assert.strictEqual(quantity, 7);
    } finally {
      await endAll(clients);
    }
  });

  await t.test('(24) nach dem Aufraeumen bleibt nichts zurueck', async () => {
    // Laeuft vor t.after - prueft nur, dass alles am Testprojekt haengt.
    const [{ foreign }] = await q(
      `select count(*)::int as foreign from cc.tours
        where project_id <> $1 and user_id = any($2::uuid[])`, [projectId, createdUsers]);
    assert.strictEqual(foreign, 0);
  });
});

// ------------------------------------------------------------------------
test('Migrationen', { skip, concurrency: false }, async (t) => {
  const admin = pgClient();
  await admin.connect();
  const created = [];

  t.after(async () => {
    for (const db of created) {
      await admin.query(`drop database if exists "${db}" with (force)`).catch(() => {});
    }
    await admin.end();
  });

  const files = fs.readdirSync(MIGRATIONS).filter((f) => f.endsWith('.sql')).sort();
  const before = files.filter((f) => f < '20260926090006');
  const quota = files.filter((f) => f >= '20260926090006');

  async function scratch() {
    const name = `cc_migtest_${randomUUID().slice(0, 8)}`;
    await admin.query(`create database "${name}"`);
    created.push(name);
    const url = new URL(DB_URL);
    url.pathname = `/${name}`;
    const c = pgClient(url.toString());
    await c.connect();
    await c.query(fs.readFileSync(AUTH_STUB, 'utf8'));
    for (const f of before) await c.query(fs.readFileSync(path.join(MIGRATIONS, f), 'utf8'));
    return c;
  }

  const outsideCc = async (c) => (await c.query(`
    select 'class:'  || n.nspname || '.' || c.relname as o from pg_class c
      join pg_namespace n on n.oid = c.relnamespace
     where n.nspname not in ('cc', 'pg_catalog', 'information_schema', 'pg_toast')
       and n.nspname not like 'pg_temp%' and n.nspname not like 'pg_toast_temp%'
    union all
    select 'proc:' || n.nspname || '.' || p.proname from pg_proc p
      join pg_namespace n on n.oid = p.pronamespace
     where n.nspname not in ('cc', 'pg_catalog', 'information_schema')
    union all
    select 'schema:' || nspname from pg_namespace
    union all
    select 'role:' || rolname from pg_roles
    order by 1`)).rows.map((r) => r.o);

  await t.test('(24) 0006/0007 legen nichts ausserhalb von cc an', async () => {
    const c = await scratch();
    try {
      const snapshot = await outsideCc(c);
      for (const f of quota) await c.query(fs.readFileSync(path.join(MIGRATIONS, f), 'utf8'));
      assert.deepStrictEqual(await outsideCc(c), snapshot);
    } finally {
      await c.end();
    }
  });

  await t.test('0006 bricht ab, statt einen echten Plan am Nutzer zu verwerfen', async () => {
    const c = await scratch();
    try {
      const id = randomUUID();
      await c.query('insert into auth.users (id) values ($1)', [id]);
      await c.query(`insert into cc.users (id, plan) values ($1, 'pro')`, [id]);
      await assert.rejects(
        c.query(fs.readFileSync(path.join(MIGRATIONS, quota[0]), 'utf8')),
        /anderen Plan als free/);
      // Nichts halb angewendet: die Spalte und der Wert sind noch da.
      const r = await c.query('select plan from cc.users where id = $1', [id]);
      assert.strictEqual(r.rows[0].plan, 'pro');
      const t2 = await c.query(`select to_regclass('cc.accounts') as t`);
      assert.strictEqual(t2.rows[0].t, null);
    } finally {
      await c.end();
    }
  });

  await t.test('0006 bricht ab bei Nutzern ohne Auth-Eintrag', async () => {
    const c = await scratch();
    try {
      await c.query('insert into cc.users (id) values ($1)', [randomUUID()]);
      await assert.rejects(
        c.query(fs.readFileSync(path.join(MIGRATIONS, quota[0]), 'utf8')),
        /ohne passenden auth.users-Eintrag/);
    } finally {
      await c.end();
    }
  });

  await t.test('0006 uebernimmt vorhandene Free-Nutzer mit Auth-Eintrag', async () => {
    const c = await scratch();
    try {
      const id = randomUUID();
      await c.query('insert into auth.users (id) values ($1)', [id]);
      await c.query('insert into cc.users (id) values ($1)', [id]);
      for (const f of quota) await c.query(fs.readFileSync(path.join(MIGRATIONS, f), 'utf8'));
      const r = await c.query('select count(*)::int as n from cc.users where id = $1', [id]);
      assert.strictEqual(r.rows[0].n, 1);
    } finally {
      await c.end();
    }
  });

  await t.test('0006 ohne auth.users bricht mit klarer Meldung ab', async () => {
    const name = `cc_migtest_${randomUUID().slice(0, 8)}`;
    await admin.query(`create database "${name}"`);
    created.push(name);
    const url = new URL(DB_URL);
    url.pathname = `/${name}`;
    const c = pgClient(url.toString());
    await c.connect();
    try {
      for (const f of before) await c.query(fs.readFileSync(path.join(MIGRATIONS, f), 'utf8'));
      await assert.rejects(
        c.query(fs.readFileSync(path.join(MIGRATIONS, quota[0]), 'utf8')),
        /auth.users fehlt/);
    } finally {
      await c.end();
    }
  });
});
