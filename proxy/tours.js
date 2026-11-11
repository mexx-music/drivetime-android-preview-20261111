/* Verbindliche Kostenkontrolle: Touren und Aufrufbudget.
 *
 * Nutzt ausschliesslich die getesteten Datenbankfunktionen
 * (Migration 0007): reserve_tour, use_tour_call, finish_tour_call,
 * complete_tour, release_tour. Hier wird nichts davon nachgebaut.
 *
 * Ablauf einer Berechnung im Tour-Modus:
 *   POST /api/tours                 -> Tour reservieren (Idempotenzschluessel vom Client)
 *   Maps-Aufrufe mit tour_id        -> vor JEDEM Google-Aufruf use_tour_call,
 *                                      danach IMMER finish_tour_call
 *   POST /api/tours/:id/complete    -> fertig
 *   POST /api/tours/:id/release     -> abgebrochen, bevor etwas gelang
 *
 * Nutzer-ID nur aus dem geprueften Token (auth.js). Konto, Plan, Budget und
 * Kontingent bestimmt allein die Datenbank; Angaben des Clients dazu werden
 * nicht gelesen.
 *
 * Fail closed: ist die Datenbank nicht erreichbar oder lehnt sie ab, findet
 * kein Google-Aufruf statt. Die Telemetrie bleibt davon getrennt.
 */
const ccdb = require('./ccdb');
const auth = require('./auth');

const PROJECT_KEY = 'drivetime';
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

/** Mit TOURS_REQUIRED=1 brauchen Directions immer eine Tour. */
function toursRequired() {
  return /^(1|true|yes|on)$/i.test(String(process.env.TOURS_REQUIRED || '').trim());
}

/** Ablehnung ohne Google-Aufruf. */
class TourDenied extends Error {
  constructor(httpStatus, code) {
    super(code);
    this.httpStatus = httpStatus;
    this.code = code;
  }
}

/** Nur diese Felder gehen an den Client - nichts Internes. */
function publicTour(r) {
  const out = {};
  for (const k of ['tour_id', 'state', 'call_budget', 'calls_used', 'expires_at', 'completed',
                   'tours_used', 'tours_limit', 'period_end']) {
    if (r[k] !== undefined) out[k] = r[k];
  }
  return out;
}

async function callDb(sql, params) {
  try {
    const res = await ccdb.query(sql, params);
    return res.rows[0].r;
  } catch (err) {
    console.warn(`[tours] Datenbank nicht verfuegbar (${err.code || err.constructor.name})`);
    throw new TourDenied(503, 'quota_unavailable');
  }
}

// ------------------------------------------------------------ Endpunkte

const RESERVE_STATUS = {
  reserved: 201,
  existing: 200,
  quota_exhausted: 402,
  quota_not_configured: 403,
  no_entitlement: 403,
  entitlement_inactive: 403,
  not_member: 403,
  user_disabled: 403,
  account_disabled: 403,
  idempotency_conflict: 409,
  invalid_argument: 400,
  project_paused: 503,
  unknown_project: 503,
};

async function handleReserve(req, res) {
  const key = req.body && req.body.idempotency_key;
  if (typeof key !== 'string' || !UUID.test(key)) {
    return res.status(400).json({ error: 'invalid_idempotency_key' });
  }
  try {
    // Nur Nutzer (aus dem Token), Projekt und Schluessel. Konto, Plan und
    // Budget ermittelt reserve_tour selbst.
    const r = await callDb('select cc.reserve_tour($1, $2, $3) as r',
      [req.auth.userId, PROJECT_KEY, key.toLowerCase()]);
    const status = RESERVE_STATUS[r.status] || 503;
    res.set('Cache-Control', 'no-store');
    if (status < 300) return res.status(status).json(publicTour(r));
    const body = { error: r.status };
    if (r.status === 'quota_exhausted') {
      Object.assign(body, publicTour(r));
    }
    return res.status(status).json(body);
  } catch (err) {
    return sendDenied(err, res);
  }
}

const COMPLETE_STATUS = { completed: 200, already_completed: 200, not_consumed: 409,
                          not_found: 404, invalid_argument: 400 };
const RELEASE_STATUS = { released: 200, already_released: 200, consumed: 409,
                         call_in_flight: 409, not_found: 404, invalid_argument: 400 };

function lifecycle(fn, table) {
  return async (req, res) => {
    const id = req.params.id;
    if (typeof id !== 'string' || !UUID.test(id)) return res.status(404).json({ error: 'not_found' });
    try {
      const r = await callDb(`select cc.${fn}($1, $2) as r`, [id.toLowerCase(), req.auth.userId]);
      const status = table[r.status] || 503;
      res.set('Cache-Control', 'no-store');
      if (status < 300) return res.status(status).json({ status: r.status, ...publicTour(r) });
      return res.status(status).json({ error: r.status });
    } catch (err) {
      return sendDenied(err, res);
    }
  };
}

const handleComplete = lifecycle('complete_tour', COMPLETE_STATUS);
const handleRelease = lifecycle('release_tour', RELEASE_STATUS);

// ------------------------------------------------ Schutz der Maps-Aufrufe

