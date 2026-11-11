import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/services.dart' show AssetBundle, rootBundle;
import 'package:latlong2/latlong.dart';

import 'tour_path.dart';

/// Ein Land aus der mitgelieferten Grenzdatei (Natural Earth, vereinfacht).
class CountryShape {
  CountryShape._(this.iso, this.name, this.polygons) {
    for (final poly in polygons) {
      for (final ring in poly) {
        final lon = Float64List(ring.length);
        final lat = Float64List(ring.length);
        var w = 180.0, e = -180.0, s = 90.0, n = -90.0;
        for (var i = 0; i < ring.length; i++) {
          lon[i] = ring[i].longitude;
          lat[i] = ring[i].latitude;
          if (lon[i] < w) w = lon[i];
          if (lon[i] > e) e = lon[i];
          if (lat[i] < s) s = lat[i];
          if (lat[i] > n) n = lat[i];
        }
        _rings.add((lon, lat, w, e, s, n));
        if (w < _w) _w = w;
        if (e > _e) _e = e;
        if (s < _s) _s = s;
        if (n > _n) _n = n;
      }
    }
  }

  /// ISO-3166-Code, z. B. „AT“; Kosovo „XK“.
  final String iso;

  /// Deutscher Name, z. B. „Österreich“.
  final String name;

  /// Flächen zum Zeichnen: je Fläche zuerst der Außenring, dann Löcher.
  final List<List<List<LatLng>>> polygons;

  final List<(Float64List, Float64List, double, double, double, double)> _rings = [];
  double _w = 180, _e = -180, _s = 90, _n = -90;

  /// Gerade/ungerade-Regel über alle Ringe: Löcher (Enklaven) zählen mit.
  bool contains(LatLng p) {
    final x = p.longitude;
    final y = p.latitude;
    if (x < _w || x > _e || y < _s || y > _n) return false;
    var inside = false;
    for (final (lon, lat, w, e, s, n) in _rings) {
      if (x < w || x > e || y < s || y > n) continue;
      var j = lon.length - 1;
      for (var i = 0; i < lon.length; i++) {
        final yi = lat[i];
        final yj = lat[j];
        if ((yi > y) != (yj > y) && x < (lon[j] - lon[i]) * (y - yi) / (yj - yi) + lon[i]) {
          inside = !inside;
        }
        j = i;
      }
    }
    return inside;
  }

  /// Abstand von [p] zur nächsten Grenzlinie dieses Landes in Metern
  /// (lokal eben gerechnet – für Abstände von einigen Kilometern genau
  /// genug). Ringe, deren Rahmen weiter als [within] Meter entfernt ist,
  /// werden übersprungen; dann ist das Ergebnis höchstens [within].
  double edgeDistanceMeters(LatLng p, {double within = 50000}) {
    const mPerDeg = 111320.0;
    final x0 = p.longitude, y0 = p.latitude;
    final kx = mPerDeg * math.cos(y0 * math.pi / 180);
    final padLat = within / mPerDeg, padLon = within / kx;
    var best = within * within;
    for (final (lon, lat, w, e, s, n) in _rings) {
      if (x0 < w - padLon || x0 > e + padLon || y0 < s - padLat || y0 > n + padLat) continue;
      var j = lon.length - 1;
      for (var i = 0; i < lon.length; i++) {
        final ax = (lon[j] - x0) * kx, ay = (lat[j] - y0) * mPerDeg;
        final bx = (lon[i] - x0) * kx, by = (lat[i] - y0) * mPerDeg;
        final dx = bx - ax, dy = by - ay;
        final len2 = dx * dx + dy * dy;
        final t = len2 == 0 ? 0.0 : (-(ax * dx + ay * dy) / len2).clamp(0.0, 1.0);
        final qx = ax + t * dx, qy = ay + t * dy;
        final d2 = qx * qx + qy * qy;
        if (d2 < best) best = d2;
        j = i;
      }
    }
    return math.sqrt(best);
  }
}

