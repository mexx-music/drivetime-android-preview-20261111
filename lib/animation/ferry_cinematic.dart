import 'dart:math' as math;

import 'package:latlong2/latlong.dart';

import 'cinematic_camera.dart';
import 'tour_path.dart';

/// EXPERIMENT – Fähren-Cinematic v1: reine Rechnung, ohne Flutter.
///
/// Grundlage sind ausschließlich die Fährabschnitte, die [TourPath] schon
/// kennt ([TourLegKind.ferry], aus der Kartenplanung der Berechnung). Es wird
/// keine Fährroute berechnet und kein Dienst gefragt; das Schiff folgt genau
/// der Geometrie dieses Abschnitts.

/// Eine Überfahrt auf der Linie, in Streckenmetern ab Start.
class FerryCrossing {
  const FerryCrossing(this.startMeters, this.endMeters, {this.label});

  final double startMeters;
  final double endMeters;
  final String? label;

  double get length => endMeters - startMeters;
}

/// Alle Überfahrten der Tour in Fahrtreihenfolge (leer: Tour ohne Fähre).
List<FerryCrossing> ferryCrossings(TourPath path) => [
      for (final s in path.legSpans)
        if (s.kind == TourLegKind.ferry && s.to > s.from) FerryCrossing(s.from, s.to, label: s.label),
    ];

double _smooth(double t) {
  final x = t.clamp(0.0, 1.0);
  return x * x * (3 - 2 * x);
}

// ------------------------------------------------------- LKW ↔ Fähre

/// Welches Fahrzeug an einer Stelle zu sehen ist.
///
/// Filmisch abstrahiert, ohne Auffahren: Der LKW fährt bis zum Hafen und
/// blendet dort aus, während die Fähre am Kai einblendet und ablegt. Am
/// Zielhafen umgekehrt. Nur eine Funktion der Streckenposition – Bild für
/// Bild reproduzierbar, bei jedem Tempo gleich.
class VehicleMix {
  const VehicleMix({required this.ship, required this.truckMeters, required this.shipMeters, this.crossing});

  /// 0 = nur LKW, 1 = nur Fähre, dazwischen Überblendung.
  final double ship;
  double get truck => 1 - ship;

  /// Wo der LKW steht (am Hafen angehalten, solange die Fähre fährt).
  final double truckMeters;

  /// Wo die Fähre ist (vor dem Ablegen am Abfahrts-, danach am Zielhafen).
  final double shipMeters;

  /// Die betroffene Überfahrt, sonst null.
  final FerryCrossing? crossing;
}

/// Länge der Überblendung je Seite in Streckenmetern: 2,5 % der Tour (bei
/// 1× gut eine Sekunde), höchstens ein Fünftel der Überfahrt.
double ferryFadeMeters(TourPath path, FerryCrossing c) =>
    math.min(path.totalMeters * 0.025, c.length * 0.2);

VehicleMix vehicleAt(TourPath path, List<FerryCrossing> crossings, double meters) {
  for (final c in crossings) {
    final f = ferryFadeMeters(path, c);
    if (meters < c.startMeters - f) break;
    if (meters > c.endMeters + f) continue;
    final double ship;
    if (meters < c.startMeters + f) {
      ship = _smooth((meters - (c.startMeters - f)) / (2 * f));
    } else if (meters > c.endMeters - f) {
      ship = 1 - _smooth((meters - (c.endMeters - f)) / (2 * f));
    } else {
      ship = 1;
    }
    final departing = meters < (c.startMeters + c.endMeters) / 2;
    return VehicleMix(
      ship: ship,
      truckMeters: departing ? math.min(meters, c.startMeters) : math.max(meters, c.endMeters),
      shipMeters: meters.clamp(c.startMeters, c.endMeters),
      crossing: c,
    );
  }
  return VehicleMix(ship: 0, truckMeters: meters, shipMeters: meters);
}

