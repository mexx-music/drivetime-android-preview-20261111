#!/usr/bin/env node
// DriveTime Studio – lokaler Exportdienst (erste funktionsfähige Stufe).
//
//   node tool/studio_export/server.mjs [--build build/web] [--port 8150] [--work <ordner>]
//                                      [--dev-unlock-fullhd] [--dev-max-seconds N]
//
// - liefert den Studio-Build der App aus (gleiche Herkunft wie die API),
// - nimmt Exportaufträge an (POST /api/export {preset, spec}),
// - rendert mit render.mjs (headless Chrome + ffmpeg) und liefert die MP4.
//
// Der Dienst ist die maßgebliche Instanz für Berechtigungen: Full HD ist
// gesperrt, außer er wird ausdrücklich lokal mit --dev-unlock-fullhd gestartet.
// Später: dieselben Endpunkte als serverseitiger Exportjob, Freischaltung je
// bezahlter filmId statt Schalter.
//
// Läuft nur auf 127.0.0.1 und ohne neue Infrastruktur oder laufende Kosten.

import { createServer } from 'node:http';
import { createReadStream, existsSync, mkdirSync, readFileSync, rmSync, statSync, writeFileSync } from 'node:fs';
import { extname, join, normalize, resolve, dirname } from 'node:path';
import { randomUUID } from 'node:crypto';
import { tmpdir } from 'node:os';
import { fileURLToPath } from 'node:url';
import { renderFilm, profile } from './render.mjs';

const HERE = dirname(fileURLToPath(import.meta.url));
const arg = (name, def) => { const i = process.argv.indexOf(name); return i > 0 ? process.argv[i + 1] : def; };
const flag = (name) => process.argv.includes(name);
const ROOT = resolve(arg('--build', join(HERE, '..', '..', 'build', 'web')));
const PORT = Number(arg('--port', '8150'));
const WORK = resolve(arg('--work', join(tmpdir(), 'drivetime-studio-export')));
const DEV_FULLHD = flag('--dev-unlock-fullhd');
const DEV_MAX_SECONDS = arg('--dev-max-seconds') ? Number(arg('--dev-max-seconds')) : null;
mkdirSync(join(WORK, 'jobs'), { recursive: true });

const MIME = { '.html': 'text/html; charset=utf-8', '.js': 'text/javascript', '.mjs': 'text/javascript', '.json': 'application/json',
  '.wasm': 'application/wasm', '.png': 'image/png', '.jpg': 'image/jpeg', '.svg': 'image/svg+xml', '.css': 'text/css',
  '.ttf': 'font/ttf', '.otf': 'font/otf', '.woff2': 'font/woff2', '.ico': 'image/x-icon', '.pbf': 'application/x-protobuf', '.mp4': 'video/mp4' };

/** @type {Map<string, any>} */
const jobs = new Map();
const historyFile = join(WORK, 'exports.json');
// Grundlage für „ein kostenloses Kontrollvideo je Filmversion“ (noch nicht durchgesetzt).
const history = existsSync(historyFile) ? JSON.parse(readFileSync(historyFile, 'utf8')) : [];

function entitlements(filmId) {
  const controls = history.filter((h) => h.filmId === filmId && h.preset === 'controlPreview' && h.status === 'ready').length;
  return { controlPreview: true, fullHD: DEV_FULLHD, devUnlockFullHD: DEV_FULLHD, controlPreviewsReady: controls };
}

const json = (res, code, body) => { res.writeHead(code, { 'Content-Type': 'application/json', 'Cache-Control': 'no-store' }); res.end(JSON.stringify(body)); };
const readBody = (req) => new Promise((ok, fail) => { const c = []; req.on('data', (d) => c.push(d)); req.on('end', () => ok(Buffer.concat(c).toString('utf8'))); req.on('error', fail); });