/// Alle Länder der Grenzdatei mit Suche nach Ort.
class CountryIndex {
  CountryIndex._(this.countries) : _byIso = {for (final c in countries) c.iso: c};

  /// Aus der Datei von `tool/build_country_borders.py`.
  factory CountryIndex.fromJson(Map<String, dynamic> json) {
    final q = (json['q'] as num).toDouble();
    final out = <CountryShape>[];
    for (final c in (json['countries'] as List).cast<Map<String, dynamic>>()) {
      final polygons = <List<List<LatLng>>>[
        for (final poly in (c['polygons'] as List))
          [
            for (final ring in (poly as List)) _decode((ring as List).cast<num>(), q),
          ],
      ];
      out.add(CountryShape._(c['iso'] as String, c['name'] as String, polygons));
    }
    return CountryIndex._(out);
  }

  static List<LatLng> _decode(List<num> ring, double q) {
    var x = 0, y = 0;
    return [
      for (var i = 0; i + 1 < ring.length; i += 2) LatLng((y += ring[i + 1].toInt()) / q, (x += ring[i].toInt()) / q),
    ];
  }

  static const assetPath = 'assets/geo/countries.json';
  static Future<CountryIndex>? _loading;

  /// Lädt die Grenzdatei einmal pro App-Lauf – erst wenn eine Animation sie
  /// braucht. Sie kommt vom eigenen Webserver, nicht von einem Kartendienst.
  static Future<CountryIndex> load([AssetBundle? bundle]) => _loading ??= () async {
        try {
          final s = await (bundle ?? rootBundle).loadString(assetPath);
          return CountryIndex.fromJson(jsonDecode(s) as Map<String, dynamic>);
        } catch (_) {
          _loading = null; // nächster Versuch lädt neu
          rethrow;
        }
      }();

  final List<CountryShape> countries;
  final Map<String, CountryShape> _byIso;

  CountryShape? byIso(String iso) => _byIso[iso];

  /// Land an [p]; null auf See oder außerhalb der Daten. [prefer] wird zuerst
  /// geprüft – meist bleibt die Route im selben Land.
  String? countryAt(LatLng p, {String? prefer}) {
    if (prefer != null && (_byIso[prefer]?.contains(p) ?? false)) return prefer;
    for (final c in countries) {
      if (c.iso != prefer && c.contains(p)) return c.iso;
    }
    return null;
  }
}

/// Übertritt von [fromIso] nach [toIso] bei [meters] entlang der Tour.
class BorderCrossing {
  const BorderCrossing({required this.meters, required this.fromIso, required this.toIso});

  final double meters;
  final String fromIso;
  final String toIso;

  @override
  String toString() => 'BorderCrossing($fromIso→$toIso @ ${meters.round()} m)';
}

