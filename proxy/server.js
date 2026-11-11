/* Minimal Express proxy for Google Maps APIs
 * - Reads GOOGLE_MAPS_API_KEY from env
 * - Provides POST /api/geocode, /api/directions, /api/autocomplete
 * - CORS allowlist, origin check, rate limiting and an emergency kill switch
 *   for the paid endpoints (see guard.js)
 */

const express = require('express');
const helmet = require('helmet');
const rateLimit = require('express-rate-limit');
const cors = require('cors');
const fetch = require('node-fetch');
const telemetry = require('./telemetry');
const guard = require('./guard');
const auth = require('./auth');
const account = require('./account');
const tours = require('./tours');

const app = express();
app.set('trust proxy', guard.trustProxySetting());
app.use(helmet());

// Fremde Origins bekommen keine CORS-Freigabe - aber auch keinen Fehler mit
// Stacktrace. Ob die Anfrage bearbeitet wird, entscheidet danach
// requireAllowedOrigin fuer /api.
const corsOptions = {
  origin: (origin, callback) => callback(null, guard.originAllowed(origin)),
  methods: ['GET','HEAD','PUT','PATCH','POST','DELETE','OPTIONS'],
  allowedHeaders: ['Content-Type','Authorization','X-Requested-With','Accept'],
  preflightContinue: false,
  optionsSuccessStatus: 204
};

// CORS zuerst, damit auch 429-, 403- und 503-Antworten fuer die Web-App
// lesbar sind statt als undurchsichtiger Netzwerkfehler anzukommen.
app.use(cors(corsOptions));
// Handle preflight requests for all routes
app.options('*', cors(corsOptions));

// Alles unter /api kostet Google-Geld. Reihenfolge: Not-Aus zuerst (ohne
// Datenbank), dann Herkunft, dann Rate-Limit. /health bleibt davon frei.
const paidLimiter = rateLimit({
  windowMs: 60 * 1000,
  max: guard.positiveInt(process.env.RATE_LIMIT_PER_MINUTE, 120),
  standardHeaders: true,
  legacyHeaders: false,
  message: { error: 'rate_limited' },
});
app.use(
  '/api',
  guard.forwardedForDiagnostics(),
  guard.killSwitch,
  guard.requireAllowedOrigin,
  paidLimiter,
);

app.use(express.json({ limit: '1mb' }));

const GOOGLE_KEY = process.env.GOOGLE_MAPS_API_KEY;
if (!GOOGLE_KEY) {
  console.warn('Warning: GOOGLE_MAPS_API_KEY not set. Proxy will return errors for Google requests.');
}

// Google-Adressen als Konstanten, damit die Tests einen Ersatzserver
// vorschalten koennen. Ohne gesetzte Variable exakt wie bisher.
const GOOGLE_MAPS_BASE =
  process.env.GOOGLE_MAPS_BASE || 'https://maps.googleapis.com';
const GOOGLE_PLACES_BASE =
  process.env.GOOGLE_PLACES_BASE || 'https://places.googleapis.com';

// Googles eigener Statuscode im Antwortkoerper. ZERO_RESULTS ist kein
// Fehler: die Anfrage wurde beantwortet und wird auch berechnet - es gibt
// nur keine Route. Fehlt das Feld ganz, gilt die HTTP-Antwort.
function googleStatusOk(status) {
  if (!status) return true;
  return status === 'OK' || status === 'ZERO_RESULTS';
}

// Obergrenze fuer einen einzelnen Google-Aufruf. Ohne sie haengt ein Aufruf
// unbegrenzt - und eine Tour bliebe so lange mit einem laufenden Aufruf
// belegt. Muss deutlich unter dem Nachlauf der Touren (5 min) liegen.
function googleTimeoutMs() {
  const n = Number(process.env.GOOGLE_TIMEOUT_MS);
  return Number.isInteger(n) && n > 0 ? n : 30_000;
}

// Telemetrie-Zuordnung: im Tour-Modus ist die Tour die Arbeitseinheit
// (tours.id = work_units.id), unabhaengig davon, was der Client als
// cc_work_unit mitschickt.
function traceFor(req, params) {
  if (!req.tourCall) return telemetry.traceFrom(params);
  return {
    workUnitId: req.tourCall.tourId,
    workUnitKind: params && params.cc_work_kind === 'route_ferry' ? 'route_ferry' : 'route',
  };
}

/* Einzige Stelle, an der ein Google-Aufruf verbucht wird.
 *
 * Jeder Aufruf laeuft hier durch, deshalb kann weder einer doppelt gezaehlt
 * noch einer uebersehen werden. Das Verbuchen steht im finally: auch ein
 * abgebrochener oder fehlgeschlagener Aufruf wird erfasst, und zwar mit
 * ok=false. Der Fehler selbst wird nicht angefasst und laeuft weiter nach
 * oben, als gaebe es dieses Modul nicht.
 */
