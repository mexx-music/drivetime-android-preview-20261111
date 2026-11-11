// Prüft die lokalen Seewege (lib/logic/ferry_sea_routes.dart) gegen die
// Wasserflächen der Karte, die die Animation zeigt (OpenFreeMap „liberty“,
// OpenMapTiles-Ebene „water“). Entwicklungswerkzeug, nicht Teil der App.
//
//   dart run tool/dump_ferry_sea_routes.dart > /tmp/sea.json
//   node tool/check_ferry_sea_routes.mjs /tmp/sea.json [report.json]
//
// Braucht lokal Google Chrome. Lädt nur Kartenkacheln (wie die App), keine
// kostenpflichtigen Dienste. Jeder Punkt im Abstand von ~250 m wird bei
// Zoom 12 (Hafenzufahrten Zoom 14) abgefragt: liegt er nicht in einer
// Wasserfläche, gilt er als Land.
import { spawn } from 'node:child_process';
import { readFileSync, writeFileSync, rmSync, mkdtempSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

const [, , input, reportPath] = process.argv;
const routes = JSON.parse(readFileSync(input, 'utf8'));
const prof = mkdtempSync(join(tmpdir(), 'seacheck-'));
const chrome = spawn('/Applications/Google Chrome.app/Contents/MacOS/Google Chrome', [
  '--headless=new', '--remote-debugging-port=9344', `--user-data-dir=${prof}`, '--no-first-run',
  '--ignore-gpu-blocklist', '--window-size=1200,1200', 'about:blank'], { stdio: 'ignore' });
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
let ws;
for (let i = 0; i < 50 && !ws; i++) {
  try {
    const list = await (await fetch('http://127.0.0.1:9344/json')).json();
    const page = list.find((t) => t.type === 'page');
    if (page) ws = new WebSocket(page.webSocketDebuggerUrl);
  } catch (_) { /* Chrome startet noch */ }
  await sleep(200);
}
if (ws.readyState !== WebSocket.OPEN) await new Promise((r) => ws.addEventListener('open', r));
let id = 0;
const pending = new Map();
ws.addEventListener('message', (ev) => {
  const m = JSON.parse(ev.data);
  if (m.id && pending.has(m.id)) { pending.get(m.id)(m.error ? { error: m.error } : m.result); pending.delete(m.id); }
});
const send = (method, params = {}) => new Promise((res) => {
  const i = ++id; pending.set(i, res); ws.send(JSON.stringify({ id: i, method, params }));
});
const evaluate = async (expr) => {
  const r = await send('Runtime.evaluate', { expression: expr, awaitPromise: true, returnByValue: true });
  if (r.error || r.exceptionDetails) throw new Error(JSON.stringify(r.error ?? r.exceptionDetails));
  return r.result.value;
};

const html = `<!doctype html><html><head>
<link href="https://unpkg.com/maplibre-gl@4.7.1/dist/maplibre-gl.css" rel="stylesheet">
<script src="https://unpkg.com/maplibre-gl@4.7.1/dist/maplibre-gl.js"></script>
<style>html,body,#m{margin:0;width:1200px;height:1200px}</style></head>
<body><div id="m"></div></body></html>`;
await send('Page.enable');
await send('Runtime.enable');
await send('Page.navigate', { url: 'data:text/html;base64,' + Buffer.from(html).toString('base64') });
for (let i = 0; i < 200; i++) {
  if (await evaluate('!!window.maplibregl').catch(() => false)) break;
  await sleep(100);
}
console.log('MapLibre geladen');
await evaluate(`new Promise((res) => {
  window.map = new maplibregl.Map({container: 'm', style: 'https://tiles.openfreemap.org/styles/liberty',
    center: [12, 55], zoom: 5, interactive: false, fadeDuration: 0});
  map.on('load', () => res(true));
})`);
await evaluate(`window.check = async (pts, zoom) => {
  const land = [];
  let i = 0;
  while (i < pts.length) {
    map.jumpTo({center: [pts[i][1], pts[i][0]], zoom});
    // Warten, bis die Kacheln dieses Ausschnitts geladen und gezeichnet sind.
    for (let t = 0; t < 100; t++) {
      await new Promise((r) => setTimeout(r, 100));
      if (map.loaded() && map.areTilesLoaded()) break;
    }
    await new Promise((r) => requestAnimationFrame(() => requestAnimationFrame(r)));
    const b = map.getBounds();
    let j = i;
    for (; j < pts.length; j++) {
      const [lat, lon] = pts[j];
      if (!b.contains([lon, lat])) break;
      const px = map.project([lon, lat]);
      if (px.x < 20 || px.y < 20 || px.x > 1180 || px.y > 1180) break;
      const water = map.queryRenderedFeatures([px.x, px.y]).some((f) => f.sourceLayer === 'water');
      if (!water) land.push([lat, lon]);
    }
    i = Math.max(j, i + 1);
  }
  return land;
}; true`);

const km = (a, b) => 6371 * Math.hypot((b[0] - a[0]) * Math.PI / 180,
  (b[1] - a[1]) * Math.PI / 180 * Math.cos(a[0] * Math.PI / 180));
const report = [];
for (const r of routes) {
  // Punkte im Abstand von ~250 m entlang der Wegpunkte (linear wie die App).
  const pts = [];
  const wp = r.waypoints;
  for (let i = 1; i < wp.length; i++) {
    const n = Math.max(1, Math.ceil(km(wp[i - 1], wp[i]) / 0.25));
    for (let k = i === 1 ? 0 : 1; k <= n; k++) {
      pts.push([wp[i - 1][0] + (wp[i][0] - wp[i - 1][0]) * k / n, wp[i - 1][1] + (wp[i][1] - wp[i - 1][1]) * k / n]);
    }
  }
  // Hafenzufahrten (erste/letzte 12 km) feiner prüfen.
  let acc = 0;
  const along = pts.map((p, i) => (acc += i ? km(pts[i - 1], p) : 0));
  const total = along[along.length - 1];
  const near = pts.filter((_, i) => along[i] < 12 || total - along[i] < 12);
  const far = pts.filter((_, i) => !(along[i] < 12 || total - along[i] < 12));
  const land = [...await evaluate(`check(${JSON.stringify(near)}, 14)`),
    ...await evaluate(`check(${JSON.stringify(far)}, 12)`)];
  report.push({ a: r.a, b: r.b, samples: pts.length, km: Math.round(total), land });
  console.log(`${r.a} – ${r.b}: ${pts.length} Punkte, ${Math.round(total)} km, Land: ${land.length}` +
    (land.length ? `  z. B. ${land.slice(0, 3).map((p) => p.map((v) => v.toFixed(4)).join(',')).join(' | ')}` : ''));
}
if (reportPath) writeFileSync(reportPath, JSON.stringify(report, null, 1));
ws.close();
chrome.kill();
await new Promise((r) => chrome.once('exit', r));
rmSync(prof, { recursive: true, force: true, maxRetries: 5, retryDelay: 200 });