/// Kurs der Fähre: entlang der Fährgeometrie selbst (nie über die Straße
/// davor oder danach gemittelt) – am Kai schon in Ablegerichtung.
double shipHeading(TourPath path, FerryCrossing c, double meters) {
  final span = math.max(500.0, math.min(c.length * 0.05, path.totalMeters * 0.002));
  final m = meters.clamp(c.startMeters, c.endMeters);
  var a = path.at(math.max(c.startMeters, m - span)).point;
  var b = path.at(math.min(c.endMeters, m + span)).point;
  if (a == b) {
    a = path.at(c.startMeters).point;
    b = path.at(c.endMeters).point;
  }
  return (const Distance(calculator: Haversine()).bearing(a, b) + 360) % 360;
}

// ------------------------------------------------------- Größe

/// Länge des Schiffs auf dem Bildschirm im Verhältnis zum LKW (Sattelzug
/// ≈ 16,8 m) bei Folge-Zoom – gut sichtbar, aber zurückhaltend. Näher kommt
/// es nur über die Kamera (Zoom), nie durch Vergrößern.
const double shipLengthInTrucks = 2.2;
const double truckLengthMeters = 16.8;

/// Bildschirmpunkte je Schiffsmeter, abgeleitet aus denen des LKW.
double shipPointsPerMeter(double truckPointsPerMeter, double shipLength) =>
    truckPointsPerMeter * shipLengthInTrucks * truckLengthMeters / shipLength;

// ------------------------------------------------------- Kameraregie

/// Namen der Fähren-Shots (Anzeige, Tests).
const shotToPort = 'TO PORT';
const shotFerryFollow = 'FERRY FOLLOW';
const shotFerrySide = 'FERRY SIDE 3/4';
const shotHighDrone = 'HIGH DRONE';
const shotToDestPort = 'TO DEST PORT';

const _follow = 'FOLLOW';

/// Kamerawerte der Fähren-Shots (Bahnwinkel relativ, wie [ShotKey]).
const _ferryFollow = (orbit: 0.0, pitch: 46.0, zoom: 0.35, ahead: 0.5);
const _port = (orbit: 0.0, pitch: 30.0, zoom: -0.5, ahead: 1.8);
const _side = (orbit: 60.0, pitch: 52.0, zoom: 0.85, ahead: 0.0);
const _high = (orbit: 20.0, pitch: 24.0, zoom: -0.6, ahead: 0.3);

/// Wie viele ruhige Perspektivwechsel eine Überfahrt bekommt, nach ihrer
/// Dauer auf See in Animationssekunden: kurz keinen, mittel einen
/// (seitlich), lang zwei (seitlich, dann hoch).
int ferrySeaShots(double seaSeconds) => seaSeconds >= 9 ? 2 : (seaSeconds >= 4.5 ? 1 : 0);

