/* Schutz der kostenpflichtigen Endpunkte, solange es noch keinen Login gibt.
 *
 * Nichts hiervon braucht eine Datenbank. Insbesondere der Not-Aus
 * (PAID_CALLS_DISABLED) muss auch dann greifen, wenn das Control Center nicht
 * erreichbar ist.
 *
 * Ehrliche Grenze: ein Origin-Header laesst sich von jedem Skript faelschen.
 * Die Pruefung haelt Browser fremder Seiten und naive Skripte ab, ist aber
 * keine Authentifizierung. Die kommt erst mit dem Login.
 */

// Oeffentliche Web-App. Exakte Origins, keine Praefixe.
const ALLOWED_ORIGINS = new Set(['https://mexx-music.github.io']);

// Lokale Entwicklung: jeder Port, aber nur exakt diese Hostnamen. Ein
// Praefixvergleich wuerde auch http://localhost.boese.example durchlassen.
const LOCAL_HOSTS = new Set(['localhost', '127.0.0.1']);

function originAllowed(origin) {
  if (typeof origin !== 'string' || origin === '') return false;
  if (ALLOWED_ORIGINS.has(origin)) return true;
  let url;
  try {
    url = new URL(origin);
  } catch (_) {
    return false;
  }
  // Ein Origin besteht nur aus Schema, Host und Port. Alles andere ist kein
  // Origin, den ein Browser senden wuerde.
  if (url.origin !== origin) return false;
  return url.protocol === 'http:' && LOCAL_HOSTS.has(url.hostname);
}

function flag(value) {
  return /^(1|true|yes|on)$/i.test(String(value || '').trim());
}

/** Not-Aus fuer alle kostenpflichtigen Aufrufe. Wird je Anfrage gelesen. */
function paidCallsDisabled() {
  return flag(process.env.PAID_CALLS_DISABLED);
}

/** Nur fuer Tests und Notfaelle: Anfragen ohne Origin wieder zulassen. */
function requestsWithoutOriginAllowed() {
  return flag(process.env.ALLOW_REQUESTS_WITHOUT_ORIGIN);
}

/* Wert fuer Express' "trust proxy". Ohne Angabe wird keinem Proxy vertraut -
 * genau das bisherige Verhalten. Eine Zahl ist die Anzahl der Proxys vor der
 * App (bei Render: Cloudflare und Render-Lastverteiler). Die richtige Zahl
 * zeigt die Protokollzeile "X-Forwarded-For ... Eintraege" nach dem Deploy.
 * Eine zu grosse Zahl macht die Client-IP faelschbar, deshalb kein Raten.
 */
function trustProxySetting(raw = process.env.TRUST_PROXY) {
  if (raw === undefined || String(raw).trim() === '') return false;
  const s = String(raw).trim();
  if (/^\d+$/.test(s)) return Number(s);
  if (/^(true|false)$/i.test(s)) {
    // "true" vertraut jedem Eintrag, also auch einem vom Client gesetzten.
    // Fuer ein Rate-Limit waere das wertlos. Nicht abstuerzen, sondern beim
    // bisherigen Verhalten bleiben und laut darauf hinweisen.
    console.error('[proxy] TRUST_PROXY=true/false ignoriert: Anzahl der Proxys angeben');
    return false;
  }
  return s; // z. B. "loopback" oder eine IP-/CIDR-Liste
}

function positiveInt(raw, fallback) {
  const n = Number(raw);
  return Number.isInteger(n) && n > 0 ? n : fallback;
}

// Pfade unter /api, die keinen kostenpflichtigen Provider-Aufruf ausloesen.
// Alles andere gilt als kostenpflichtig - auch jede kuenftige Route.
const NON_PAID_PATHS = new Set(['/account/bootstrap']);

/** Antwort, wenn der Not-Aus aktiv ist. Google wird nicht angefragt. */
function killSwitch(req, res, next) {
  if (!paidCallsDisabled() || NON_PAID_PATHS.has(req.path)) return next();
  res.set('Retry-After', '600');
  res.set('Cache-Control', 'no-store');
  return res.status(503).json({
    error: 'paid_calls_disabled',
    message: 'Routenberechnung ist voruebergehend pausiert.',
  });
}

/** Kostenpflichtige Endpunkte nur fuer eine erlaubte Web-App. */
function requireAllowedOrigin(req, res, next) {
  const origin = req.get('Origin');
  if (origin === undefined && requestsWithoutOriginAllowed()) return next();
  if (originAllowed(origin)) return next();
  return res.status(403).json({ error: 'origin_not_allowed' });
}

/* Einmalige Diagnose fuer die TRUST_PROXY-Einstellung: wie viele Eintraege
 * X-Forwarded-For bei den ersten Anfragen hat. Protokolliert werden nur
 * Anzahlen, keine Adressen. */
function forwardedForDiagnostics(limit = 3) {
  let remaining = limit;
  return (req, _res, next) => {
    if (remaining > 0) {
      remaining -= 1;
      const xff = req.get('X-Forwarded-For');
      const entries = xff ? xff.split(',').filter((s) => s.trim()).length : 0;
      console.log(
        `[proxy] X-Forwarded-For: ${entries} Eintraege, ` +
          `trust proxy=${JSON.stringify(req.app.get('trust proxy'))}`,
      );
    }
    next();
  };
}

module.exports = {
  NON_PAID_PATHS,
  originAllowed,
  paidCallsDisabled,
  trustProxySetting,
  positiveInt,
  killSwitch,
  requireAllowedOrigin,
  forwardedForDiagnostics,
};
