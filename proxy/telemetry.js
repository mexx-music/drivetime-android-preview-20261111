/* Telemetrie fuer das CatLab Control Center.
 *
 * Grundregel dieses Moduls: es darf eine Routenberechnung unter keinen
 * Umstaenden stoeren. Jeder Schreibvorgang laeuft nachgelagert, niemand
 * wartet auf ihn, und jeder Fehler endet hier. Ist die Datenbank weg, faellt
 * das Modul in einen stillen Ruhezustand und DriveTime arbeitet weiter, als
 * gaebe es keine Telemetrie.
 *
 * Gespeichert wird ausschliesslich, DASS ein Aufruf stattfand - nie, worum es
 * ging. Keine Adressen, keine Suchtexte, keine Koordinaten.
 *
 * Achtung fuer spaeter: weil niemand auf den Schreibvorgang wartet, koennen
 * einzelne Ereignisse verlorengehen - etwa wenn der Prozess mitten im
 * Schreiben endet. Das ist fuer Beobachtung und Kostenschaetzung in Ordnung,
 * taugt aber NICHT als alleinige Grundlage fuer Abrechnung oder harte
 * Kontingente. Siehe README, Abschnitt "Offene Architekturaufgabe".
 */

const PROJECT_KEY = 'drivetime';

// Wie lange nach einem Datenbankfehler gar nicht erst wieder versucht wird.
// Ohne diese Sperre wuerde jeder einzelne Google-Aufruf in eine neue,
// aussichtslose Verbindung laufen und der Proxy sich an einer toten Datenbank
// festhalten.
const COOLDOWN_MS = 60_000;

// Obergrenze fuer einen Schreibvorgang. Er laeuft zwar nebenher, soll aber
// nicht unbegrenzt eine Verbindung belegen.
const WRITE_TIMEOUT_MS = 5_000;

let pool = null;
let poolFailed = false;
let mutedUntil = 0;

// Auflösung von Schluessel zu ID passiert einmal und wird behalten: diese
// Zeilen aendern sich nicht im Betrieb.
let projectId = null;
const serviceIds = new Map();

// Arbeitseinheiten, die in dieser Prozesslaufzeit schon angelegt wurden,
// samt ihrer zuletzt geschriebenen Gattung. Spart den Einfuegeversuch fuer
// jeden weiteren Aufruf derselben Berechnung.
const knownWorkUnits = new Map();

// Ob eine Faehre im Spiel ist, stellt sich erst waehrend der Berechnung
// heraus: die ersten Aufrufe dienen ja gerade dazu, das herauszufinden. Die
// Arbeitseinheit ist da laengst angelegt. Deshalb darf eine spaetere Meldung
// die Einstufung heraufsetzen - aber nie wieder herunter, damit ein
// nachzueglerischer Aufruf eine erkannte Faehrroute nicht zurueckstuft.
function kindRank(kind) {
  return kind === 'route_ferry' ? 1 : 0;
}

function enabled() {
  return Boolean(process.env.CONTROL_CENTER_DATABASE_URL) && !poolFailed;
}

function muted() {
  return Date.now() < mutedUntil;
}

function mute(reason) {
  mutedUntil = Date.now() + COOLDOWN_MS;
  console.warn(`[telemetry] pausiert fuer ${COOLDOWN_MS / 1000}s: ${reason}`);
}

function sslSetting(url) {
  return String(url).includes('sslmode=disable')
    ? false
    : { rejectUnauthorized: false };
}

function getPool() {
  if (pool || poolFailed) return pool;
  try {
    // Erst hier laden: fehlt das Paket, laeuft der Proxy trotzdem.
    const { Pool } = require('pg');
    pool = new Pool({
      connectionString: process.env.CONTROL_CENTER_DATABASE_URL,
      // Supabase verlangt TLS, stellt aber ein eigenes Zertifikat aus.
      // Eine lokale Testdatenbank spricht dagegen gar kein TLS; das sagt sie
      // ueber sslmode=disable in der Adresse.
      ssl: sslSetting(process.env.CONTROL_CENTER_DATABASE_URL),
      max: Number(process.env.CONTROL_CENTER_POOL_MAX || 2),
      connectionTimeoutMillis: WRITE_TIMEOUT_MS,
      idleTimeoutMillis: 30_000,
    });
    pool.on('error', (err) => mute(`Pool-Fehler ${err.code || err.message}`));
  } catch (err) {
    poolFailed = true;
    console.warn(`[telemetry] nicht verfuegbar: ${err.message}`);
  }
  return pool;
}

