import 'dart:math' as math;

import 'truck_projection.dart';

/// EXPERIMENT – neutrale RoPax-Fähre v1 als einfache 2.5D-Geometrie.
///
/// Keine Reederei, kein Logo, keine reale Schiffsklasse: Rumpf mit spitzem
/// Bug und breitem Heck (Heckklappe), weißer Aufbau über fast die ganze
/// Länge, Brücke mit Nocken vorn, Schornstein achtern. Damit sind Bug und
/// Heck aus jeder Kamerarichtung klar zu unterscheiden.
///
/// Koordinaten wie beim LKW ([TruckProjection]): f nach vorn (Bug), r nach
/// rechts (Steuerbord), z nach oben; Meter, Ursprung Mitte an der Wasserlinie.
class FerryShipModel {
  const FerryShipModel();

  /// Länge über alles und halbe Breite.
  static const double length = 180;
  static const double halfBeam = 14;

  /// Freibord: Rumpf über der Wasserlinie; darüber beginnt der Aufbau.
  static const double freeboard = 9;

  /// Höhe, ab der der Rumpf weiß ist (darunter dunkel).
  static const double hullBand = 6;

  /// Länge der Bugverjüngung.
  static const double bowLength = 36;

  static double get sternF => -length / 2;
  static double get bowF => length / 2;

  /// Grundriss des Rumpfs (Deck und Wasserlinie gleich), im Uhrzeigersinn
  /// von oben: Heck links → Bug → Heck rechts.
  static List<(double f, double r)> hullOutline() {
    final out = <(double, double)>[(sternF, -halfBeam)];
    final shoulder = bowF - bowLength;
    out.add((shoulder, -halfBeam));
    // Bug: weich zugespitzt.
    const n = 6;
    for (var i = 1; i < n; i++) {
      final t = i / n;
      out.add((shoulder + bowLength * t, -halfBeam * math.cos(t * math.pi / 2)));
    }
    out.add((bowF, 0));
    for (var i = n - 1; i >= 1; i--) {
      final t = i / n;
      out.add((shoulder + bowLength * t, halfBeam * math.cos(t * math.pi / 2)));
    }
    out.add((shoulder, halfBeam));
    out.add((sternF, halfBeam));
    return out;
  }

  /// Aufbauten als Quader (gleiche Zeichenlogik wie beim LKW).
  static const List<TruckBox> superstructure = [
    TruckBox(name: 'deckhouse', fromF: -66, toF: 40, halfWidth: 12.5, fromZ: freeboard, toZ: 24),
    TruckBox(name: 'upper', fromF: -44, toF: 30, halfWidth: 10.5, fromZ: 24, toZ: 29),
    TruckBox(name: 'bridge', fromF: 30, toF: 42, halfWidth: 14.5, fromZ: 24, toZ: 31),
    TruckBox(name: 'funnel', fromF: -52, toF: -41, halfWidth: 3.6, fromZ: 29, toZ: 40),
    TruckBox(name: 'mast', fromF: 36, toF: 37.4, halfWidth: 0.7, fromZ: 31, toZ: 38),
  ];

  /// Positionslichter (Welt im Schiffssystem): Backbord rot links an der
  /// Brückennock, Steuerbord grün rechts, Topplicht weiß am Mast, Hecklicht.
  static const portLight = (f: 41.0, r: -14.6, z: 30.0);
  static const starboardLight = (f: 41.0, r: 14.6, z: 30.0);
  static const mastheadLight = (f: 36.7, r: 0.0, z: 38.5);
  static const sternLight = (f: -90.0, r: 0.0, z: 9.5);
}

/// Länge des (schlichten) Kielwassers hinter dem Heck.
const double shipWakeLength = 70;

/// Eine Seitenfläche des Rumpfs zwischen zwei Grundrisspunkten, projiziert.
class HullFace {
  const HullFace(this.corners, this.depth, this.shade, {required this.stern, required this.upper});
  final List<ScreenPoint> corners;
  final double depth;
  final double shade;

  /// Heckspiegel (Fläche quer am Heck).
  final bool stern;

  /// Weißes Oberteil (true) oder dunkles Unterteil des Rumpfs.
  final bool upper;
}

/// Sichtbare Rumpfseiten (unten dunkel, oben weiß), nach Tiefe sortiert.
List<HullFace> visibleHullFaces(TruckProjection proj) {
  const light = Vec3(-0.35, -0.25, 0.9);
  final outline = FerryShipModel.hullOutline();
  final out = <HullFace>[];
  for (var i = 0; i < outline.length; i++) {
    final (f0, r0) = outline[i];
    final (f1, r1) = outline[(i + 1) % outline.length];
    // Außennormale im Grundriss (Umlauf im Uhrzeigersinn von oben, r rechts).
    final df = f1 - f0, dr = r1 - r0;
    final l = math.sqrt(df * df + dr * dr);
    if (l < 1e-9) continue;
    final nf = dr / l, nr = -df / l;
    final normal = proj.forward * nf + proj.right * nr;
    if (normal.dot(proj.view) >= -1e-6) continue;
    final shade = (0.62 + 0.38 * normal.dot(light).clamp(-1.0, 1.0)).clamp(0.0, 1.0);
    final stern = (f0 - FerryShipModel.sternF).abs() < 1e-6 && (f1 - FerryShipModel.sternF).abs() < 1e-6;
    for (final (z0, z1, upper) in [
      (0.0, FerryShipModel.hullBand, false),
      (FerryShipModel.hullBand, FerryShipModel.freeboard, true),
    ]) {
      // Ecken in Leserichtung von außen: oben-links, oben-rechts, unten-rechts, unten-links.
      final c = [
        proj.project(proj.world(f1, r1, z1)),
        proj.project(proj.world(f0, r0, z1)),
        proj.project(proj.world(f0, r0, z0)),
        proj.project(proj.world(f1, r1, z0)),
      ];
      out.add(HullFace(c, c.fold(0.0, (a, p) => a + p.depth) / 4, shade, stern: stern, upper: upper));
    }
  }
  out.sort((a, b) => b.depth.compareTo(a.depth));
  return out;
}

/// Größte Ausdehnung des projizierten Schiffs (Meter) vom Ursprung – für die
/// Bildgröße und um sicherzustellen, dass nichts abgeschnitten wird.
double shipScreenExtent(TruckProjection proj) {
  var ext = 0.0;
  void see(double f, double r, double z) {
    final p = proj.project(proj.world(f, r, z));
    ext = math.max(ext, math.max(p.x.abs(), p.y.abs()));
  }

  for (final (f, r) in FerryShipModel.hullOutline()) {
    see(f, r, 0);
    see(f, r, FerryShipModel.freeboard);
  }
  // Kielwasser hinter dem Heck gehört mit ins Bild.
  for (final r in [-20.0, 20.0]) {
    see(FerryShipModel.sternF - shipWakeLength, r, 0);
  }
  for (final b in FerryShipModel.superstructure) {
    for (final f in [b.fromF, b.toF]) {
      for (final r in [-b.halfWidth, b.halfWidth]) {
        see(f, r, b.toZ);
      }
    }
  }
  return ext;
}
