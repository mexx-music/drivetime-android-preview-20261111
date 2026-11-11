import 'dart:math' as math;

import 'package:latlong2/latlong.dart';

import '../services/map_launcher.dart';

/// Art eines Abschnitts: nur auf der Straße zählen Kilometer.
enum TourLegKind { road, ferry, gap }

/// Ein Abschnitt der animierten Tour.
class TourLeg {
  const TourLeg({required this.points, this.kind = TourLegKind.road, this.label});

  final List<LatLng> points;
  final TourLegKind kind;
  final String? label;
}

/// Ort des Fahrzeugs an einer Stelle der Tour.
class TourPosition {
  const TourPosition({
    required this.point,
    required this.meters,
    required this.roadMeters,
    required this.bearing,
    required this.kind,
  });

  final LatLng point;

  /// Zurückgelegt entlang der ganzen Linie (inkl. Fähre).
  final double meters;

  /// Davon auf der Straße – Grundlage des Kilometerzählers.
  final double roadMeters;

  /// Fahrtrichtung in Grad, 0 = Norden, im Uhrzeigersinn.
  final double bearing;
  final TourLegKind kind;
}

/// Bereits gefahrener Teil eines Abschnitts, zum Zeichnen.
class TourTrail {
  const TourTrail(this.points, this.kind);

  final List<LatLng> points;
  final TourLegKind kind;
}

/// Die Route als Linie mit Streckenmaß – reine Rechnung, ohne Flutter.
///
/// Entsteht ausschließlich aus Daten einer abgeschlossenen Berechnung
/// ([RouteMapPlan]); fragt nie einen Dienst an. Positionen werden nach
/// zurückgelegter Strecke bestimmt, nicht nach Punktnummer: Polylinien haben
/// in Kurven dichte und auf Autobahnen weite Punktabstände.
///
/// Bewusst unabhängig von Bildschirm, Uhr und Karte, damit dieselbe Linie
/// später auch für andere Formate (9:16, 16:9, Videoexport) dient.
class TourPath {
  TourPath(List<TourLeg> legs) : legs = [for (final l in legs) if (l.points.length >= 2) l] {
    for (final leg in this.legs) {
      for (var i = 0; i < leg.points.length; i++) {
        final p = leg.points[i];
        if (_points.isEmpty) {
          _add(p, 0, TourLegKind.road);
        } else if (i == 0) {
          // Übergang zwischen zwei Abschnitten, die nicht am selben Punkt
          // enden und beginnen: verbinden, aber ohne Straßenkilometer.
          if (p != _points.last) _add(p, _distance(_points.last, p), TourLegKind.gap);
        } else {
          _add(p, _distance(_points.last, p), leg.kind);
        }
        if (i == 0) _legStart = _points.length - 1;
      }
      _legRanges.add((_legStart, _points.length - 1));
    }
  }

  /// Aus genau dem, was die Karte zeigt: Fährroute in Abschnitten, sonst die
  /// berechnete Polyline. Ohne Streckenführung gibt es nichts zu animieren.
  static TourPath? fromMapPlan(RouteMapPlan plan) {
    if (!plan.available || plan.markersOnly) return null;
    final legs = plan.segments.isNotEmpty
        ? [
            for (final s in plan.segments)
              TourLeg(
                points: s.points,
                label: s.label,
                kind: s.isFerry
                    ? TourLegKind.ferry
                    : (s.isGap ? TourLegKind.gap : TourLegKind.road),
              ),
          ]
        : [TourLeg(points: plan.route)];
    final path = TourPath(legs);
    return path.totalMeters > 0 ? path : null;
  }

  final List<TourLeg> legs;

  final List<LatLng> _points = [];

  /// Strecke vom Anfang bis Punkt i.
  final List<double> _cum = [];

  /// Straßenstrecke vom Anfang bis Punkt i.
  final List<double> _roadCum = [];

  /// Art der Kante von Punkt i-1 nach i (Index 0 unbenutzt).
  final List<TourLegKind> _edgeKind = [];

  /// Punktbereich je Abschnitt in der Gesamtliste (inklusive).
  final List<(int, int)> _legRanges = [];
  int _legStart = 0;

  static const _haversine = Distance(calculator: Haversine());

  static double _distance(LatLng a, LatLng b) => _haversine(a, b);

  void _add(LatLng p, double d, TourLegKind kind) {
    final prev = _cum.isEmpty ? 0.0 : _cum.last;
    final prevRoad = _roadCum.isEmpty ? 0.0 : _roadCum.last;
    _points.add(p);
    _cum.add(prev + d);
    _roadCum.add(prevRoad + (kind == TourLegKind.road ? d : 0));
    _edgeKind.add(kind);
  }