async function resolveIds(client) {
  if (projectId === null) {
    const r = await client.query(
      'select id from cc.projects where key = $1',
      [PROJECT_KEY],
    );
    if (r.rowCount === 0) throw new Error(`Projekt ${PROJECT_KEY} fehlt`);
    projectId = r.rows[0].id;
  }
  if (serviceIds.size === 0) {
    const r = await client.query(
      `select s.key, s.id from cc.services s
         join cc.providers p on p.id = s.provider_id
        where p.key = 'google-maps'`,
    );
    for (const row of r.rows) serviceIds.set(row.key, row.id);
  }
}

async function write({ service, ok, workUnitId, workUnitKind, cacheHit }) {
  const p = getPool();
  if (!p) return;
  const client = await p.connect();
  try {
    await resolveIds(client);
    const serviceId = serviceIds.get(service);
    if (!serviceId) throw new Error(`Leistung ${service} nicht im Katalog`);

    if (workUnitId) {
      const bekannt = knownWorkUnits.get(workUnitId);
      if (bekannt === undefined || kindRank(workUnitKind) > kindRank(bekannt)) {
        await client.query(
          `insert into cc.work_units (id, project_id, kind)
           values ($1, $2, $3)
           on conflict (id) do update set kind = excluded.kind
            where cc.work_units.kind <> 'route_ferry'
              and excluded.kind = 'route_ferry'`,
          [workUnitId, projectId, workUnitKind],
        );
        knownWorkUnits.set(workUnitId, workUnitKind);
        // Nicht unbegrenzt wachsen lassen. Die aeltesten Eintraege werden
        // ohnehin nicht mehr gebraucht, weil die Berechnung laengst vorbei ist.
        if (knownWorkUnits.size > 5000) {
          const keep = [...knownWorkUnits].slice(-1000);
          knownWorkUnits.clear();
          for (const [k, v] of keep) knownWorkUnits.set(k, v);
        }
      }
    }

    // cost_estimate bleibt bewusst leer: es sind noch keine Preise hinterlegt.
    // Die Menge wird trotzdem gezaehlt.
    await client.query(
      `insert into cc.usage_events
         (project_id, service_id, work_unit_id, quantity, unit, cache_hit, ok)
       values ($1, $2, $3, 1, 'request', $4, $5)`,
      [projectId, serviceId, workUnitId || null, Boolean(cacheHit), Boolean(ok)],
    );
  } finally {
    client.release();
  }
}

/** Verbucht einen tatsaechlich ausgefuehrten Google-Aufruf. Wirft nie. */
function record(event) {
  if (!enabled() || muted()) return;
  // Bewusst kein await: der Aufrufer antwortet weiter, waehrend das hier
  // nebenher laeuft.
  write(event).catch((err) => {
    // Erste Fehlerursache merken, dann Ruhe geben.
    mute(err.code || err.message);
  });
}

/** Ordnet einen Proxy-Endpunkt der Leistung im Katalog zu. */
function serviceFor(endpoint) {
  switch (endpoint) {
    case 'directions':
      return 'directions';
    case 'geocode':
      return 'geocode';
    case 'autocomplete':
      return 'places-autocomplete';
    default:
      return null;
  }
}

/** Liest die Kennung der Berechnung aus dem Anfragekoerper. */
function traceFrom(params) {
  if (!params || typeof params !== 'object') return {};
  const id = params.cc_work_unit;
  if (typeof id !== 'string') return {};
  // Nur echte UUIDs uebernehmen, damit nichts Beliebiges in die Datenbank
  // gelangt, das von aussen gesetzt wurde.
  if (!/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(id)) {
    return {};
  }
  const kind = params.cc_work_kind === 'route_ferry' ? 'route_ferry' : 'route';
  return { workUnitId: id, workUnitKind: kind };
}

/** Nur fuer Tests: Zustand zuruecksetzen. */
async function _reset() {
  if (pool) await pool.end().catch(() => {});
  pool = null;
  poolFailed = false;
  mutedUntil = 0;
  projectId = null;
  serviceIds.clear();
  knownWorkUnits.clear();
}

/** Nur fuer Tests: wartet, bis alle angestossenen Schreibvorgaenge durch sind. */
const pending = new Set();
const originalWrite = write;
function recordAndTrack(event) {
  if (!enabled() || muted()) return;
  const task = originalWrite(event).catch((err) => mute(err.code || err.message));
  pending.add(task);
  task.finally(() => pending.delete(task));
}
async function _drain() {
  while (pending.size) await Promise.allSettled([...pending]);
}

module.exports = {
  record: process.env.CONTROL_CENTER_TEST === '1' ? recordAndTrack : record,
  serviceFor,
  traceFrom,
  _reset,
  _drain,
};
