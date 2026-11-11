/* Verbindlicher Zugang zum Control Center (Konten, Touren, Kontingente).
 *
 * Getrennt vom Telemetrie-Pool: hier wartet der Aufrufer auf das Ergebnis,
 * und ein Fehler wird gemeldet statt verschluckt. Der Telemetrie-Pool legt
 * sich nach einem Fehler bewusst eine Minute schlafen - das darf eine
 * Kostenpruefung nie.
 */
let pool = null;

function getPool() {
  if (pool) return pool;
  const url = process.env.CONTROL_CENTER_DATABASE_URL;
  if (!url) return null;
  const { Pool } = require('pg');
  pool = new Pool({
    connectionString: url,
    ssl: String(url).includes('sslmode=disable') ? false : { rejectUnauthorized: false },
    max: Number(process.env.CONTROL_CENTER_SYNC_POOL_MAX || 4),
    connectionTimeoutMillis: 5000,
    idleTimeoutMillis: 30_000,
    // Eine haengende Anfrage darf keine Verbindung ewig belegen.
    statement_timeout: 5000,
  });
  // Ein Fehler an einer ruhenden Verbindung darf den Prozess nicht beenden.
  pool.on('error', (err) => console.warn(`[ccdb] Pool-Fehler (${err.code || 'unbekannt'})`));
  return pool;
}

class DbUnavailable extends Error {}

/** Eine einzelne Anweisung. Wirft DbUnavailable, wenn nicht eingerichtet. */
async function query(sql, params) {
  const p = getPool();
  if (!p) throw new DbUnavailable('nicht konfiguriert');
  return p.query(sql, params);
}

/** Nur fuer Tests. */
async function _reset() {
  if (pool) await pool.end().catch(() => {});
  pool = null;
}

module.exports = { getPool, query, DbUnavailable, _reset };