function publicJob(j) {
  return { jobId: j.id, status: j.status, preset: j.preset, format: j.format, filmId: j.filmId, framesDone: j.framesDone, framesTotal: j.framesTotal,
    bytes: j.bytes ?? null, error: j.error ?? null, detail: j.detail ?? null, truncated: j.truncated ?? false,
    blockedRequests: j.blockedRequests ?? null, startedAt: j.startedAt, finishedAt: j.finishedAt ?? null };
}

async function runJob(j) {
  const dir = join(WORK, 'jobs', j.id);
  const tmpOut = join(dir, 'film.part.mp4');
  try {
    const r = await renderFilm({
      pageUrl: `http://127.0.0.1:${PORT}/?export=1&filmSpec=${encodeURIComponent(`/jobs/${j.id}/spec.json`)}`,
      preset: j.preset, format: j.format, outFile: tmpOut, timeZone: j.timeZone,
      maxSeconds: DEV_MAX_SECONDS ?? undefined, signal: j.abort.signal,
      onProgress: (p) => { Object.assign(j, p); },
    });
    if (r.blockedRequests.length) {
      // Ein Export darf KEINEN Routing-/Geocoding-/Autocomplete-Aufruf auslösen.
      throw Object.assign(new Error('Der Film hat einen gesperrten Dienst angefragt.'), { detail: r.blockedRequests.join('\n') });
    }
    const final = join(dir, j.fileName);
    rmSync(final, { force: true });
    (await import('node:fs')).renameSync(tmpOut, final);
    Object.assign(j, { status: 'ready', file: final, bytes: statSync(final).size, truncated: r.truncated, blockedRequests: 0,
      framesDone: r.framesDone, framesTotal: r.framesTotal, finishedAt: new Date().toISOString(), render: { ...r, logs: r.logs } });
    writeFileSync(join(dir, 'result.json'), JSON.stringify(publicJob(j), null, 1));
  } catch (e) {
    rmSync(tmpOut, { force: true });                     // nie eine halbe Datei als fertig ausgeben
    if (j.abort.signal.aborted) {
      Object.assign(j, { status: 'cancelled', error: 'Export abgebrochen.', finishedAt: new Date().toISOString() });
      rmSync(dir, { recursive: true, force: true });     // temporäre Dateien aufräumen
    } else {
      Object.assign(j, { status: 'failed', error: 'Der Export ist fehlgeschlagen. Bitte erneut versuchen.',
        detail: `${e.message}${e.detail ? `\n${e.detail}` : ''}${e.logs ? `\n${e.logs.join('\n')}` : ''}`.slice(0, 4000),
        finishedAt: new Date().toISOString() });
    }
  } finally {
    history.push({ filmId: j.filmId, preset: j.preset, status: j.status, at: j.finishedAt });
    writeFileSync(historyFile, JSON.stringify(history, null, 1));
  }
}

