// DriveTime Studio – Film-Renderer (lokal heute, unverändert nutzbar für einen
// späteren serverseitigen Exportjob).
//
// Gleicher Weg wie die bisherigen Filmexporte (Final Cut, „Roll On“):
// Studio-/Film-Build der App in headless Chrome, `?export=1` + Filmspezifikation,
// Bild für Bild über `window.drivetimeExport.step()`, warten bis Fahrzeugbilder
// und Kartenkacheln gezeichnet sind, Screenshot, ffmpeg.
//
// Beide Profile rendern denselben CSS-Ausschnitt mit derselben Zeitleiste; das
// Profil bestimmt nur Pixeldichte (deviceScaleFactor), welches Filmbild
// aufgenommen wird (jedes n-te), Kompression und Wasserzeichen.
//
// Netz: Routen-, Geocoding- und Autocomplete-Dienste (DriveTime-Proxy, Google)
// sind während der Aufnahme gesperrt und werden gezählt – ein Export darf
// keinen einzigen solchen Aufruf auslösen.

import { spawn } from 'node:child_process';
import { mkdtempSync, rmSync, readFileSync, existsSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const HERE = dirname(fileURLToPath(import.meta.url));
export const PRESETS = JSON.parse(readFileSync(join(HERE, 'presets.json'), 'utf8'));

/// Gesperrte Ziele (Muster für Fetch.enable) – Routing, Geocoding, Autocomplete.
export const BLOCKED_PATTERNS = [
  '*drive-time-arrival-proxy*',
  '*maps.googleapis.com*',
  '*places.googleapis.com*',
  '*routes.googleapis.com*',
  '*maps.google.com*',
  '*127.0.0.1:3000/api/*',
  '*localhost:3000/api/*',
];

const CHROME = process.env.CHROME || '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome';
const FFMPEG = process.env.FFMPEG || 'ffmpeg';
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

/// Technische Werte eines Profils (spiegelbildlich zu VideoExportProfile in Dart).
export function profile(preset, format) {
  const p = PRESETS.presets[preset];
  const vp = PRESETS.viewport[format];
  if (!p || !vp) throw new Error(`Unbekanntes Profil ${preset}/${format}`);
  const dsf = p.deviceScaleFactor;
  return {
    preset, format, viewport: vp, deviceScaleFactor: dsf,
    width: Math.round(vp.width * dsf), height: Math.round(vp.height * dsf),
    fps: p.fps, captureEvery: PRESETS.timelineFps / p.fps, crf: p.crf, x264Preset: p.x264Preset,
    audioKbps: p.audioKbps, watermark: p.watermark,
  };
}

// MapLibre-Instanzen greifen (wie im bisherigen Aufnahmeskript cdp_tiles.mjs).
const MAP_HOOK = `(() => {
  const wrap = (g) => {
    if (!g || !g.Map || g.Map.prototype.__hooked) return;
    const P = g.Map.prototype;
    const origOn = P.on;
    P.on = function (...a) { if (!this.__seen) { this.__seen = true; (window.__maps = window.__maps || []).push(this); } return origOn.apply(this, a); };
    const origRender = P._render;
    if (origRender) P._render = function (...a) { if (!this.__seen) { this.__seen = true; (window.__maps = window.__maps || []).push(this); } return origRender.apply(this, a); };
    P.__hooked = true;
  };
  (function poll() { if (window.maplibregl) wrap(window.maplibregl); setTimeout(poll, 20); })();
  document.addEventListener('load', (e) => { if (e.target && e.target.tagName === 'SCRIPT' && window.maplibregl) wrap(window.maplibregl); }, true);
})();`;

const ROUTE_MAP = `(window.__maps || []).filter((x) => { try { return !!x.getSource('route'); } catch (_) { return false; } }).pop()`;

/**
 * Rendert einen Film.
 * @param {object} o
 * @param {string} o.pageUrl   Studio-Build mit `?export=1&filmSpec=…`
 * @param {string} o.preset    controlPreview | fullHD
 * @param {string} o.format    landscape16x9 | portrait9x16
 * @param {string} o.outFile   Ziel-MP4
 * @param {string} [o.timeZone] IANA-Zone der Filmspezifikation
 * @param {number} [o.maxSeconds] nur Entwicklung: Film nach so vielen Sekunden beenden
 * @param {(p: object) => void} [o.onProgress]
 * @param {AbortSignal} [o.signal]
 * @param {number} [o.debugPort]
 */
export async function renderFilm(o) {
  const prof = profile(o.preset, o.format);
  const progress = (x) => o.onProgress && o.onProgress(x);
  const net = { blocked: [], requests: 0 };
  const prof_dir = mkdtempSync(join(tmpdir(), 'dt-studio-chrome-'));
  const port = o.debugPort || 9390;
  let chrome, ffmpeg, ws;
  const cleanup = () => {
    try { ws && ws.close(); } catch (_) {}
    try { chrome && chrome.kill('SIGKILL'); } catch (_) {}
    try { ffmpeg && ffmpeg.exitCode === null && ffmpeg.kill('SIGKILL'); } catch (_) {}
    try { rmSync(prof_dir, { recursive: true, force: true }); } catch (_) {}
  };
  const aborted = () => o.signal && o.signal.aborted;
  try {
    progress({ status: 'preparing' });
    chrome = spawn(CHROME, ['--headless=new', `--remote-debugging-port=${port}`, `--user-data-dir=${prof_dir}`, '--no-first-run',
      '--ignore-gpu-blocklist', '--use-angle=metal', '--enable-gpu-rasterization', '--hide-scrollbars', '--mute-audio',
      `--window-size=${prof.viewport.width},${prof.viewport.height}`, 'about:blank'], { stdio: 'ignore' });
    for (let i = 0; i < 100 && !ws; i++) {
      try {
        const l = await (await fetch(`http://127.0.0.1:${port}/json`)).json();
        const p = l.find((t) => t.type === 'page');
        if (p) ws = new WebSocket(p.webSocketDebuggerUrl);
      } catch (_) {}
      await sleep(150);
    }
    if (!ws) throw new Error('Chrome nicht erreichbar');
    if (ws.readyState !== WebSocket.OPEN) await new Promise((r, j) => { ws.addEventListener('open', r); ws.addEventListener('error', j); });
    let id = 0; const pend = new Map(); const handlers = [];
    ws.addEventListener('message', (e) => {
      const m = JSON.parse(e.data);
      if (m.id && pend.has(m.id)) { pend.get(m.id)(m); pend.delete(m.id); return; }
      for (const h of handlers) h(m);
    });
    const send = (method, params = {}, sessionId) => new Promise((res) => { const i = ++id; pend.set(i, res); ws.send(JSON.stringify(sessionId ? { id: i, method, params, sessionId } : { id: i, method, params })); });
    const ev = async (expr) => {
      const x = await send('Runtime.evaluate', { expression: expr, awaitPromise: true, returnByValue: true });
      if (x.error || x.result?.exceptionDetails) throw new Error(JSON.stringify(x.error ?? x.result.exceptionDetails).slice(0, 400));
      return x.result.result.value;
    };
    const logs = [];
    handlers.push((m) => {
      if (m.method === 'Fetch.requestPaused') {
        const u = m.params.request.url;
        net.blocked.push(u.replace(/key=[^&]+/g, 'key=***').slice(0, 160));
        send('Fetch.failRequest', { requestId: m.params.requestId, errorReason: 'BlockedByClient' }, m.sessionId);
      } else if (m.method === 'Network.requestWillBeSent') {
        net.requests++;
      } else if (m.method === 'Runtime.exceptionThrown') {
        logs.push('EXCEPTION ' + String(m.params.exceptionDetails?.exception?.description ?? m.params.exceptionDetails?.text).slice(0, 300));
      } else if (m.method === 'Target.attachedToTarget') {
        // Web-Worker (MapLibre) ebenfalls überwachen und sperren.
        const s = m.params.sessionId;
        send('Fetch.enable', { patterns: BLOCKED_PATTERNS.map((urlPattern) => ({ urlPattern })) }, s)
          .then(() => send('Runtime.runIfWaitingForDebugger', {}, s));
      }
    });
    await send('Target.setAutoAttach', { autoAttach: true, waitForDebuggerOnStart: true, flatten: true });
    await send('Network.enable');
    await send('Runtime.enable');
    await send('Page.enable');
    await send('Fetch.enable', { patterns: BLOCKED_PATTERNS.map((urlPattern) => ({ urlPattern })) });
    await send('Emulation.setDeviceMetricsOverride', { width: prof.viewport.width, height: prof.viewport.height, deviceScaleFactor: prof.deviceScaleFactor, mobile: false });
    if (o.timeZone) await send('Emulation.setTimezoneOverride', { timezoneId: o.timeZone });
    await send('Page.addScriptToEvaluateOnNewDocument', { source: MAP_HOOK });
    await send('Page.navigate', { url: o.pageUrl });

    // Film bereit: Export-Schnittstelle und Animationskarte vorhanden.
    let ready = false;
    for (let t = 0; t < 1200 && !ready; t++) {
      if (aborted()) throw new Error('abgebrochen');
      try { ready = await ev(`!!(window.drivetimeExport && ${ROUTE_MAP})`); } catch (_) {}
      if (!ready) await sleep(100);
    }
    if (!ready) throw Object.assign(new Error('Film startet nicht (keine Exportschnittstelle)'), { logs });
    const total = await ev('window.drivetimeExport.total()');
    const fullFrames = Math.round(total * PRESETS.timelineFps);
    const timelineFrames = o.maxSeconds ? Math.min(fullFrames, Math.round(o.maxSeconds * PRESETS.timelineFps)) : fullFrames;
    const framesTotal = Math.ceil(timelineFrames / prof.captureEvery);

    // ffmpeg: Bilder als JPEG über stdin, Wasserzeichen als Bild, H.264.
    const args = ['-hide_banner', '-loglevel', 'error', '-y', '-f', 'image2pipe', '-framerate', String(prof.fps), '-c:v', 'mjpeg', '-i', '-'];
    let vf = [];
    if (prof.watermark) {
      const wm = join(HERE, 'assets', `watermark_preview_${prof.width}x${prof.height}.png`);
      if (!existsSync(wm)) throw new Error(`Wasserzeichen fehlt: ${wm}`);
      args.push('-loop', '1', '-i', wm);
      vf = ['-filter_complex', '[0:v][1:v]overlay=0:0:shortest=1,scale=out_range=tv,format=yuv420p[v]', '-map', '[v]'];
    } else {
      vf = ['-vf', 'scale=out_range=tv,format=yuv420p'];
    }
    args.push(...vf, '-c:v', 'libx264', '-preset', prof.x264Preset, '-crf', String(prof.crf), '-r', String(prof.fps),
      '-pix_fmt', 'yuv420p', '-color_range', 'tv', '-color_primaries', 'bt709', '-color_trc', 'bt709', '-colorspace', 'bt709',
      // Der App-Film hat keine Tonspur; eine spätere Tonspur bekäme AAC mit prof.audioKbps.
      '-an', '-movflags', '+faststart', o.outFile);
    ffmpeg = spawn(FFMPEG, args, { stdio: ['pipe', 'ignore', 'pipe'] });
    let ffErr = '';
    ffmpeg.stderr.on('data', (d) => { ffErr += d; });
    const ffDone = new Promise((res) => ffmpeg.on('close', (code) => res(code)));
    const write = (buf) => new Promise((res, rej) => ffmpeg.stdin.write(buf, (e) => (e ? rej(e) : res())));

    progress({ status: 'rendering', framesDone: 0, framesTotal });
    let k = 0, done = 0, waitTimeouts = 0;
    while (k < timelineFrames) {
      if (aborted()) throw new Error('abgebrochen');
      await ev('window.drivetimeExport.step()');
      const shoot = k % prof.captureEvery === 0;
      if (shoot) {
        // Wie bisher: fertig gezeichnet = keine entstehenden Fahrzeugbilder,
        // Kacheln geladen, Lkw-Symbol an der gesetzten Stelle.
        let ok = false;
        for (let w = 0; w < 300 && !ok; w++) {
          ok = await ev(`(() => { const m = ${ROUTE_MAP};
            if (!(window.drivetimeExport.pending() === 0 && (!m || (m.loaded() && m.areTilesLoaded())))) return false;
            if (!m) return true;
            try { const f = m.getSource('truck').serialize().data.features[0]; if (!f) return true;
              const r = m.queryRenderedFeatures({ layers: ['truck-upright', 'truck-flat'] }); if (!r.length) return true;
              const a = f.geometry.coordinates, b = r[0].geometry.coordinates;
              if (Math.abs(a[0] - b[0]) < 1e-3 && Math.abs(a[1] - b[1]) < 1e-3) return true; m.triggerRepaint(); return false; } catch (e) { return true; } })()`);
          if (!ok) await sleep(20);
        }
        if (!ok) waitTimeouts++;
        await ev('new Promise((r) => requestAnimationFrame(() => requestAnimationFrame(() => r(true))))');
        const shot = await send('Page.captureScreenshot', { format: 'jpeg', quality: o.preset === 'fullHD' ? 95 : 88 });
        if (!shot.result?.data) throw new Error('Screenshot fehlgeschlagen');
        await write(Buffer.from(shot.result.data, 'base64'));
        done++;
        if (done % 5 === 0 || done === framesTotal) progress({ status: 'rendering', framesDone: done, framesTotal });
      } else {
        // Zwischenbilder: Zeitleiste übernehmen (deterministisch), keine Aufnahme.
        for (let w = 0; w < 300; w++) { if (await ev('window.drivetimeExport.pending() === 0')) break; await sleep(10); }
      }
      k++;
    }
    progress({ status: 'encoding', framesDone: done, framesTotal });
    ffmpeg.stdin.end();
    const code = await ffDone;
    if (code !== 0) throw new Error(`ffmpeg ${code}: ${ffErr.slice(-400)}`);
    return { framesDone: done, framesTotal, timelineFrames, fullFrames, truncated: timelineFrames < fullFrames,
      seconds: timelineFrames / PRESETS.timelineFps, waitTimeouts, blockedRequests: net.blocked, requests: net.requests, logs: logs.slice(0, 20), profile: prof };
  } finally {
    cleanup();
  }
}
