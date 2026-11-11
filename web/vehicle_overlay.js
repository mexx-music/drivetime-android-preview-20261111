// Fahrzeug-Overlay der 2.5D-Vorschau (DriveTime).
//
// Lkw und Abblendlicht werden nicht mehr als MapLibre-Symbole über eigene
// GeoJSON-Quellen gezeichnet: jede Positionsänderung baute dort die Kacheln
// samt Bildatlas neu (gemessen 60–200 MB neu angelegte WebGL-Texturen pro
// Sekunde), was die installierte iOS-Web-App beenden kann. Stattdessen ein
// einziger 2D-Canvas über der Karte, gezeichnet im render-Ereignis der Karte –
// also genau zum Bild, das MapLibre gerade gezeichnet hat.
//
// Geometrie wie MapLibre-Symbole:
//  - Lkw: aufrecht zum Betrachter (viewport), Anker Mitte, Größe = Bild ×
//    size × Perspektivfaktor, Drehung in Grad im Bildschirm.
//  - Licht: flach auf der Karte (map), Anker unten, Drehung = Kurs, Größe in
//    Kartenpixeln × Perspektivfaktor; als eigenes Bildelement per CSS
//    matrix3d perspektivisch auf die vier Bodenpunkte gelegt.
// Perspektivfaktor wie im MapLibre-Shader (symbol_icon.vertex):
//   0.5 + 0.5 · Abstandsverhältnis (viewport: Mitte/Anker, map: Anker/Mitte).
(function () {
  'use strict';
  const O = { map: null, canvas: null, ctx: null, state: null, drawn: null, cone: null, coneName: null };
  const slots = {}; // Bildname → {canvas, ctx, w, h} (je Art ein Puffer)

  function slot(kind) {
    if (!slots[kind]) {
      const c = document.createElement('canvas');
      c.width = 1024; c.height = 1024; // fest: kein Neuanlegen je Bild
      slots[kind] = { c, x: c.getContext('2d'), name: null, w: 0, h: 0 };
    }
    return slots[kind];
  }

  // Bild aus dem Bildspeicher der Karte (dieselben Pixel wie bisher) in den
  // Puffer übernehmen – nur wenn sich der Name ändert.
  function image(kind, name) {
    const s = slot(kind);
    if (s.name === name) return s;
    const im = O.map.style.getImage(name);
    const d = im && im.data;
    if (!d || !d.width || d.width > 1024 || d.height > 1024) return null;
    s.x.clearRect(0, 0, 1024, 1024);
    s.x.putImageData(new ImageData(new Uint8ClampedArray(d.data.buffer, d.data.byteOffset, d.width * d.height * 4), d.width, d.height), 0, 0);
    s.name = name; s.w = d.width; s.h = d.height;
    return s;
  }

  function transform() { return O.map._camera && O.map._camera.transform; }

  function world(lng, lat, ws) {
    const s = Math.sin(lat * Math.PI / 180);
    return [(lng + 180) / 360 * ws, (0.5 - Math.log((1 + s) / (1 - s)) / (4 * Math.PI)) * ws];
  }

  // Weltpixel → Bildschirm (CSS-Pixel) und w (Abstand zur Kamera).
  function screen(m, x, y) {
    const w = m[3] * x + m[7] * y + m[15];
    return [(m[0] * x + m[4] * y + m[12]) / w, (m[1] * x + m[5] * y + m[13]) / w, w];
  }

  function resize() {
    const mc = O.map.getCanvas();
    if (O.canvas.width !== mc.width || O.canvas.height !== mc.height) {
      O.canvas.width = mc.width; O.canvas.height = mc.height;
    }
    O.canvas.style.width = mc.style.width; O.canvas.style.height = mc.style.height;
    return mc.width / (mc.clientWidth || mc.width);
  }

  // Homographie Bildrechteck (0,0)-(w,0)-(w,h)-(0,h) → vier Bildschirmpunkte.
  function homography(w, h, q) {
    const src = [[0, 0], [w, 0], [w, h], [0, h]];
    const A = [], B = [];
    for (let i = 0; i < 4; i++) {
      const [x, y] = src[i], [u, v] = q[i];
      A.push([x, y, 1, 0, 0, 0, -u * x, -u * y]); B.push(u);
      A.push([0, 0, 0, x, y, 1, -v * x, -v * y]); B.push(v);
    }
    for (let c = 0; c < 8; c++) { // Gauß mit Pivot
      let p = c;
      for (let r = c + 1; r < 8; r++) if (Math.abs(A[r][c]) > Math.abs(A[p][c])) p = r;
      [A[c], A[p]] = [A[p], A[c]]; [B[c], B[p]] = [B[p], B[c]];
      if (Math.abs(A[c][c]) < 1e-12) return null;
      for (let r = c + 1; r < 8; r++) {
        const f = A[r][c] / A[c][c];
        for (let k = c; k < 8; k++) A[r][k] -= f * A[c][k];
        B[r] -= f * B[c];
      }
    }
    const X = new Array(8);
    for (let r = 7; r >= 0; r--) {
      let sum = B[r];
      for (let k = r + 1; k < 8; k++) sum -= A[r][k] * X[k];
      X[r] = sum / A[r][r];
    }
    return X; // a b c d e f g h
  }

  // Licht flach auf der Karte: eigenes Bildelement, perspektivisch per CSS
  // matrix3d auf die vier Bodenpunkte gelegt – der Browser bildet eine Ebene
  // nahtlos ab; die Bildtextur bleibt dieselbe, nur die Lage ändert sich.
  function placeCone(t, m, c) {
    const el = O.cone;
    if (!c || !(c.op > 0.003)) { el.style.display = 'none'; return; }
    const im = O.map.style.getImage(c.img);
    const d = im && im.data;
    if (!d) { el.style.display = 'none'; return; }
    if (O.coneName !== c.img) {
      el.width = d.width; el.height = d.height;
      el.getContext('2d').putImageData(new ImageData(new Uint8ClampedArray(d.data.buffer, d.data.byteOffset, d.width * d.height * 4), d.width, d.height), 0, 0);
      O.coneName = c.img;
    }
    const ws = t.worldSize, ctc = t.cameraToCenterDistance;
    const [ax, ay] = world(c.lng, c.lat, ws);
    const a = screen(m, ax, ay);
    const ratio = Math.min(4, Math.max(0, 0.5 + 0.5 * (a[2] / ctc)));
    const W = d.width * c.size * ratio, H = d.height * c.size * ratio;
    const h = c.heading * Math.PI / 180;
    const fx = Math.sin(h), fy = -Math.cos(h), rx = Math.cos(h), ry = Math.sin(h);
    const g = (u, v) => screen(m, ax + rx * u * W + fx * v * H, ay + ry * u * W + fy * v * H);
    const q = [g(-0.5, 1), g(0.5, 1), g(0.5, 0), g(-0.5, 0)]; // Bild oben = vorn
    if (q.some((p) => !(p[2] > 0))) { el.style.display = 'none'; return; }
    const H8 = homography(d.width, d.height, q);
    if (!H8) { el.style.display = 'none'; return; }
    const [A, B, C, D, E, F, G, Hh] = H8;
    el.style.transform = `matrix3d(${A},${D},0,${G},${B},${E},0,${Hh},0,0,1,0,${C},${F},0,1)`;
    el.style.opacity = String(Math.max(0, Math.min(1, c.op)));
    el.style.display = 'block';
  }

  function drawTruck(ctx, t, m, k) {
    const s = image('truck', k.img);
    if (!s) return false;
    const [x, y] = world(k.lng, k.lat, t.worldSize);
    const p = screen(m, x, y);
    const ratio = Math.min(4, Math.max(0, 0.5 + 0.5 * (t.cameraToCenterDistance / p[2])));
    const w = s.w * k.size * ratio, h = s.h * k.size * ratio;
    ctx.save();
    ctx.globalAlpha = Math.max(0, Math.min(1, k.op));
    ctx.translate(p[0], p[1]);
    ctx.rotate(k.rot * Math.PI / 180);
    ctx.drawImage(s.c, 0, 0, s.w, s.h, -w / 2, -h / 2, w, h);
    ctx.restore();
    return true;
  }

  function draw() {
    if (!O.map || !O.ctx) return;
    const pr = resize();
    const ctx = O.ctx;
    ctx.setTransform(1, 0, 0, 1, 0, 0);
    ctx.clearRect(0, 0, O.canvas.width, O.canvas.height);
    O.drawn = null;
    const st = O.state, t = transform();
    const m = t && (t._pixelMatrix || t.pixelMatrix);
    placeCone(t, m, st && m ? st.cone : null);
    if (!st || !t || !m) return;
    ctx.setTransform(pr, 0, 0, pr, 0, 0);
    if (st.truck && st.truck.op > 0.001 && drawTruck(ctx, t, m, st.truck)) O.drawn = st.truck.img;
  }

  window.dtVehicleOverlay = {
    attach(map) {
      if (O.map === map) return true;
      this.detach();
      const cone = document.createElement('canvas');
      cone.style.cssText = 'position:absolute;left:0;top:0;pointer-events:none;transform-origin:0 0;display:none;';
      const c = document.createElement('canvas');
      c.style.cssText = 'position:absolute;left:0;top:0;pointer-events:none;';
      const host = map.getCanvasContainer();
      host.appendChild(cone); // Licht unter dem Lkw
      host.appendChild(c);
      O.map = map; O.canvas = c; O.ctx = c.getContext('2d'); O.cone = cone; O.coneName = null;
      map.on('render', draw);
      map.on('resize', draw);
      return true;
    },
    detach() {
      if (O.map) { O.map.off('render', draw); O.map.off('resize', draw); }
      for (const el of [O.canvas, O.cone]) if (el && el.parentNode) el.parentNode.removeChild(el);
      O.map = O.canvas = O.ctx = O.state = O.drawn = O.cone = O.coneName = null;
      for (const k of Object.keys(slots)) slots[k].name = null;
    },
    // Zustand des Bildes; gezeichnet beim nächsten render der Karte (die
    // Szene stößt das Neuzeichnen an).
    set(state) {
      O.state = state;
      if (O.map) O.map.triggerRepaint();
    },
    drawn() { return O.drawn; },
  };
})();
