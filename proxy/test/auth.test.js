/* Tests fuer die JWT-Pruefung (auth.js) und den Konto-Bootstrap (account.js).
 *
 * Ein Ersatz fuer Supabase liefert echte oeffentliche Schluessel (ES256 und
 * RS256) ueber denselben JWKS-Pfad wie Supabase. Die Tokens werden hier mit
 * den passenden privaten Schluesseln signiert - oder absichtlich falsch.
 *
 * Die Bootstrap-Tests mit Datenbank brauchen CONTROL_CENTER_TEST_URL (wie
 * telemetry.test.js) und werden sonst uebersprungen.
 */
const test = require('node:test');
const assert = require('node:assert');
const http = require('http');
const { randomUUID } = require('crypto');
const { generateKeyPair, exportJWK, exportSPKI, SignJWT, UnsecuredJWT } = require('jose');

const DB_URL = process.env.CONTROL_CENTER_TEST_URL;
const WEB_APP = 'https://mexx-music.github.io';

let jwksServer;
let supabaseUrl;
let issuer;
let es;   // im JWKS veroeffentlicht
let rs;   // im JWKS veroeffentlicht
let evil; // NICHT veroeffentlicht
let auth;
let server;
let base;
const logs = [];

async function startJwks(keys) {
  const srv = http.createServer((req, res) => {
    if (req.url === '/auth/v1/.well-known/jwks.json') {
      res.writeHead(200, { 'Content-Type': 'application/json' });
      return res.end(JSON.stringify({ keys }));
    }
    res.writeHead(404);
    res.end();
  });
  await new Promise((r) => srv.listen(0, '127.0.0.1', r));
  return srv;
}

async function keyPair(alg, kid) {
  const { publicKey, privateKey } = await generateKeyPair(alg, { extractable: true });
  const jwk = { ...(await exportJWK(publicKey)), kid, alg, use: 'sig' };
  return { publicKey, privateKey, jwk, kid, alg };
}

function claims(overrides = {}) {
  const now = Math.floor(Date.now() / 1000);
  return {
    iss: issuer,
    aud: 'authenticated',
    sub: randomUUID(),
    role: 'authenticated',
    is_anonymous: false,
    email: 'fahrer@example.com',
    iat: now,
    exp: now + 600,
    ...overrides,
  };
}

async function sign(c = claims(), key = es, header = {}) {
  return new SignJWT(c)
    .setProtectedHeader({ alg: key.alg, kid: key.kid, typ: 'JWT', ...header })
    .sign(key.privateKey);
}

async function bootstrap(token, { body = {}, query = '' } = {}) {
  const headers = { 'Content-Type': 'application/json', Origin: WEB_APP };
  if (token !== undefined) headers.Authorization = token;
  const res = await fetch(`${base}/api/account/bootstrap${query}`, {
    method: 'POST', headers, body: JSON.stringify(body),
  });
  const text = await res.text();
  let json = null;
  try { json = JSON.parse(text); } catch (_) { /* leer */ }
  return { status: res.status, json, wwwAuth: res.headers.get('www-authenticate'),
           cache: res.headers.get('cache-control') };
}

async function expectReject(token, status, code) {
  await assert.rejects(auth.verifyAccessToken(token), (err) => {
    assert.strictEqual(err.status, status);
    assert.strictEqual(err.code, code);
    return true;
  });
}