  List<LatLng> get points => List.unmodifiable(_points);

  /// Streckenbereich je Abschnitt (von/bis in Metern ab Start), mit Art und
  /// Beschriftung – z. B. um eine Fährüberfahrt auf der Linie zu finden.
  List<({double from, double to, TourLegKind kind, String? label})> get legSpans => [
        for (var k = 0; k < legs.length; k++)
          (from: _cum[_legRanges[k].$1], to: _cum[_legRanges[k].$2], kind: legs[k].kind, label: legs[k].label),
      ];
  double get totalMeters => _cum.isEmpty ? 0 : _cum.last;
  double get roadMeters => _roadCum.isEmpty ? 0 : _roadCum.last;
  LatLng get start => _points.first;
  LatLng get end => _points.last;

  /// Index i mit _cum[i] <= m < _cum[i+1] (binäre Suche).
  int _edgeAt(double m) {
    var lo = 0;
    var hi = _cum.length - 1;
    while (hi - lo > 1) {
      final mid = (lo + hi) >> 1;
      if (_cum[mid] <= m) {
        lo = mid;
      } else {
        hi = mid;
      }
    }
    return lo;
  }

  LatLng _pointAt(double m) {
    final d = m.clamp(0.0, totalMeters);
    if (d >= totalMeters) return end;
    final i = _edgeAt(d);
    final len = _cum[i + 1] - _cum[i];
    if (len <= 0) return _points[i + 1];
    final t = (d - _cum[i]) / len;
    final a = _points[i];
    final b = _points[i + 1];
    return LatLng(
      a.latitude + (b.latitude - a.latitude) * t,
      a.longitude + (b.longitude - a.longitude) * t,
    );
  }

  /// Position nach [meters] zurückgelegter Strecke.
  TourPosition at(double meters) {
    final d = meters.clamp(0.0, totalMeters);
    final i = d >= totalMeters ? _cum.length - 2 : _edgeAt(d);
    final len = _cum[i + 1] - _cum[i];
    final t = len <= 0 ? 1.0 : ((d - _cum[i]) / len).clamp(0.0, 1.0);
    final kind = _edgeKind[i + 1];
    final road = _roadCum[i] + (kind == TourLegKind.road ? len * t : 0);
    return TourPosition(
      point: _pointAt(d),
      meters: d,
      roadMeters: road,
      bearing: _bearingAt(d),
      kind: kind,
    );
  }

  /// Streckenmeter, an dem [roadMeters] Straßenkilometer gefahren sind –
  /// Umkehrung des Kilometerzählers. Auf einer Fähre steht der Zähler still;
  /// geliefert wird dann der erste Meter mit diesem Stand (Fährbeginn).
  double metersAtRoad(double roadMeters) {
    if (roadMeters <= 0) return 0;
    if (roadMeters >= this.roadMeters) {
      // Erster Punkt mit vollem Stand – danach kann nur noch Fähre/Lücke folgen.
      var i = _roadCum.length - 1;
      while (i > 0 && _roadCum[i - 1] >= this.roadMeters) {
        i--;
      }
      return _cum[i];
    }
    var lo = 0;
    var hi = _roadCum.length - 1;
    while (hi - lo > 1) {
      final mid = (lo + hi) >> 1;
      if (_roadCum[mid] < roadMeters) {
        lo = mid;
      } else {
        hi = mid;
      }
    }
    // Kante lo -> hi enthält den Stand; nur Straßenkanten zählen.
    final roadLen = _roadCum[hi] - _roadCum[lo];
    if (roadLen <= 0) return _cum[hi];
    final t = (roadMeters - _roadCum[lo]) / roadLen;
    return _cum[lo] + (_cum[hi] - _cum[lo]) * t;
  }

  /// Position bei Anteil [fraction] (0 = Start, 1 = Ziel) der Gesamtstrecke.
  TourPosition atFraction(double fraction) =>
      at(fraction.clamp(0.0, 1.0) * totalMeters);

  /// Fahrtrichtung über ein kurzes Stück vor und nach der Stelle gemittelt,
  /// damit das Fahrzeug bei dicht liegenden Punkten nicht zittert.
  double _bearingAt(double d) {
    final look = (totalMeters * 0.002).clamp(30.0, 3000.0);
    var a = _pointAt(d - look);
    var b = _pointAt(d + look);
    if (a == b) {
      a = _points[math.max(0, _edgeAt(d))];
      b = _points[math.min(_points.length - 1, _edgeAt(d) + 1)];
    }
    if (a == b) return 90;
    final deg = _haversine.bearing(a, b);
    return (deg + 360) % 360;
  }

