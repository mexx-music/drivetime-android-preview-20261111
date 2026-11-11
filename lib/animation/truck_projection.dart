import 'dart:math' as math;

/// Leichte 2.5D-Darstellung eines Sattelzugs – reine Geometrie, ohne Flutter.
///
/// Der Zug besteht aus wenigen Quadern (Zugmaschine, Auflieger, Fahrwerk).
/// Er wird orthografisch mit genau der Neigung der Karte projiziert, damit er
/// zur Kamera passt (nicht umgekehrt). Gezeichnet wird ein Bild je Gierwinkel
/// relativ zur Blickrichtung; die Kamera selbst bleibt unverändert.
///
/// Koordinaten: x nach rechts, y vom Betrachter weg (in die Karte hinein),
/// z nach oben; Meter. Ursprung = Bodenmitte des Zugs.
class Vec3 {
  const Vec3(this.x, this.y, this.z);
  final double x, y, z;
  Vec3 operator +(Vec3 o) => Vec3(x + o.x, y + o.y, z + o.z);
  Vec3 operator -(Vec3 o) => Vec3(x - o.x, y - o.y, z - o.z);
  Vec3 operator *(double s) => Vec3(x * s, y * s, z * s);
  double dot(Vec3 o) => x * o.x + y * o.y + z * o.z;
}

/// Punkt auf dem Bild: x nach rechts, y nach unten (Bildschirm), plus Tiefe.
class ScreenPoint {
  const ScreenPoint(this.x, this.y, this.depth);
  final double x, y, depth;
}

/// Welche Fläche eines Quaders.
enum FaceSide { front, back, left, right, top, bottom }

/// Ein Quader im Fahrzeug-Koordinatensystem (vorne = +f).
class TruckBox {
  const TruckBox({
    required this.name,
    required this.fromF,
    required this.toF,
    required this.halfWidth,
    required this.fromZ,
    required this.toZ,
  });

  final String name;
  final double fromF, toF, halfWidth, fromZ, toZ;
}

/// Eine sichtbare, projizierte Fläche.
class ProjectedFace {
  const ProjectedFace({
    required this.box,
    required this.side,
    required this.corners,
    required this.depth,
    required this.shade,
  });

  final TruckBox box;
  final FaceSide side;

  /// Vier Ecken im Bild, in Leserichtung der Fläche: oben-links, oben-rechts,
  /// unten-rechts, unten-links – so, wie ein Betrachter außen sie sieht.
  final List<ScreenPoint> corners;
  final double depth;

  /// 0..1 – Helligkeit nach Ausrichtung zum Licht (oben/links etwas heller).
  final double shade;
}

/// Projektion mit Kartenneigung [pitchDeg] (0 = senkrecht von oben) und
/// Fahrzeug-Gierwinkel [yawDeg] relativ zur Blickrichtung (0 = fährt vom
/// Betrachter weg, positiv = nach rechts gedreht – dann zeigt es dem
/// Betrachter seine RECHTE Seite, negativ die linke).
class TruckProjection {
  TruckProjection({required this.pitchDeg, required this.yawDeg, this.origin = const Vec3(0, 0, 0)})
      : _p = pitchDeg * math.pi / 180,
        _y = yawDeg * math.pi / 180;

  final double pitchDeg;
  final double yawDeg;

  /// Lage des Körper-Ursprungs in der Welt (z. B. Sattelpunkt).
  final Vec3 origin;
  final double _p;
  final double _y;

  /// Fahrtrichtung, rechte Seite und oben in Weltkoordinaten.
  Vec3 get forward => Vec3(math.sin(_y), math.cos(_y), 0);
  Vec3 get right => Vec3(math.cos(_y), -math.sin(_y), 0);
  static const up = Vec3(0, 0, 1);

  /// Blickrichtung der Kamera (in die Szene hinein, nach vorn und unten).
  Vec3 get view => Vec3(0, math.sin(_p), -math.cos(_p));

  Vec3 world(double f, double r, double z) => origin + forward * f + right * r + up * z;

  /// Orthografisch: Bild-x = Welt-x; Bild-y (nach unten) aus Tiefe und Höhe.
  ScreenPoint project(Vec3 w) => ScreenPoint(
        w.x,
        -(w.y * math.cos(_p) + w.z * math.sin(_p)),
        w.y * math.sin(_p) - w.z * math.cos(_p),
      );

