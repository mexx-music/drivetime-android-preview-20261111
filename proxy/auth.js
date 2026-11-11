/* Pruefung der Supabase-Zugangstoken (JWT) im Proxy.
 *
 * Geprueft wird ausschliesslich lokal gegen die oeffentlichen Schluessel
 * (JWKS) des Supabase-Projekts: kein Service-Role-Key, keine
 * Datenbankabfrage. Die Schluessel werden zwischengespeichert.
 *
 * Die Nutzer-ID ist allein "sub" aus dem gepruefenen Token. Was im
 * Anfragekoerper oder in der Adresse steht, zaehlt dafuer nie.
 *
 * Fail closed: fehlt die Einstellung, ist das Token ungueltig oder sind die
 * Schluessel nicht erreichbar, wird abgelehnt. In Logs landen nur
 * Fehlerarten, nie ein Token oder dessen Inhalt.
 */
const { createRemoteJWKSet, jwtVerify } = require('jose');

// Nur asymmetrische Verfahren. HS256 wuerde ein gemeinsames Geheimnis
// voraussetzen - und liesse sich mit dem oeffentlichen Schluessel faelschen,
// wenn man es hier zuliesse.
const ALGORITHMS = ['ES256', 'RS256'];
const AUDIENCE = 'authenticated';
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

// Fehler beim Abruf der Schluessel selbst (nicht beim Token). jose meldet
// eine Nicht-200-Antwort als ERR_JOSE_GENERIC.
const JWKS_UNAVAILABLE = new Set([
  'ERR_JWKS_TIMEOUT', 'ERR_JOSE_GENERIC',
  'ECONNREFUSED', 'ECONNRESET', 'ENOTFOUND', 'EAI_AGAIN', 'ETIMEDOUT',
]);

let cached = null; // { url, issuer, jwks }

/** Liest SUPABASE_URL. null = nicht eingerichtet. */
function config() {
  const raw = String(process.env.SUPABASE_URL || '').trim().replace(/\/+$/, '');
  if (!raw) return null;
  let url;
  try {
    url = new URL(raw);
  } catch (_) {
    return null;
  }
  const local = url.hostname === 'localhost' || url.hostname === '127.0.0.1';
  if (!(url.protocol === 'https:' || (local && url.protocol === 'http:'))) return null;
  if (cached && cached.url === raw) return cached;
  const issuer = `${raw}/auth/v1`;
  cached = {
    url: raw,
    issuer,
    jwks: createRemoteJWKSet(new URL(`${issuer}/.well-known/jwks.json`), {
      timeoutDuration: 5000,
      // Neue Schluessel (Rotation) werden hoechstens alle 30 s nachgeladen;
      // bekannte bleiben 10 min gueltig, wie Supabase selbst cacht.
      cooldownDuration: 30_000,
      cacheMaxAge: 10 * 60_000,
    }),
  };
  return cached;
}

class AuthError extends Error {
  constructor(status, code) {
    super(code);
    this.status = status;
    this.code = code;
  }
}

/** Prueft ein Token und liefert { userId }. Wirft AuthError. */
async function verifyAccessToken(token) {
  const cfg = config();
  if (!cfg) throw new AuthError(503, 'auth_not_configured');
  if (typeof token !== 'string' || token.length === 0 || token.length > 8192) {
    throw new AuthError(401, 'invalid_token');
  }
  let payload;
  try {
    ({ payload } = await jwtVerify(token, cfg.jwks, {
      issuer: cfg.issuer,
      audience: AUDIENCE,
      algorithms: ALGORITHMS,
      clockTolerance: 5,
      requiredClaims: ['sub', 'exp', 'iat'],
    }));
  } catch (err) {
    // Schluessel nicht abrufbar: der Dienst ist gestoert, nicht das Token.
    if (err && JWKS_UNAVAILABLE.has(err.code)) {
      console.warn(`[auth] Schluessel nicht abrufbar (${err.code || err.name})`);
      throw new AuthError(503, 'auth_unavailable');
    }
    console.warn(`[auth] Token abgelehnt (${(err && err.code) || 'unbekannt'})`);
    throw new AuthError(401, 'invalid_token');
  }
  if (typeof payload.sub !== 'string' || !UUID.test(payload.sub)) {
    throw new AuthError(401, 'invalid_token');
  }
  if (payload.role !== 'authenticated') throw new AuthError(401, 'invalid_token');
  if (payload.is_anonymous === true) throw new AuthError(403, 'anonymous_not_allowed');
  return { userId: payload.sub.toLowerCase() };
}

/** Express-Middleware: setzt req.auth = { userId } oder lehnt ab. */
async function requireAuth(req, res, next) {
  const header = req.get('Authorization') || '';
  const match = /^Bearer ([A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+)$/.exec(header);
  if (!match) {
    res.set('WWW-Authenticate', 'Bearer');
    return res.status(401).json({ error: header ? 'invalid_token' : 'auth_required' });
  }
  try {
    req.auth = await verifyAccessToken(match[1]);
    return next();
  } catch (err) {
    const status = err instanceof AuthError ? err.status : 401;
    const code = err instanceof AuthError ? err.code : 'invalid_token';
    if (status === 401) res.set('WWW-Authenticate', 'Bearer error="invalid_token"');
    return res.status(status).json({ error: code });
  }
}

/** Nur fuer Tests: zwischengespeicherte Schluessel verwerfen. */
function _reset() {
  cached = null;
}

module.exports = { verifyAccessToken, requireAuth, AuthError, _reset };