test('JWT-Pruefung und Konto-Bootstrap', { concurrency: false }, async (t) => {
  es = await keyPair('ES256', 'es-1');
  rs = await keyPair('RS256', 'rs-1');
  evil = await keyPair('ES256', 'es-1'); // gleiche kid, anderer Schluessel
  jwksServer = await startJwks([es.jwk, rs.jwk]);
  supabaseUrl = `http://127.0.0.1:${jwksServer.address().port}`;
  issuer = `${supabaseUrl}/auth/v1`;

  Object.assign(process.env, { SUPABASE_URL: supabaseUrl, PORT: '0',
                               GOOGLE_MAPS_API_KEY: 'testschluessel' });
  delete process.env.PAID_CALLS_DISABLED;
  if (DB_URL) process.env.CONTROL_CENTER_DATABASE_URL = DB_URL;
  else delete process.env.CONTROL_CENTER_DATABASE_URL;

  // Alles mitschreiben, was protokolliert wird - kein Token darf darin stehen.
  const orig = { warn: console.warn, error: console.error, log: console.log };
  for (const k of Object.keys(orig)) {
    console[k] = (...a) => { logs.push(a.join(' ')); };
  }

  auth = require('../auth');
  const mod = require('../server');
  server = mod.server;
  await new Promise((r) => (server.listening ? r() : server.once('listening', r)));
  base = `http://127.0.0.1:${server.address().port}`;

  t.after(async () => {
    Object.assign(console, orig);
    await mod.account._reset();
    await new Promise((r) => server.close(r));
    await new Promise((r) => jwksServer.close(r));
  });

  // ------------------------------------------------------- Token-Pruefung
  await t.test('gueltiges ES256-Token: Nutzer-ID aus sub', async () => {
    const c = claims();
    const r = await auth.verifyAccessToken(await sign(c));
    assert.deepStrictEqual(r, { userId: c.sub });
  });

  await t.test('gueltiges RS256-Token wird ebenfalls akzeptiert', async () => {
    const c = claims();
    const r = await auth.verifyAccessToken(await sign(c, rs));
    assert.strictEqual(r.userId, c.sub);
  });

  await t.test('falscher Aussteller', async () => {
    await expectReject(await sign(claims({ iss: 'https://anderes-projekt.supabase.co/auth/v1' })),
      401, 'invalid_token');
  });

  await t.test('falsche Zielgruppe', async () => {
    await expectReject(await sign(claims({ aud: 'anon' })), 401, 'invalid_token');
  });

  await t.test('abgelaufenes Token', async () => {
    const now = Math.floor(Date.now() / 1000);
    await expectReject(await sign(claims({ iat: now - 7200, exp: now - 60 })), 401, 'invalid_token');
  });

  await t.test('noch nicht gueltiges Token (nbf in der Zukunft)', async () => {
    const now = Math.floor(Date.now() / 1000);
    await expectReject(await sign(claims({ nbf: now + 600 })), 401, 'invalid_token');
  });

  await t.test('manipulierte Nutzlast bei gueltiger Signatur', async () => {
    const [h, , s] = (await sign(claims())).split('.');
    const forged = Buffer.from(JSON.stringify(claims({ sub: randomUUID() }))).toString('base64url');
    await expectReject(`${h}.${forged}.${s}`, 401, 'invalid_token');
  });

  await t.test('fremder Schluessel mit gleicher kid', async () => {
    await expectReject(await sign(claims(), evil), 401, 'invalid_token');
  });

  await t.test('unbekannte kid', async () => {
    await expectReject(await sign(claims(), { ...evil, kid: 'unbekannt' }), 401, 'invalid_token');
  });

  await t.test('alg=none wird abgewiesen', async () => {
    const unsigned = new UnsecuredJWT(claims()).encode();
    await expectReject(unsigned, 401, 'invalid_token');
  });

  await t.test('HS256 mit dem oeffentlichen Schluessel als Geheimnis (Algorithmus-Verwechslung)',
    async () => {
      const pem = await exportSPKI(es.publicKey);
      const token = await new SignJWT(claims())
        .setProtectedHeader({ alg: 'HS256', kid: 'es-1' })
        .sign(new TextEncoder().encode(pem));
      await expectReject(token, 401, 'invalid_token');
    });

  await t.test('anonymer Nutzer wird abgewiesen', async () => {
    await expectReject(await sign(claims({ is_anonymous: true })), 403, 'anonymous_not_allowed');
  });

  await t.test('Rolle anon statt authenticated', async () => {
    await expectReject(await sign(claims({ role: 'anon' })), 401, 'invalid_token');
  });

  await t.test('sub ist keine UUID', async () => {
    await expectReject(await sign(claims({ sub: 'admin' })), 401, 'invalid_token');
  });

  await t.test('fehlendes exp', async () => {
    const c = claims();
    delete c.exp;
    await expectReject(await sign(c), 401, 'invalid_token');
  });

  await t.test('JWKS nicht erreichbar: 503, fail closed', async () => {
    const closed = await startJwks([]);
    const port = closed.address().port;
    await new Promise((r) => closed.close(r));
    process.env.SUPABASE_URL = `http://127.0.0.1:${port}`;
    auth._reset();
    try {
      const c = claims({ iss: `http://127.0.0.1:${port}/auth/v1` });
      await expectReject(await sign(c), 503, 'auth_unavailable');
    } finally {
      process.env.SUPABASE_URL = supabaseUrl;
      auth._reset();
    }
  });

  await t.test('SUPABASE_URL fehlt oder ist unsicher: 503, fail closed', async () => {
    try {
      delete process.env.SUPABASE_URL;
      auth._reset();
      await expectReject(await sign(), 503, 'auth_not_configured');
      process.env.SUPABASE_URL = 'http://projekt.supabase.co';
      auth._reset();
      await expectReject(await sign(), 503, 'auth_not_configured');
    } finally {
      process.env.SUPABASE_URL = supabaseUrl;
      auth._reset();
    }
  });

  // ------------------------------------------------- Endpunkt ohne Datenbank
  await t.test('Bootstrap ohne Authorization-Header: 401', async () => {
    const r = await bootstrap(undefined);
    assert.strictEqual(r.status, 401);
    assert.deepStrictEqual(r.json, { error: 'auth_required' });
    assert.strictEqual(r.wwwAuth, 'Bearer');
  });

  await t.test('Bootstrap mit falschem Schema oder kaputtem Token: 401', async () => {
    for (const h of ['Basic Zm9vOmJhcg==', 'Bearer', 'Bearer ', 'Bearer abc', `bearer ${await sign()}x y`]) {
      const r = await bootstrap(h);
      assert.strictEqual(r.status, 401, h.slice(0, 12));
      assert.strictEqual(r.json.error, 'invalid_token');
    }
  });

  await t.test('Bootstrap mit abgelaufenem Token: 401', async () => {
    const now = Math.floor(Date.now() / 1000);
    const r = await bootstrap(`Bearer ${await sign(claims({ iat: now - 7200, exp: now - 60 }))}`);
    assert.strictEqual(r.status, 401);
    assert.match(r.wwwAuth, /invalid_token/);
  });

  await t.test('Bootstrap als anonymer Nutzer: 403', async () => {
    const r = await bootstrap(`Bearer ${await sign(claims({ is_anonymous: true }))}`);
    assert.strictEqual(r.status, 403);
    assert.deepStrictEqual(r.json, { error: 'anonymous_not_allowed' });
  });

  await t.test('Bootstrap ohne Origin: 403 wie alle /api-Routen', async () => {
    const res = await fetch(`${base}/api/account/bootstrap`, {
      method: 'POST', headers: { Authorization: `Bearer ${await sign()}` },
    });
    assert.strictEqual(res.status, 403);
  });

  if (!DB_URL) {
    await t.test('gueltiges Token ohne Datenbank: 503, nichts angelegt', async () => {
      const r = await bootstrap(`Bearer ${await sign()}`);
      assert.strictEqual(r.status, 503);
      assert.deepStrictEqual(r.json, { error: 'bootstrap_failed' });
    });
  }

  // --------------------------------------------------- Endpunkt mit Datenbank
  await t.test('Bootstrap mit Datenbank', { skip: DB_URL ? false : 'CONTROL_CENTER_TEST_URL nicht gesetzt' },
    async (tt) => {
      const { Client } = require('pg');
      const pg = new Client({ connectionString: DB_URL,
        ssl: DB_URL.includes('sslmode=disable') ? false : { rejectUnauthorized: false } });
      await pg.connect();
      const created = [];
      const newAuthUser = async () => {
        const id = randomUUID();
        created.push(id);
        await pg.query('insert into auth.users (id) values ($1)', [id]);
        return id;
      };
      const counts = async (id) => (await pg.query(
        `select (select count(*) from cc.users where id = $1)::int as users,
                (select count(*) from cc.accounts where personal_owner = $1)::int as accounts,
                (select count(*) from cc.account_members where user_id = $1)::int as members,
                (select count(*) from cc.entitlements e join cc.accounts a on a.id = e.account_id
                  where a.personal_owner = $1)::int as entitlements`, [id])).rows[0];
      tt.after(async () => {
        await pg.query(`update cc.projects set active = true where key = 'drivetime'`);
        if (created.length) await pg.query('delete from auth.users where id = any($1::uuid[])', [created]);
        await pg.end();
      });

      await tt.test('erster Aufruf legt Konto, Mitgliedschaft und Free-Entitlement an', async () => {
        const id = await newAuthUser();
        const r = await bootstrap(`Bearer ${await sign(claims({ sub: id }))}`);
        assert.strictEqual(r.status, 200);
        assert.deepStrictEqual(Object.keys(r.json).sort(), ['account_id', 'created', 'plan_key', 'status']);
        assert.strictEqual(r.json.plan_key, 'free');
        assert.strictEqual(r.json.status, 'active');
        assert.strictEqual(r.json.created, true);
        assert.strictEqual(r.cache, 'no-store');
        assert.deepStrictEqual(await counts(id), { users: 1, accounts: 1, members: 1, entitlements: 1 });
        const e = (await pg.query(
          `select e.source, e.period_mode, p.key as project from cc.entitlements e
             join cc.accounts a on a.id = e.account_id join cc.projects p on p.id = e.project_id
            where a.personal_owner = $1`, [id])).rows[0];
        assert.deepStrictEqual(e, { source: 'default_free', period_mode: 'calendar_month', project: 'drivetime' });
      });

      await tt.test('idempotent: zweiter Aufruf liefert dasselbe Konto, legt nichts an', async () => {
        const id = await newAuthUser();
        const token = `Bearer ${await sign(claims({ sub: id }))}`;
        const first = await bootstrap(token);
        const second = await bootstrap(token);
        assert.strictEqual(second.status, 200);
        assert.strictEqual(second.json.account_id, first.json.account_id);
        assert.strictEqual(second.json.created, false);
        assert.deepStrictEqual(await counts(id), { users: 1, accounts: 1, members: 1, entitlements: 1 });
      });

      await tt.test('gleichzeitige Aufrufe desselben Nutzers: ein Konto', async () => {
        const id = await newAuthUser();
        const token = `Bearer ${await sign(claims({ sub: id }))}`;
        const results = await Promise.all(Array.from({ length: 6 }, () => bootstrap(token)));
        assert.ok(results.every((r) => r.status === 200));
        assert.strictEqual(new Set(results.map((r) => r.json.account_id)).size, 1);
        assert.deepStrictEqual(await counts(id), { users: 1, accounts: 1, members: 1, entitlements: 1 });
      });

      await tt.test('user_id aus Body oder Query wird ignoriert', async () => {
        const me = await newAuthUser();
        const other = await newAuthUser();
        const r = await bootstrap(`Bearer ${await sign(claims({ sub: me }))}`, {
          body: { user_id: other, sub: other, account_id: randomUUID(), plan_key: 'fleet' },
          query: `?user_id=${other}&sub=${other}`,
        });
        assert.strictEqual(r.status, 200);
        assert.strictEqual(r.json.plan_key, 'free');
        assert.deepStrictEqual(await counts(me), { users: 1, accounts: 1, members: 1, entitlements: 1 });
        assert.deepStrictEqual(await counts(other), { users: 0, accounts: 0, members: 0, entitlements: 0 });
      });

      await tt.test('Fehler im zweiten Schritt: alles zurueckgerollt', async () => {
        const id = await newAuthUser();
        // ensure_default_entitlement findet ein inaktives Projekt nicht -
        // nachdem ensure_personal_account schon gelaufen ist.
        await pg.query(`update cc.projects set active = false where key = 'drivetime'`);
        try {
          const r = await bootstrap(`Bearer ${await sign(claims({ sub: id }))}`);
          assert.strictEqual(r.status, 503);
          assert.deepStrictEqual(r.json, { error: 'bootstrap_failed' });
        } finally {
          await pg.query(`update cc.projects set active = true where key = 'drivetime'`);
        }
        assert.deepStrictEqual(await counts(id), { users: 0, accounts: 0, members: 0, entitlements: 0 });
      });

      await tt.test('gueltiges Token eines geloeschten Nutzers: 503, nichts angelegt', async () => {
        const id = randomUUID(); // nicht in auth.users
        const r = await bootstrap(`Bearer ${await sign(claims({ sub: id }))}`);
        assert.strictEqual(r.status, 503);
        assert.deepStrictEqual(await counts(id), { users: 0, accounts: 0, members: 0, entitlements: 0 });
      });

      await tt.test('Datenbank nicht erreichbar: 503, fail closed', async () => {
        await mod.account._reset();
        process.env.CONTROL_CENTER_DATABASE_URL = 'postgresql://x:y@127.0.0.1:1/cc?sslmode=disable';
        try {
          const r = await bootstrap(`Bearer ${await sign(claims({ sub: await newAuthUser() }))}`);
          assert.strictEqual(r.status, 503);
        } finally {
          await mod.account._reset();
          process.env.CONTROL_CENTER_DATABASE_URL = DB_URL;
        }
      });
    });

  await t.test('kein Token und kein Token-Inhalt in den Logs', async () => {
    const token = await sign(claims({ email: 'geheim-im-token@example.com' }));
    await bootstrap(`Bearer ${token}x`); // absichtlich kaputt
    const all = logs.join('\n');
    // Es wurde tatsaechlich protokolliert - nur eben ohne Inhalt.
    assert.match(all, /\[auth\] Token abgelehnt \(ERR_/);
    assert.ok(!all.includes(token.split('.')[1]), 'Token-Nutzlast im Log');
    assert.ok(!all.includes(token.split('.')[2]), 'Signatur im Log');
    assert.ok(!all.includes('geheim-im-token@example.com'), 'E-Mail im Log');
    assert.ok(!/eyJ[A-Za-z0-9_-]{10,}/.test(all), 'JWT-artiger Inhalt im Log');
  });
});