  Vec3 normalOf(FaceSide s) => switch (s) {
        FaceSide.front => forward,
        FaceSide.back => forward * -1,
        FaceSide.right => right,
        FaceSide.left => right * -1,
        FaceSide.top => up,
        FaceSide.bottom => up * -1,
      };

  /// Zeigt die Fläche zum Betrachter?
  bool facesViewer(FaceSide s) => normalOf(s).dot(view) < -1e-6;

  /// Ecken einer Fläche in Leserichtung von außen (siehe [ProjectedFace]).
  List<Vec3> faceCorners(TruckBox b, FaceSide s) {
    final w = b.halfWidth;
    Vec3 p(double f, double r, double z) => world(f, r, z);
    return switch (s) {
      // Linke Seite von außen: vorn links im Bild, Schrift läuft nach hinten.
      FaceSide.left => [p(b.toF, -w, b.toZ), p(b.fromF, -w, b.toZ), p(b.fromF, -w, b.fromZ), p(b.toF, -w, b.fromZ)],
      // Rechte Seite von außen: hinten links im Bild, Schrift läuft nach vorn.
      FaceSide.right => [p(b.fromF, w, b.toZ), p(b.toF, w, b.toZ), p(b.toF, w, b.fromZ), p(b.fromF, w, b.fromZ)],
      FaceSide.back => [p(b.fromF, -w, b.toZ), p(b.fromF, w, b.toZ), p(b.fromF, w, b.fromZ), p(b.fromF, -w, b.fromZ)],
      FaceSide.front => [p(b.toF, w, b.toZ), p(b.toF, -w, b.toZ), p(b.toF, -w, b.fromZ), p(b.toF, w, b.fromZ)],
      FaceSide.top => [p(b.toF, -w, b.toZ), p(b.toF, w, b.toZ), p(b.fromF, w, b.toZ), p(b.fromF, -w, b.toZ)],
      FaceSide.bottom => [p(b.fromF, -w, b.fromZ), p(b.fromF, w, b.fromZ), p(b.toF, w, b.fromZ), p(b.toF, -w, b.fromZ)],
    };
  }

  /// Alle sichtbaren Flächen, von hinten nach vorn sortiert (Malerverfahren).
  List<ProjectedFace> visibleFaces(List<TruckBox> boxes) {
    const light = Vec3(-0.35, -0.25, 0.9); // von oben links
    final out = <ProjectedFace>[];
    for (final b in boxes) {
      for (final s in FaceSide.values) {
        if (!facesViewer(s)) continue;
        final corners = [for (final c in faceCorners(b, s)) project(c)];
        final depth = corners.fold(0.0, (a, c) => a + c.depth) / 4;
        final n = normalOf(s);
        final shade = (0.62 + 0.38 * n.dot(light).clamp(-1.0, 1.0)).clamp(0.0, 1.0);
        out.add(ProjectedFace(box: b, side: s, corners: corners, depth: depth, shade: shade));
      }
    }
    out.sort((a, b) => b.depth.compareTo(a.depth));
    return out;
  }

  /// Richtung der Schriftzeile einer Fläche im Bild (oben-links → oben-rechts).
  /// Positive x-Komponente bzw. positive Orientierung heißt: nicht gespiegelt.
  static double orientation(List<ScreenPoint> c) {
    final ax = c[1].x - c[0].x, ay = c[1].y - c[0].y; // Schriftrichtung
    final bx = c[3].x - c[0].x, by = c[3].y - c[0].y; // nach unten
    return ax * by - ay * bx; // > 0: Bildkoordinaten (y nach unten) rechtshändig
  }
}

// ------------------------------------------------ gekoppelter Sattelzug

/// Zugmaschine relativ zum Sattelpunkt (Ursprung), Fahrtrichtung +f.
const List<TruckBox> tractorBoxes = [
  TruckBox(name: 'chassis', fromF: -0.9, toF: 4.4, halfWidth: 1.1, fromZ: 0.0, toZ: 1.0),
  TruckBox(name: 'cab', fromF: 2.0, toF: 4.4, halfWidth: 1.25, fromZ: 0.8, toZ: 3.7),
];

/// Auflieger relativ zum Sattelpunkt (Königszapfen 1,2 m hinter der Stirn).
const List<TruckBox> trailerBoxes = [
  TruckBox(name: 'trailer-gear', fromF: -12.0, toF: -8.6, halfWidth: 1.1, fromZ: 0.0, toZ: 1.1),
  TruckBox(name: 'trailer', fromF: -12.4, toF: 1.2, halfWidth: 1.27, fromZ: 1.1, toZ: 4.0),
];