/// Regie mit Fähren: [base] (Straßen-Regie) bleibt, wo keine Fähre ist,
/// unverändert. Um jede Überfahrt herum werden Straßenmanöver, die sich mit
/// ihr überschneiden würden, ganz weggelassen und durch den Fährablauf
/// ersetzt:
///
///   FOLLOW → TO PORT (höher, voraus zum Hafen) → FERRY FOLLOW
///   → [FERRY SIDE 3/4] → [HIGH DRONE] → FERRY FOLLOW
///   → TO DEST PORT (höher, voraus zum Zielhafen) → FOLLOW
///
/// Rein nach Streckenanteil – gleiche Tour, gleiche Regie, bei jedem Tempo.
CinematicPlan ferryAwarePlan(CinematicPlan base, TourPath path, Duration drive) {
  final crossings = ferryCrossings(path);
  final total = path.totalMeters;
  if (crossings.isEmpty || total <= 0) return base;
  final secs = math.max(1.0, drive.inMilliseconds / 1000);
  double sec(double s) => s / secs; // Sekunden → Streckenanteil

  var keys = List<ShotKey>.of(base.keys);
  var lo = 0.0;
  for (var i = 0; i < crossings.length; i++) {
    final c = crossings[i];
    final a = c.startMeters / total, b = c.endMeters / total;
    final hi = i + 1 < crossings.length ? crossings[i + 1].startMeters / total : 1.0;
    final len = b - a;
    final tIn = math.min(sec(2.4), (a - lo) * 0.8);
    final tOut = math.min(sec(2.4), (hi - b) * 0.45);
    final settleIn = math.min(sec(1.2), len * 0.2);
    final settleOut = math.min(sec(1.6), len * 0.25);
    final pre = a - tIn, post = b + tOut;

    keys = _dropManoeuvres(keys, pre - 0.01, post + 0.01);
    final baseOrbit = (CinematicPlan(keys).at(pre).orbit / 360).round() * 360.0;
    keys.removeWhere((k) => k.p >= pre && k.p <= post);

    ShotKey key(double p, String shot, ({double orbit, double pitch, double zoom, double ahead}) v) =>
        ShotKey(p, shot, orbit: baseOrbit + v.orbit, pitch: v.pitch, zoom: v.zoom, ahead: v.ahead);

    final s0 = a + settleIn, s1 = b - settleOut;
    final shots = ferrySeaShots((s1 - s0) * secs);
    final sea = <ShotKey>[
      key(s0, shotFerryFollow, _ferryFollow),
      if (shots == 1) ...[
        key(s0 + (s1 - s0) * 0.2, shotFerryFollow, _ferryFollow),
        key(s0 + (s1 - s0) * 0.45, shotFerrySide, _side),
        key(s0 + (s1 - s0) * 0.7, shotFerrySide, _side),
      ],
      if (shots == 2) ...[
        key(s0 + (s1 - s0) * 0.12, shotFerryFollow, _ferryFollow),
        key(s0 + (s1 - s0) * 0.3, shotFerrySide, _side),
        key(s0 + (s1 - s0) * 0.45, shotFerrySide, _side),
        key(s0 + (s1 - s0) * 0.62, shotHighDrone, _high),
        key(s0 + (s1 - s0) * 0.78, shotHighDrone, _high),
      ],
      key(s1, shotFerryFollow, _ferryFollow),
    ];
    keys.addAll([
      ShotKey(pre, _follow, orbit: baseOrbit),
      key(a - tIn * 0.3, shotToPort, _port),
      ...sea,
      key(b, shotToDestPort, _port),
      if (post < 1) ShotKey(post, _follow, orbit: baseOrbit),
    ]);
    keys.sort((x, y) => x.p.compareTo(y.p));
    lo = post;
  }
  // Anfang und Ende der Regie bleiben definiert.
  if (keys.first.p > 0) keys.insert(0, ShotKey(0, _follow, orbit: keys.first.orbit));
  if (keys.last.p < 1) {
    final l = keys.last;
    keys.add(ShotKey(1, l.shot == shotToDestPort ? _follow : l.shot,
        orbit: l.orbit, pitch: l.pitch, zoom: l.zoom, ahead: l.ahead));
  }
  return CinematicPlan(keys);
}

/// Lässt Straßenmanöver (zusammenhängende Nicht-FOLLOW-Stützpunkte samt
/// ihrer FOLLOW-Ränder), die [from]..[to] berühren, ganz weg. Spätere
/// Bahnwinkel werden um die ausgelassene Drehung verschoben, damit die
/// Kamera keine Extrarunde fliegt.
List<ShotKey> _dropManoeuvres(List<ShotKey> keys, double from, double to) {
  final out = <ShotKey>[];
  var shift = 0.0;
  var i = 0;
  while (i < keys.length) {
    final k = keys[i];
    if (k.shot != _follow && i > 0) {
      var j = i;
      while (j < keys.length && keys[j].shot != _follow) {
        j++;
      }
      final prev = keys[i - 1];
      final next = j < keys.length ? keys[j] : keys.last;
      if (prev.p <= to && next.p >= from) {
        shift += next.orbit - prev.orbit;
        i = j;
        continue;
      }
    }
    out.add(shift == 0
        ? k
        : ShotKey(k.p, k.shot, orbit: k.orbit - shift, pitch: k.pitch, zoom: k.zoom, ahead: k.ahead));
    i++;
  }
  return out;
}

/// Die Cinematic-Regie einer Tour (Straßen-Regie plus Fähren) – dieselbe für
/// Kamera und Tempo. Geplant nach der bisherigen Fahrdauer, damit Anzahl und
/// Timing der Kamerafahrten gleich bleiben.
CinematicPlan cinematicPlanFor(TourPath path, {bool demo = false}) {
  final d = tourAnimationDuration(path.totalMeters);
  return ferryAwarePlan(demo ? CinematicPlan.demo() : CinematicPlan.standard(d), path, d);
}
