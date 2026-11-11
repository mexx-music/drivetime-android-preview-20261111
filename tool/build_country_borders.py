#!/usr/bin/env python3
"""Ländergrenzen für die Tour-Animation aus Natural Earth erzeugen.

Quelle: Natural Earth, 1:10m Cultural Vectors, Admin 0 – Countries in der
Fassung „Point of View Germany“ (gemeinfrei,
https://www.naturalearthdata.com/about/terms-of-use/). Diese Fassung ordnet
Gebiete so zu, wie Deutschland sie anerkennt (z. B. Krim → Ukraine).

    curl -L -o ne10_deu.geojson \\
      https://raw.githubusercontent.com/nvkelso/natural-earth-vector/master/geojson/ne_10m_admin_0_countries_deu.geojson
    python3 tool/build_country_borders.py ne10_deu.geojson assets/geo/countries.json

Flaggen (assets/flags/<iso>.png, 80 px breit) für genau diese Länder:

    python3 tool/build_country_borders.py --flags assets/geo/countries.json assets/flags

Ausschnitt: Europa samt UK/Irland, Island, Balkan, Türkei, Kaukasus, Naher
Osten am Rand und Nordafrika (Länge -25..52, Breite 27..72). Die Ringe werden auf das Fenster zugeschnitten,
vereinfacht (Douglas-Peucker), auf 1e-4 Grad (~11 m) gerundet und als
Differenzen kodiert. Ohne Abhängigkeiten außer der Python-Standardbibliothek.
"""
import json
import sys

WEST, EAST, SOUTH, NORTH = -25.0, 52.0, 27.0, 72.0
TOLERANCE = 0.003  # Grad, etwa 200–330 m
MIN_RING_AREA = 0.003  # Grad² (~20 km²), kleinere Inseln weg (größter Ring bleibt immer)
SKIP = {'GL'}  # Grönland: keine Straßenverbindung, nur Größe
Q = 10000


def clip(ring):
    """Sutherland-Hodgman gegen das (konvexe) Fenster."""
    def run(points, inside, cut):
        out = []
        if not points:
            return out
        prev = points[-1]
        for cur in points:
            if inside(cur):
                if not inside(prev):
                    out.append(cut(prev, cur))
                out.append(cur)
            elif inside(prev):
                out.append(cut(prev, cur))
            prev = cur
        return out

    def at_x(x):
        return lambda a, b: (x, a[1] + (b[1] - a[1]) * (x - a[0]) / (b[0] - a[0]))

    def at_y(y):
        return lambda a, b: (a[0] + (b[0] - a[0]) * (y - a[1]) / (b[1] - a[1]), y)

    pts = [tuple(p[:2]) for p in ring]
    pts = run(pts, lambda p: p[0] >= WEST, at_x(WEST))
    pts = run(pts, lambda p: p[0] <= EAST, at_x(EAST))
    pts = run(pts, lambda p: p[1] >= SOUTH, at_y(SOUTH))
    pts = run(pts, lambda p: p[1] <= NORTH, at_y(NORTH))
    return pts


def simplify(points, tol):
    if len(points) < 3:
        return points
    keep = [False] * len(points)
    keep[0] = keep[-1] = True
    stack = [(0, len(points) - 1)]
    while stack:
        a, b = stack.pop()
        ax, ay = points[a]
        bx, by = points[b]
        dx, dy = bx - ax, by - ay
        norm = (dx * dx + dy * dy) ** 0.5
        best, idx = -1.0, -1
        for i in range(a + 1, b):
            px, py = points[i]
            if norm == 0:
                d = ((px - ax) ** 2 + (py - ay) ** 2) ** 0.5
            else:
                d = abs(dy * px - dx * py + bx * ay - by * ax) / norm
            if d > best:
                best, idx = d, i
        if best > tol:
            keep[idx] = True
            stack.append((a, idx))
            stack.append((idx, b))
    return [p for p, k in zip(points, keep) if k]


def area(ring):
    s = 0.0
    for i in range(len(ring)):
        x1, y1 = ring[i - 1]
        x2, y2 = ring[i]
        s += x1 * y2 - x2 * y1
    return abs(s) / 2


def encode(ring):
    out, lx, ly = [], 0, 0
    for x, y in ring:
        qx, qy = round(x * Q), round(y * Q)
        if out and qx == lx and qy == ly:
            continue
        out += [qx - lx, qy - ly]
        lx, ly = qx, qy
    return out


def main(src, dst):
    data = json.load(open(src, encoding='utf-8'))
    countries = []
    for f in data['features']:
        p = f['properties']
        iso = p.get('ISO_A2_EH')
        if not iso or iso == '-99' or iso in SKIP:
            continue  # z. B. Pufferzonen, international nicht anerkannte Gebiete
        g = f['geometry']
        polys = g['coordinates'] if g['type'] == 'MultiPolygon' else [g['coordinates']]
        kept = []
        for poly in polys:
            rings = []
            for k, ring in enumerate(poly):
                c = clip(ring)
                if len(c) < 3:
                    if k == 0:
                        break  # Außenring außerhalb -> ganzes Polygon weg
                    continue
                c = simplify(c + [c[0]], TOLERANCE)[:-1]
                if len(c) >= 3:
                    rings.append(c)
                elif k == 0:
                    break
            if rings:
                kept.append(rings)
        if not kept:
            continue
        largest = max(area(r[0]) for r in kept)
        kept = [r for r in kept if area(r[0]) >= MIN_RING_AREA or area(r[0]) == largest]
        countries.append({
            'iso': iso,
            'name': p.get('NAME_DE') or p['NAME'],
            'polygons': [[encode(r) for r in rings] for rings in kept],
        })
    countries.sort(key=lambda c: c['iso'])
    out = {
        'source': 'Natural Earth 1:10m Admin 0 Countries, POV Germany (public domain), '
                  'vereinfacht für DriveTime (tool/build_country_borders.py)',
        'window': [WEST, SOUTH, EAST, NORTH],
        'q': Q,
        'countries': countries,
    }
    with open(dst, 'w', encoding='utf-8') as fh:
        json.dump(out, fh, ensure_ascii=False, separators=(',', ':'))
    print(f'{len(countries)} Länder -> {dst}')


def flags(countries_json, out_dir):
    """Flaggen einmalig laden (Wikimedia-Flaggen, gemeinfrei, über flagcdn.com)."""
    import os
    import urllib.request
    os.makedirs(out_dir, exist_ok=True)
    for c in json.load(open(countries_json, encoding='utf-8'))['countries']:
        iso = c['iso'].lower()
        url = f'https://flagcdn.com/w80/{iso}.png'
        with urllib.request.urlopen(url) as r, open(f'{out_dir}/{iso}.png', 'wb') as fh:
            fh.write(r.read())
    print(f'Flaggen -> {out_dir}')


if __name__ == '__main__':
    if sys.argv[1] == '--flags':
        flags(sys.argv[2], sys.argv[3])
    else:
        main(sys.argv[1], sys.argv[2])