/// Sichtbare Flächen beider Körper, gemeinsam nach Tiefe sortiert. Beide
/// drehen um den Sattelpunkt: Zugmaschine mit [tractorYaw], Auflieger mit
/// [tractorYaw] + [knick].
List<ProjectedFace> articulatedFaces({
  required double tractorYaw,
  required double knick,
  required double pitchDeg,
  List<TruckBox> extraTrailerBoxes = const [],
}) {
  final tractor = TruckProjection(pitchDeg: pitchDeg, yawDeg: tractorYaw);
  final trailer = TruckProjection(pitchDeg: pitchDeg, yawDeg: tractorYaw + knick);
  return [
    ...tractor.visibleFaces(tractorBoxes),
    ...trailer.visibleFaces([...trailerBoxes, ...extraTrailerBoxes]),
  ]..sort((a, b) => b.depth.compareTo(a.depth));
}

/// Maße eines Standard-Sattelzugs (Meter), Ursprung Bodenmitte des Zugs.
const List<TruckBox> standardTruck = [
  TruckBox(name: 'chassis', fromF: -8.0, toF: 8.2, halfWidth: 1.05, fromZ: 0.0, toZ: 1.1),
  TruckBox(name: 'trailer', fromF: -8.2, toF: 5.4, halfWidth: 1.27, fromZ: 1.1, toZ: 4.0),
  TruckBox(name: 'cab', fromF: 5.8, toF: 8.2, halfWidth: 1.25, fromZ: 0.7, toZ: 3.7),
];

// -------------------------------------------------- Seite und Gierwinkel

/// Welche Fahrzeugseite die 3/4-Ansicht zeigt.
enum TruckSide { left, right }

/// Wählt die Seite mit Hysterese: erst bei deutlichem Winkel ([threshold]
/// Grad) wird gewechselt, im Band dazwischen bleibt die bisherige Seite.
/// [relativeDeg] > 0: Fahrzeug nach rechts gegenüber der Blickrichtung
/// gedreht – dann sieht man natürlicherweise seine rechte Seite.
TruckSide chooseSide(double relativeDeg, TruckSide current, {double threshold = 8}) {
  if (relativeDeg > threshold) return TruckSide.right;
  if (relativeDeg < -threshold) return TruckSide.left;
  return current;
}

/// Automatische Seitenwahl mit Hysterese UND Mindesthaltezeit: nach einem
/// Wechsel bleibt die Seite mindestens [minHold] stehen. Gemessen auf
/// İpsala → Odense: Schwelle 8° ohne Haltezeit 10 Wechsel, 15° / 8 s noch 4.
class SideChooser {
  SideChooser({this.threshold = 15, this.minHold = const Duration(seconds: 8), this.side = TruckSide.right});

  final double threshold;
  final Duration minHold;
  TruckSide side;
  Duration _since = const Duration(days: 1);
  int switches = 0;

  TruckSide update(double relativeDeg, Duration dt) {
    _since += dt;
    final next = chooseSide(relativeDeg, side, threshold: threshold);
    if (next != side && _since >= minHold) {
      side = next;
      switches++;
      _since = Duration.zero;
    }
    return side;
  }
}

/// Gierwinkel-Zuschlag, der die gewünschte Seite zeigt: rechts +, links −.
double biasFor(TruckSide side, double bias) => side == TruckSide.right ? bias : -bias;

/// Weicher Übergang des Seitenwinkels: [current] läuft mit Zeitkonstante
/// [tau] auf [target] zu – kein Springen beim Seitenwechsel.
double easeBias(double current, double target, Duration dt, {double tau = 0.7}) {
  final s = dt.inMicroseconds / 1e6;
  if (s <= 0) return current;
  return current + (target - current) * (1 - math.exp(-s / tau));
}

/// Bild-Nummer für einen Gierwinkel in [step]-Grad-Schritten, mit Hysterese
/// gegen Flackern an der Grenze zweier Bilder.
int frameFor(double yawDeg, int currentFrame, {double step = 4, double hysteresis = 0.35}) {
  var y = yawDeg % 360;
  if (y > 180) y -= 360;
  final currentYaw = currentFrame * step;
  var diff = (y - currentYaw) % 360;
  if (diff > 180) diff -= 360;
  if (diff.abs() <= step * (0.5 + hysteresis)) return currentFrame;
  return (y / step).round();
}
