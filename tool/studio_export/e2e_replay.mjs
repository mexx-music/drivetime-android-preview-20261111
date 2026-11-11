#!/usr/bin/env node
// End-to-End-Test des Studio-Exports OHNE Netz zu Google/Proxy:
// rechnet eine Tour im Studio-Build über die echte Oberfläche, beantwortet alle
// Proxy-Aufrufe aus einer Aufzeichnung (Tape), klickt „Kontrollvideo erstellen“
// und verfolgt den Auftrag beim Exportdienst bis zur fertigen MP4.
//
//   node tool/studio_export/e2e_replay.mjs <steps.json> <tape.json> [http://127.0.0.1:8150]
//
// steps.json: [{type, text} | {click, exact} | {clickVisible} | {typeVisible, text} | {wait}]
import { spawn } from 'node:child_process';
import { mkdtempSync, readFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

const [, , stepsFile, tapeFile, base = 'http://127.0.0.1:8150'] = process.argv;
const steps = JSON.parse(readFileSync(stepsFile, 'utf8'));
const tape = JSON.parse(readFileSync(tapeFile, 'utf8'));
const W = 1280, H = 1400, PORT = 9395;
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const prof = mkdtempSync(join(tmpdir(), 'dt-e2e-'));
const chrome = spawn('/Applications/Google Chrome.app/Contents/MacOS/Google Chrome', ['--headless=new', `--remote-debugging-port=${PORT}`,
  `--user-data-dir=${prof}`, '--no-first-run', '--ignore-gpu-blocklist', '--use-angle=metal', `--window-size=${W},${H}`, 'about:blank'], { stdio: 'ignore' });
const done = (code) => { try { chrome.kill('SIGKILL'); } catch (_) {} try { rmSync(prof, { recursive: true, force: true }); } catch (_) {} process.exit(code); };
let ws;
for (let i = 0; i < 80 && !ws; i++) { try { const l = await (await fetch(`http://127.0.0.1:${PORT}/json`)).json(); const p = l.find((t) => t.type === 'page'); if (p) ws = new WebSocket(p.webSocketDebuggerUrl); } catch (_) {} await sleep(150); }
if (ws.readyState !== WebSocket.OPEN) await new Promise((r) => ws.addEventListener('open', r));
let id = 0; const pend = new Map(); const net = { replayed: [], missing: [], blocked: [] };
const send = (method, params = {}) => new Promise((res) => { const i = ++id; pend.set(i, res); ws.send(JSON.stringify({ id: i, method, params })); });
ws.addEventListener('message', (e) => {
  const m = JSON.parse(e.data);
  if (m.id && pend.has(m.id)) { pend.get(m.id)(m.result ?? m); pend.delete(m.id); return; }
  if (m.method !== 'Fetch.requestPaused') return;
  const r = m.params.request;
  if (!r.url.includes('drive-time-arrival-proxy')) { net.blocked.push(r.url.slice(0, 120)); send('Fetch.failRequest', { requestId: m.params.requestId, errorReason: 'BlockedByClient' }); return; }
  if (r.method === 'OPTIONS') {
    send('Fetch.fulfillRequest', { requestId: m.params.requestId, responseCode: 204, responseHeaders: [
      { name: 'Access-Control-Allow-Origin', value: '*' }, { name: 'Access-Control-Allow-Headers', value: '*' }, { name: 'Access-Control-Allow-Methods', value: 'POST, GET, OPTIONS' }] });
    return;
  }
  // Wie das bewährte Aufnahmeskript: nach Endpunkt, Suchwort und Reihenfolge.
  const path = new URL(r.url).pathname;
  let word = '';
  try { const b = JSON.parse(r.postData || '{}'); word = String(b.address || b.input || '').split(',')[0].trim().toLowerCase(); } catch (_) {}
  const text = (x) => (x.base64 ? Buffer.from(x.body, 'base64').toString() : x.body).toLowerCase();
  const hit = (word && tape.find((x) => x.path === path && !x.used && text(x).includes(word))) || tape.find((x) => x.path === path && !x.used);
  if (hit) { hit.used = true; net.replayed.push(path); } else net.missing.push(path);
  send('Fetch.fulfillRequest', { requestId: m.params.requestId, responseCode: hit ? 200 : 503,
    responseHeaders: [{ name: 'Content-Type', value: 'application/json' }, { name: 'Access-Control-Allow-Origin', value: '*' }],
    body: hit ? (hit.base64 ? hit.body : Buffer.from(hit.body).toString('base64')) : Buffer.from('{"error":"replay_miss"}').toString('base64') });
});
const ev = async (e) => (await send('Runtime.evaluate', { expression: e, awaitPromise: true, returnByValue: true })).result?.value;
await send('Page.enable'); await send('Runtime.enable');
// Proxy aus der Aufzeichnung, Google gesperrt – kein einziger echter Aufruf.
await send('Fetch.enable', { patterns: ['*drive-time-arrival-proxy*', '*googleapis.com*', '*maps.google.com*'].map((urlPattern) => ({ urlPattern })) });
await send('Page.navigate', { url: base + '/' });
const nodes = () => ev(`(() => { const out = []; for (const el of document.querySelectorAll('flt-semantics, input, textarea')) { const r = el.getBoundingClientRect(); if (!r.width || !r.height) continue;
  const label = (el.getAttribute('aria-label') || el.textContent || el.getAttribute('placeholder') || '').trim().replace(/\\s+/g, ' ');
  out.push({ tag: el.tagName.toLowerCase(), role: el.getAttribute('role') || '', label: label.slice(0, 80), x: r.x + r.width / 2, y: r.y + r.height / 2 }); } return out; })()`);
const find = async (label, { role, exact = false, tries = 120 } = {}) => {
  for (let t = 0; t < tries; t++) { const all = ((await nodes()) || []).filter((n) => (exact ? n.label === label : n.label.includes(label)) && (!role || n.role === role || n.tag === role)); if (all.length) return all[0]; await sleep(250); }
  throw new Error(`nicht gefunden: ${label}`);
};
const tap = async (x, y) => { for (const type of ['mousePressed', 'mouseReleased']) await send('Input.dispatchMouseEvent', { type, x, y, button: 'left', clickCount: 1 }); };
const scrollTo = async (label, role) => {
  for (let t = 0; t < 40; t++) {
    const n = await find(label, { role, tries: 4 }).catch(() => null);
    if (n && n.y > 60 && n.y < H - 120) return n;
    await send('Input.dispatchMouseEvent', { type: 'mouseWheel', x: 300, y: H / 2, deltaX: 0, deltaY: n && n.y < 60 ? -300 : 300 });
    await sleep(400);
  }
  throw new Error(`nicht sichtbar: ${label}`);
};
try {
  for (let t = 0; t < 150; t++) { if (await ev(`!!document.querySelector('flt-semantics-placeholder') || !!document.querySelector('flt-semantics')`)) break; await sleep(200); }
  await ev(`(() => { const p = document.querySelector('flt-semantics-placeholder'); if (p) p.click(); return true; })()`);
  await sleep(1500);
  let clicked = 0;
  for (const s of steps) {
    if (s.wait) await sleep(s.wait);
    if (s.type) { const n = await find(s.type, { role: 'input' }); await tap(n.x, n.y); await sleep(300); await send('Input.insertText', { text: s.text }); }
    if (s.typeVisible) { const n = await scrollTo(s.typeVisible, 'input'); await tap(n.x, n.y); await sleep(300); await send('Input.insertText', { text: s.text }); }
    if (s.click) { const n = await find(s.click, s); await tap(n.x, n.y); }
    if (s.clickVisible) { const n = await scrollTo(s.clickVisible, s.role); await tap(n.x, n.y); }
    console.log('Schritt', JSON.stringify(s));
  }
  // Exportauftrag beim Dienst verfolgen – nur Aufträge, die nach dem Klick begonnen haben.
  const t0 = Date.now(); let last = '';
  for (;;) {
    const jobs = await (await fetch(base + '/api/export')).json();
    const j = jobs.filter((x) => Date.parse(x.startedAt) >= t0 - 15000).pop();
    if (j) {
      const line = `${j.status} ${j.framesDone}/${j.framesTotal}`;
      if (line !== last) { console.log(new Date().toISOString().slice(11, 19), 'Auftrag', j.jobId.slice(0, 8), line); last = line; }
      if (['ready', 'failed', 'cancelled'].includes(j.status)) {
        console.log(JSON.stringify({ job: j, tourAufrufeAusAufzeichnung: net.replayed, fehlendInAufzeichnung: net.missing, gesperrt: net.blocked, sekunden: Math.round((Date.now() - t0) / 1000) }, null, 1));
        done(j.status === 'ready' ? 0 : 2);
      }
    }
    await sleep(2000);
  }
} catch (e) {
  console.error('ABBRUCH', e.message, JSON.stringify(net));
  done(1);
}