async function googleCall(endpoint, trace, run, tour, input) {
  // Tour-Modus: erst das Budget verbindlich belegen. Lehnt die Datenbank ab
  // oder ist sie nicht erreichbar, wirft beginCall - Google wird dann gar
  // nicht erst angefragt.
  if (tour) await tours.beginCall(tour);
  // Angemeldete Adresseingabe: Tagesbudget, ebenso vor Google.
  else if (input) await tours.beginInputCall(input);
  let ok = false;
  try {
    const out = await run();
    ok = out.ok;
    return out.value;
  } finally {
    telemetry.record({
      service: telemetry.serviceFor(endpoint),
      ok,
      // Es gibt noch keinen Zwischenspeicher, also war jeder Aufruf echt.
      cacheHit: false,
      ...trace,
    });
    // Immer abschliessen, auch nach Fehler oder Timeout - sonst bliebe der
    // Aufruf als laufend vermerkt.
    if (tour) await tours.endCall(tour, ok);
  }
}

// Fehler von Google-Aufrufen enthalten die volle Adresse - samt API-Key und
// Adressen der Nutzer. Deshalb nur die Fehlerart protokollieren und dem
// Client nie eine Fehlermeldung durchreichen.
function logProviderError(endpoint, err) {
  const kind = (err && (err.type || err.code || err.name)) || 'unbekannt';
  console.error(`[proxy] ${endpoint}: Aufruf fehlgeschlagen (${kind})`);
}

function forwardGet(url) {
  return fetch(url, { timeout: googleTimeoutMs() }).then(async (r) => {
    const text = await r.text();
    return { status: r.status, body: text };
  });
}

app.get('/health', (_, res) => res.json({ ok: true, proxy: true }));

const handleDirections = async (req, res) => {
  try {
    const params = req.method === 'GET' ? req.query : req.body;

    const { origin, destination, waypoints, mode, departure_time, alternatives, avoid, optimize } = params;

    if (!origin || !destination) {
      return res.status(400).json({ error: 'Missing origin or destination' });
    }

    const apiKey = process.env.GOOGLE_MAPS_API_KEY;

    const trace = traceFor(req, params);
    const url = new URL(`${GOOGLE_MAPS_BASE}/maps/api/directions/json`);

    url.searchParams.append('origin', origin);
    url.searchParams.append('destination', destination);
    url.searchParams.append('mode', mode || 'driving');
    url.searchParams.append('departure_time', departure_time || 'now');
    url.searchParams.append('key', apiKey);

    // Alternativrouten werden fuer die automatische Laendersperre gebraucht:
    // ohne sie kann die App nur eine einzige Variante gegen die gesperrten
    // Laender pruefen. Default bleibt false, damit sich nichts anderes aendert.
    const wantAlternatives = alternatives === true || alternatives === 'true';
    url.searchParams.append('alternatives', wantAlternatives ? 'true' : 'false');

    if (avoid) url.searchParams.append('avoid', String(avoid));

    if (waypoints && waypoints.length > 0) {
      // support both array and single-string waypoint formats
      const wpValue = Array.isArray(waypoints) ? waypoints.join('|') : waypoints;
      const wantOptimize = optimize === true || optimize === 'true';
      url.searchParams.append('waypoints', wantOptimize ? `optimize:true|${wpValue}` : wpValue);
    }

    const data = await googleCall('directions', trace, async () => {
      const response = await fetch(url.toString(), { timeout: googleTimeoutMs() });
      const body = await response.json();
      return {
        ok: response.ok && googleStatusOk(body.status),
        value: body,
      };
    }, req.tourCall);

    res.json(data);

  } catch (err) {
    if (err instanceof tours.TourDenied) return tours.sendDenied(err, res);
    logProviderError('directions', err);
    res.status(500).json({ error: 'Proxy failed' });
  }
};

app.get('/api/directions', tours.gate('directions'), handleDirections);
app.post('/api/directions', tours.gate('directions'), handleDirections);

const GEOCODE_LANGUAGES = new Set(['de', 'en']);