/* Vor einem Maps-Endpunkt: entscheidet, ob die Anfrage im Tour-Modus laeuft.
 *
 *  - tour_id vorhanden              -> Tour-Modus (Token Pflicht)
 *  - Directions mit Authorization   -> Tour-Modus (wer sich anmeldet, rechnet in Touren)
 *  - Directions und TOURS_REQUIRED  -> Tour-Modus
 *  - sonst                          -> wie bisher (Adresseingabe, heutige App)
 *
 * Im Tour-Modus ist ohne gueltige tour_id und gueltiges Token Schluss, bevor
 * Google auch nur angefragt wird.
 */
function gate(endpoint) {
  return (req, res, next) => {
    const params = (req.method === 'GET' ? req.query : req.body) || {};
    const tourId = params.tour_id;
    const hasAuth = Boolean(req.get('Authorization'));
    const needsTour = endpoint === 'directions' && (toursRequired() || hasAuth);
    if (tourId === undefined && !needsTour) {
      // Adresseingabe eines angemeldeten Nutzers: eigenes Tagesbudget statt
      // Tour. Ohne Token bleibt es beim öffentlichen Weg wie bisher.
      if (hasAuth && INPUT_SERVICES[endpoint]) {
        return auth.requireAuth(req, res, () => {
          req.inputCall = { userId: req.auth.userId, service: INPUT_SERVICES[endpoint] };
          return next();
        });
      }
      return next();
    }
    if (typeof tourId !== 'string' || !UUID.test(tourId)) {
      return res.status(428).json({ error: 'tour_required' });
    }
    return auth.requireAuth(req, res, () => {
      req.tourCall = { tourId: tourId.toLowerCase(), userId: req.auth.userId };
      return next();
    });
  };
}

// Eingabe-Aufrufe außerhalb einer Tour und ihr Dienst im Katalog.
const INPUT_SERVICES = { geocode: 'geocode', autocomplete: 'places-autocomplete' };

const INPUT_STATUS = {
  input_quota_exhausted: [429, 'input_budget_exhausted'],
  input_quota_not_configured: [403, 'input_quota_not_configured'],
  no_entitlement: [403, 'no_entitlement'],
  entitlement_inactive: [403, 'entitlement_inactive'],
  not_member: [403, 'not_member'],
  user_disabled: [403, 'user_disabled'],
  account_disabled: [403, 'account_disabled'],
  project_paused: [503, 'project_paused'],
};

/** Unmittelbar VOR einem Eingabe-Aufruf. Wirft TourDenied - dann kein Aufruf.
 *  Nutzer aus dem Token, Konto/Plan/Limit/Tag bestimmt die Datenbank. */
async function beginInputCall(input) {
  const r = await callDb('select cc.try_input_call($1, $2, $3) as r',
    [input.userId, PROJECT_KEY, input.service]);
  if (r.status === 'ok') return;
  const [status, code] = INPUT_STATUS[r.status] || [503, 'quota_unavailable'];
  throw new TourDenied(status, code);
}

const USE_STATUS = {
  not_found: [404, 'tour_not_found'],
  released: [409, 'tour_released'],
  completed: [409, 'tour_completed'],
  expired: [409, 'tour_expired'],
  budget_exhausted: [429, 'call_budget_exhausted'],
  not_member: [403, 'not_member'],
  invalid_argument: [400, 'invalid_argument'],
};

/** Unmittelbar VOR einem Google-Aufruf. Wirft TourDenied - dann kein Aufruf. */
async function beginCall(tour) {
  const r = await callDb('select cc.use_tour_call($1, $2) as r', [tour.tourId, tour.userId]);
  if (r.status === 'ok') return;
  const [status, code] = USE_STATUS[r.status] || [503, 'quota_unavailable'];
  throw new TourDenied(status, code);
}

/** Nach JEDEM begonnenen Google-Aufruf, auch nach Fehler oder Timeout. Wirft nie. */
async function endCall(tour, success) {
  try {
    const res = await ccdb.query('select cc.finish_tour_call($1, $2, $3) as r',
      [tour.tourId, tour.userId, Boolean(success)]);
    const r = res.rows[0].r;
    if (r.status !== 'ok') console.warn(`[tours] Abschluss eines Aufrufs: ${r.status}`);
  } catch (err) {
    // Der Aufruf bleibt dann als laufend vermerkt: die Tour laesst sich nicht
    // mehr freigeben und laeuft zur vorgesehenen Zeit ab. Kosten entstehen
    // dadurch keine zusaetzlichen.
    console.warn(`[tours] Abschluss nicht verbucht (${err.code || err.constructor.name})`);
  }
}

function sendDenied(err, res) {
  if (err instanceof TourDenied) {
    res.set('Cache-Control', 'no-store');
    return res.status(err.httpStatus).json({ error: err.code });
  }
  console.warn(`[tours] unerwarteter Fehler (${err.code || err.constructor.name})`);
  return res.status(503).json({ error: 'quota_unavailable' });
}

module.exports = {
  gate,
  beginCall,
  endCall,
  beginInputCall,
  handleReserve,
  handleComplete,
  handleRelease,
  TourDenied,
  sendDenied,
  toursRequired,
};
