/* Konto-Bootstrap: legt nach bestaetigter Anmeldung das persoenliche Konto
 * und das Standard-Entitlement (Free) fuer DriveTime an.
 *
 * Anders als die Telemetrie ist das kein Best-effort: der Aufrufer wartet auf
 * das Ergebnis, und ein Fehler wird gemeldet statt verschluckt (ccdb.js).
 *
 * Idempotent: beide Datenbankfunktionen legen nur an, was fehlt. Ein
 * wiederholter Aufruf liefert dasselbe Konto und aendert nichts.
 */
const PROJECT_KEY = 'drivetime';

const ccdb = require('./ccdb');

class BootstrapError extends Error {}

/** Legt Konto und Free-Entitlement fuer userId an (falls noch nicht da). */
async function bootstrapAccount(userId) {
  const p = ccdb.getPool();
  if (!p) throw new BootstrapError('nicht konfiguriert');
  const client = await p.connect();
  try {
    await client.query('begin');
    const acc = await client.query('select cc.ensure_personal_account($1) as id', [userId]);
    const accountId = acc.rows[0].id;
    const ent = await client.query(
      'select cc.ensure_default_entitlement($1, $2) as e', [accountId, PROJECT_KEY]);
    const e = ent.rows[0].e;
    if (!e || (e.status !== 'created' && e.status !== 'existing')) {
      throw new BootstrapError(`Entitlement: ${e && e.status}`);
    }
    await client.query('commit');
    return {
      account_id: accountId,
      plan_key: e.plan_key,
      status: e.entitlement_status,
      created: e.status === 'created',
    };
  } catch (err) {
    await client.query('rollback').catch(() => {});
    throw err;
  } finally {
    client.release();
  }
}

/** Express-Handler; setzt voraus, dass requireAuth vorher lief. */
async function handleBootstrap(req, res) {
  // Die Nutzer-ID kommt ausschliesslich aus dem geprueften Token.
  const userId = req.auth && req.auth.userId;
  if (!userId) return res.status(401).json({ error: 'auth_required' });
  try {
    const result = await bootstrapAccount(userId);
    res.set('Cache-Control', 'no-store');
    return res.status(200).json(result);
  } catch (err) {
    // Nur die Fehlerart, keine Nutzer-ID und keine Datenbankdetails.
    console.warn(`[account] Bootstrap fehlgeschlagen (${err.code || err.constructor.name})`);
    return res.status(503).json({ error: 'bootstrap_failed' });
  }
}

/** Nur fuer Tests. */
async function _reset() {
  await ccdb._reset();
}

module.exports = { handleBootstrap, bootstrapAccount, _reset };