app.post('/api/geocode', tours.gate('geocode'), async (req, res) => {
  try {
    const address = (req.body && req.body.address) || '';
    const lat = req.body && req.body.lat;
    const lng = req.body && req.body.lng;
    if (!address && (!Number.isFinite(lat) || !Number.isFinite(lng))) {
      return res.status(400).json({ error: 'missing_address_or_coordinates' });
    }
    const query = address
      ? `address=${encodeURIComponent(address)}`
      : `latlng=${encodeURIComponent(`${lat},${lng}`)}`;
    // Ortsnamen in lesbarer (lateinischer) Schrift statt Landessprache –
    // z. B. „Thessaloniki, Griechenland“ statt „Θεσσαλονίκη, Ελλάδα“. Nur de/en.
    const language = GEOCODE_LANGUAGES.has(req.body && req.body.language) ? req.body.language : 'de';
    const trace = traceFor(req, req.body);
    const url = `${GOOGLE_MAPS_BASE}/maps/api/geocode/json?${query}&language=${language}&key=${GOOGLE_KEY}`;
    const r = await googleCall('geocode', trace, async () => {
      const res = await forwardGet(url);
      let status = null;
      try {
        status = JSON.parse(res.body).status;
      } catch (_) {
        // Keine JSON-Antwort: dann entscheidet allein der HTTP-Status.
      }
      const httpOk = res.status >= 200 && res.status < 300;
      return { ok: httpOk && googleStatusOk(status), value: res };
    }, req.tourCall, req.inputCall);
    res.status(r.status).type('application/json').send(r.body);
  } catch (err) {
    if (err instanceof tours.TourDenied) return tours.sendDenied(err, res);
    logProviderError(req.path, err);
    res.status(500).json({ error: 'proxy_error' });
  }
});


app.post('/api/autocomplete', tours.gate('autocomplete'), async (req, res) => {
  try {
    const { input, sessiontoken, language, location, radius } = req.body || {};
    if (!input) return res.status(400).json({ error: 'missing_input' });
    const body = {
      input,
      languageCode: language || 'de',
      includeQueryPredictions: false,
    };
    if (sessiontoken) body.sessionToken = sessiontoken;

    if (location) {
      const [latitude, longitude] = String(location)
        .split(',')
        .map(Number);
      if (Number.isFinite(latitude) && Number.isFinite(longitude)) {
        body.locationBias = {
          circle: {
            center: { latitude, longitude },
            radius: Math.min(Number(radius) || 50000, 50000),
          },
        };
      }
    }

    const trace = traceFor(req, req.body);
    const response = await googleCall('autocomplete', trace, async () => {
      const res = await fetch(`${GOOGLE_PLACES_BASE}/v1/places:autocomplete`, {
        timeout: googleTimeoutMs(),
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          'X-Goog-Api-Key': GOOGLE_KEY,
          'X-Goog-FieldMask':
            'suggestions.placePrediction.placeId,suggestions.placePrediction.text',
        },
        body: JSON.stringify(body),
      });
      // Places New meldet Fehler ueber den HTTP-Status, nicht im Koerper.
      return { ok: res.ok, value: res };
    }, req.tourCall, req.inputCall);
    const responseBody = await response.text();
    res.status(response.status).type('application/json').send(responseBody);
  } catch (err) {
    if (err instanceof tours.TourDenied) return tours.sendDenied(err, res);
    logProviderError(req.path, err);
    res.status(500).json({ error: 'proxy_error' });
  }
});

// Konto nach bestaetigter Anmeldung anlegen. Nur mit gueltigem Supabase-
// Token; die Nutzer-ID kommt allein aus dessen "sub". Kostet kein
// Google-Geld und ist deshalb vom Not-Aus ausgenommen (guard.NON_PAID_PATHS).
app.post('/api/account/bootstrap', auth.requireAuth, account.handleBootstrap);

// Touren: reservieren, abschliessen, freigeben. Nutzer nur aus dem Token.
app.post('/api/tours', auth.requireAuth, tours.handleReserve);
app.post('/api/tours/:id/complete', auth.requireAuth, tours.handleComplete);
app.post('/api/tours/:id/release', auth.requireAuth, tours.handleRelease);

// Fehler als knappes JSON, nie als HTML-Seite mit Stacktrace und Dateipfaden.
// eslint-disable-next-line no-unused-vars
app.use((err, req, res, next) => {
  const status = Number.isInteger(err.status) && err.status >= 400 && err.status < 600
    ? err.status
    : 500;
  // Nur die Fehlerart: Meldungen koennen Teile der Anfrage (Adressen) enthalten.
  if (status >= 500) console.error(`[proxy] Fehler (${err.type || err.code || err.name})`);
  res.status(status).json({ error: status >= 500 ? 'proxy_error' : 'bad_request' });
});

// replace direct listen with a safe wrapper to avoid crashing if port is in use
const startServer = (port) => {
  const server = app.listen(port, () => {
    console.log(`[proxy] Listening on port ${port}`);
  });
  server.on('error', (err) => {
    if (err && err.code === 'EADDRINUSE') {
      console.error(`[proxy] Port ${port} already in use; proxy will not start a new process.`);
    } else {
      console.error('[proxy] Server error:', err);
      process.exit(1);
    }
  });
  return server;
};

const port = process.env.PORT || 3000;
const server = startServer(port);

module.exports = { app, server, telemetry, account };