  /// Der gefahrene Teil bis [meters], je Abschnitt; zum Zeichnen auf höchstens
  /// [maxPointsPerLeg] Punkte ausgedünnt.
  List<TourTrail> trailUpTo(double meters, {int maxPointsPerLeg = 3000}) {
    final d = meters.clamp(0.0, totalMeters);
    if (d <= 0) return const [];
    final current = _pointAt(d);
    final lastIndex = d >= totalMeters ? _points.length - 1 : _edgeAt(d);
    final out = <TourTrail>[];
    for (var k = 0; k < legs.length; k++) {
      final (from, to) = _legRanges[k];
      if (from > lastIndex) break;
      final end = math.min(to, lastIndex);
      final step = math.max(1, ((to - from + 1) / maxPointsPerLeg).ceil());
      final pts = <LatLng>[
        for (var i = from; i <= end; i += step) _points[i],
      ];
      if (pts.last != _points[end]) pts.add(_points[end]);
      if (lastIndex < to && pts.last != current) pts.add(current);
      if (pts.length >= 2) out.add(TourTrail(pts, legs[k].kind));
    }
    return out;
  }
}

/// Dauer der Animation bei Tempo 1×: wächst mit der Strecke, aber nur
/// logarithmisch. Ruhiges Grundtempo (20 % langsamer als der erste Entwurf):
/// Lambach–Linz etwa 14 s, 900 km etwa 28 s, 2.700 km etwa 34 s; nie unter
/// 7,5 und nie über 36 Sekunden, damit lange Touren nicht zäh werden.
/// 2× und 4× teilen diese Dauer.
Duration tourAnimationDuration(double meters) {
  const calm = 1.25; // Faktor gegenüber dem ersten Entwurf (Tempo × 0,8)
  final km = math.max(0.0, meters / 1000);
  final seconds =
      ((4 + 9.5 * math.log(1 + km / 10) / math.ln10) * calm).clamp(7.5, 36.0);
  return Duration(milliseconds: (seconds * 1000).round());
}

/// Zoomstufe, mit der die Kamera dem Fahrzeug folgt: kurze Touren nah,
/// lange internationale Touren als Region, damit die Bewegung ruhig bleibt.
double tourFollowZoom(double meters) {
  final km = math.max(1.0, meters / 1000);
  return (13 - 0.9 * math.log(km / 10) / math.ln2).clamp(7.0, 12.5);
}

/// Grenzen für den manuellen Zoom: weit genug für eine Europa-Tour, nah genug
/// für Ortsdurchfahrten – weder Weltkarte noch einzelne Häuser.
const double tourMinZoom = 4;
const double tourMaxZoom = 15;

/// Nächste Zoomstufe nach einem Tipp auf − oder +, innerhalb der Grenzen.
double tourZoomStep(double current, double delta) =>
    (current + delta).clamp(tourMinZoom, tourMaxZoom);

/// Sanfter Anlauf und sanftes Auslaufen: über die ersten und letzten 6 % der
/// Zeit beschleunigt bzw. bremst das Fahrzeug, dazwischen fährt es gleichmäßig.
double tourEase(double progress) {
  const r = 0.06;
  const vmax = 1 / (1 - r);
  final p = progress.clamp(0.0, 1.0);
  if (p < r) return vmax * p * p / (2 * r);
  if (p > 1 - r) return 1 - vmax * (1 - p) * (1 - p) / (2 * r);
  return vmax * (p - r / 2);
}

/// Wie das Fahrzeug-Symbol zu drehen ist. Das Symbol zeigt nach rechts
/// (Osten); damit es nie kopfüber fährt, wird es für Fahrten nach Westen
/// gespiegelt und nur noch höchstens 90° geneigt.
({double radians, bool mirrored}) truckPose(double bearing) {
  var a = (bearing - 90) % 360; // Bildschirmwinkel ab Osten, im Uhrzeigersinn
  if (a > 180) a -= 360;
  if (a < -180) a += 360;
  if (a > 90 || a < -90) {
    var m = a - 180;
    if (m < -180) m += 360;
    return (radians: m * math.pi / 180, mirrored: true);
  }
  return (radians: a * math.pi / 180, mirrored: false);
}