const server = createServer(async (req, res) => {
  const url = new URL(req.url, `http://127.0.0.1:${PORT}`);
  const p = url.pathname;
  try {
    if (p === '/api/health') return json(res, 200, { ok: true, service: 'drivetime-studio-export', devUnlockFullHD: DEV_FULLHD, devMaxSeconds: DEV_MAX_SECONDS });
    if (p === '/api/entitlements') return json(res, 200, entitlements(url.searchParams.get('film') || ''));
    if (p === '/api/export' && req.method === 'POST') {
      let body;
      try { body = JSON.parse(await readBody(req)); } catch (_) { return json(res, 400, { error: 'invalid_json' }); }
      const { preset, spec } = body || {};
      if (!spec || typeof spec !== 'object' || !spec.plan || !spec.eta || !spec.filmId) return json(res, 400, { error: 'invalid_spec' });
      let prof;
      try { prof = profile(preset, spec.format); } catch (_) { return json(res, 400, { error: 'invalid_preset' }); }
      if (!entitlements(spec.filmId)[preset]) return json(res, 403, { error: 'not_entitled', preset });
      if ([...jobs.values()].some((j) => ['preparing', 'rendering', 'encoding'].includes(j.status))) return json(res, 409, { error: 'busy' });
      const id = randomUUID();
      const dir = join(WORK, 'jobs', id);
      mkdirSync(dir, { recursive: true });
      writeFileSync(join(dir, 'spec.json'), JSON.stringify(spec));
      const safe = String(spec.title || 'tour').replace(/[^\p{L}\p{N}]+/gu, '_').replace(/^_|_$/g, '').slice(0, 60) || 'tour';
      const j = { id, preset, format: spec.format, filmId: spec.filmId, timeZone: spec.timeZone || undefined, status: 'preparing',
        framesDone: 0, framesTotal: 0, startedAt: new Date().toISOString(), abort: new AbortController(),
        fileName: `drivetime_${safe}_${preset === 'fullHD' ? '1080p' : 'kontrollvideo'}_${prof.width}x${prof.height}.mp4` };
      jobs.set(id, j);
      runJob(j);
      return json(res, 202, { jobId: id });
    }
    if (p === '/api/export' && req.method === 'GET') return json(res, 200, [...jobs.values()].map(publicJob));
    let m;
    if ((m = p.match(/^\/api\/export\/([\w-]+)$/))) {
      const j = jobs.get(m[1]);
      return j ? json(res, 200, publicJob(j)) : json(res, 404, { error: 'unknown_job' });
    }
    if ((m = p.match(/^\/api\/export\/([\w-]+)\/cancel$/)) && req.method === 'POST') {
      const j = jobs.get(m[1]);
      if (!j) return json(res, 404, { error: 'unknown_job' });
      j.abort.abort();
      return json(res, 200, publicJob(j));
    }
    if ((m = p.match(/^\/api\/export\/([\w-]+)\/video$/))) {
      const j = jobs.get(m[1]);
      if (!j || j.status !== 'ready' || !existsSync(j.file)) return json(res, 404, { error: 'not_ready' });
      res.writeHead(200, { 'Content-Type': 'video/mp4', 'Content-Length': statSync(j.file).size,
        'Content-Disposition': `attachment; filename="${j.fileName}"` });
      return createReadStream(j.file).pipe(res);
    }
    if ((m = p.match(/^\/jobs\/([\w-]+)\/spec\.json$/))) {
      const f = join(WORK, 'jobs', m[1], 'spec.json');
      if (!existsSync(f)) return json(res, 404, { error: 'unknown_spec' });
      res.writeHead(200, { 'Content-Type': 'application/json', 'Cache-Control': 'no-store' });
      return createReadStream(f).pipe(res);
    }
    // Studio-Build ausliefern (SPA: unbekannte Pfade → index.html)
    let f = normalize(join(ROOT, decodeURIComponent(p)));
    if (!f.startsWith(ROOT)) return json(res, 403, { error: 'forbidden' });
    if (!existsSync(f) || statSync(f).isDirectory()) f = join(ROOT, 'index.html');
    res.writeHead(200, { 'Content-Type': MIME[extname(f)] || 'application/octet-stream', 'Cache-Control': 'no-cache' });
    return createReadStream(f).pipe(res);
  } catch (e) {
    return json(res, 500, { error: 'internal', detail: String(e).slice(0, 300) });
  }
});
server.listen(PORT, '127.0.0.1', () => {
  console.log(`DriveTime Studio Export: http://127.0.0.1:${PORT}/  (Build ${ROOT}, Arbeitsordner ${WORK})`);
  console.log(`Full HD: ${DEV_FULLHD ? 'LOKAL FREIGESCHALTET (--dev-unlock-fullhd)' : 'gesperrt'}${DEV_MAX_SECONDS ? ` · Entwicklung: Filme nach ${DEV_MAX_SECONDS} s gekürzt` : ''}`);
});