/// Grenzübertritte entlang der vorhandenen Routengeometrie – ohne Dienst.
///
/// Tastet die Linie alle [sampleMeters] ab. Ein neues Land zählt erst, wenn
/// die Route mindestens [minStayMeters] darin bleibt (oder dort endet): Straßen
/// entlang einer Grenze und ungenaue, vereinfachte Grenzlinien erzeugen so
/// kein Flattern. Die Stelle wird danach per Halbierung auf
/// [precisionMeters] genau bestimmt. Auf See (Fähre) gibt es kein Land; der
/// Wechsel erscheint dort, wo die Route nach der Überfahrt wieder Land hat.
///
/// Danach fallen Grenzberührungen weg: Ein Land zwischen zwei Übertritten
/// zählt nur, wenn die Route darin mindestens [minDepthMeters] Abstand zu den
/// Grenzen der Nachbarländer davor und danach gewinnt. Läuft eine Straße
/// lange direkt an der Grenze (Donau am Eisernen Tor, Serbien/Rumänien),
/// pendelt die vereinfachte Grenzlinie sonst über viele Kilometer hin und
/// her. Echte kurze Durchfahrten (Deutsches Eck, Neum) liegen tiefer.
List<BorderCrossing> detectBorderCrossings(
  TourPath path,
  CountryIndex index, {
  double sampleMeters = 1000,
  double minStayMeters = 2000,
  double minDepthMeters = 2500,
  double precisionMeters = 25,
}) {
  final total = path.totalMeters;
  if (total <= 0) return const [];
  final n = (total / sampleMeters).ceil();
  double distAt(int k) => k >= n ? total : k * sampleMeters;

  String? current;
  String? lastSeen;
  String? isoAt(double d) {
    final pos = path.at(d);
    if (pos.kind == TourLegKind.ferry) return null; // Seestrecke: kein Land
    return lastSeen = index.countryAt(pos.point, prefer: lastSeen ?? current);
  }

  final out = <BorderCrossing>[];
  String? candidate;
  var candidateFirst = 0;

  for (var k = 0; k <= n; k++) {
    final d = distAt(k);
    final iso = isoAt(d);
    if (iso == null) continue;
    if (current == null) {
      current = iso;
      continue;
    }
    if (iso == current) {
      candidate = null;
      continue;
    }
    if (iso != candidate) {
      candidate = iso;
      candidateFirst = k;
    }
    final stayed = d - distAt(candidateFirst);
    if (stayed + 1e-6 >= minStayMeters || k == n) {
      // Übergang zwischen dem letzten Punkt davor und dem ersten im neuen Land.
      var lo = candidateFirst == 0 ? 0.0 : distAt(candidateFirst - 1);
      var hi = distAt(candidateFirst);
      while (hi - lo > precisionMeters) {
        final mid = (lo + hi) / 2;
        if (isoAt(mid) == candidate) {
          hi = mid;
        } else {
          lo = mid;
        }
      }
      out.add(BorderCrossing(meters: hi, fromIso: current, toIso: iso));
      current = candidate;
      candidate = null;
    }
  }
  return _dropBorderTouches(out, path, index, minDepthMeters, sampleMeters / 4);
}

/// Entfernt flache Abstecher (siehe [detectBorderCrossings]), den flachsten
/// zuerst – so lösen sich auch mehrfache Pendel A→B→A→B→A ganz auf. Führt
/// der Abstecher in ein drittes Land weiter (A→B→C), bleibt ein Übertritt
/// A→C an der ersten Stelle.
List<BorderCrossing> _dropBorderTouches(
  List<BorderCrossing> crossings,
  TourPath path,
  CountryIndex index,
  double minDepth,
  double step,
) {
  if (minDepth <= 0) return crossings;
  final out = List<BorderCrossing>.of(crossings);
  double depth(int i) {
    final a = index.byIso(out[i].fromIso), c = index.byIso(out[i + 1].toIso);
    if (a == null || c == null) return double.infinity;
    final from = out[i].meters, to = out[i + 1].meters;
    var best = 0.0;
    for (var m = from + step / 2; m < to; m += step) {
      final p = path.at(m).point;
      final d = math.min(a.edgeDistanceMeters(p, within: minDepth), c.edgeDistanceMeters(p, within: minDepth));
      if (d > best) best = d;
      if (best >= minDepth) break;
    }
    return best;
  }

  while (out.length >= 2) {
    var worst = -1;
    var worstDepth = minDepth;
    for (var i = 0; i + 1 < out.length; i++) {
      final d = depth(i);
      if (d < worstDepth) {
        worst = i;
        worstDepth = d;
      }
    }
    if (worst < 0) break;
    final a = out[worst], c = out[worst + 1];
    out.removeRange(worst, worst + 2);
    if (a.fromIso != c.toIso) {
      out.insert(worst, BorderCrossing(meters: a.meters, fromIso: a.fromIso, toIso: c.toIso));
    }
  }
  return out;
}
