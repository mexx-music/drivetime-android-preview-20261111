import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:driverroute_eta/animation/articulation.dart';
import 'package:driverroute_eta/animation/cinematic_camera.dart';
import 'package:driverroute_eta/animation/daylight.dart';
import 'package:driverroute_eta/animation/tour_path.dart';
import 'package:driverroute_eta/ui/truck_sprites.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';

/// Das Lichtbild als Deckkraft- und Farbraster (aus dem PNG, wie in der Karte).
class _Cone {
  _Cone(this.w, this.h, this.data, this.bytes);
  final int w, h;
  final ByteData data;
  final Uint8List bytes;

  double get pxPerMeter => h / headlightConeMeters;
  int alpha(int x, int y) => data.getUint8((y * w + x) * 4 + 3);
  int channel(int x, int y, int c) => data.getUint8((y * w + x) * 4 + c);

  /// Bildzeile [d] Meter vor der Front.
  int row(double d) => (h - 1 - d * pxPerMeter).round().clamp(0, h - 1);
  List<int> line(double d) => [for (var x = 0; x < w; x++) alpha(x, row(d))];
  int rowMax(double d) => line(d).reduce(math.max);

  /// Weitester Abstand, bei dem die Zeile noch [f] × Spitzenhelligkeit hat.
  double reach(double f) {
    final peak = [for (var y = 0; y < h; y++) rowMax((h - 1 - y) / pxPerMeter)].reduce(math.max);
    for (var y = 0; y < h; y++) {
      final d = (h - 1 - y) / pxPerMeter;
      if (rowMax(d) >= f * peak) return d;
    }
    return 0;
  }
}

Future<_Cone> _cone() async {
  final bytes = await headlightConePng();
  final img = (await (await ui.instantiateImageCodec(bytes)).getNextFrame()).image;
  final data = (await img.toByteData(format: ui.ImageByteFormat.rawStraightRgba))!;
  return _Cone(img.width, img.height, data, bytes);
}

/// Erhebungen einer Zeile (über [min] Deckkraft; Plateaus zählen einmal),
/// als Meter seitlich der Mitte.
List<double> _peaks(_Cone c, double d, {int min = 20}) {
  final l = c.line(d);
  final out = <double>[];
  var rising = false;
  var start = 0;
  for (var x = 1; x < c.w; x++) {
    if (l[x] > l[x - 1]) {
      rising = true;
      start = x;
    } else if (l[x] < l[x - 1]) {
      if (rising && l[x - 1] >= min) out.add(((start + x - 1) / 2 + 0.5 - c.w / 2) / c.pxPerMeter);
      rising = false;
    }
  }
  return out;
}

/// Altes Lichtbild (bis 583d14b) zum Vergleich: 16 Fahrzeugmeter lang,
/// Spitze ≈ 2 m vor der Front, halbe Helligkeit bis ≈ 11 m, 10 % bis ≈ 13,7 m.
const _oldHalfReach = 11.0, _oldTenthReach = 13.7;

void main() {
  late _Cone cone;
  setUpAll(() async => cone = await _cone());

  group('Abblendlicht', () {
    test('zwei getrennte Lichtzentren vorn, weiter vorn ein Feld', () {
      final near = _peaks(cone, 4);
      expect(near.length, 2, reason: '$near');
      expect(near.first, inInclusiveRange(-1.8, -0.9)); // links der Front
      expect(near.last, inInclusiveRange(0.9, 1.8)); // rechts der Front
      // Dazwischen deutlich dunkler: zwei Scheinwerfer, kein Fleck.
      final l = cone.line(4);
      final mid = l[cone.w ~/ 2];
      expect(mid, lessThan(0.6 * l.reduce(math.max)));
      // Weiter vorn laufen die Felder zusammen.
      expect(_peaks(cone, 16).length, 1, reason: '${_peaks(cone, 16)}');
    });

    test('am hellsten einige Meter vor der Front, nicht an der Kabine', () {
      var best = 0.0, bestD = 0.0;
      for (var d = 0.0; d < headlightConeMeters; d += 0.25) {
        if (cone.rowMax(d) > best) {
          best = cone.rowMax(d).toDouble();
          bestD = d;
        }
      }
      expect(bestD, inInclusiveRange(3, 7));
      // Am Ansatz sichtbar (Anschluss an die Kabine), aber deutlich dunkler
      // als die Spitze – kein heller Fleck an der Kabine.
      expect(cone.rowMax(0), inInclusiveRange(0.4 * best, 0.65 * best));
      expect(best, greaterThan(180)); // nachts klar sichtbar
    });

    test('weicher Verlauf und 1,5–2× längere Reichweite', () {
      final half = cone.reach(0.5), tenth = cone.reach(0.1);
      expect(half / _oldHalfReach, inInclusiveRange(1.4, 2.0), reason: 'halbe Helligkeit bis $half m');
      expect(tenth / _oldTenthReach, inInclusiveRange(1.4, 2.0), reason: '10 % bis $tenth m');
      // Längs ohne Stufe: von der Spitze nach vorn stetig dunkler.
      var last = cone.rowMax(6);
      for (var d = 6.25; d < headlightConeMeters; d += 0.25) {
        final m = cone.rowMax(d);
        expect(m, lessThanOrEqualTo(last + 1));
        expect(last - m, lessThan(12), reason: 'Absatz bei $d m');
        last = m;
      }
    });

    test('keine harte Außenkante, nichts abgeschnitten', () {
      for (var y = 0; y < cone.h; y++) {
        expect(cone.alpha(0, y), lessThanOrEqualTo(2));
        expect(cone.alpha(cone.w - 1, y), lessThanOrEqualTo(2));
      }
      for (var x = 0; x < cone.w; x++) {
        expect(cone.alpha(x, 0), 0); // vorderes Ende vollständig ausgeblendet
      }
      // Nirgends ein Sprung zwischen Nachbarpixeln.
      var maxStep = 0;
      for (var y = 1; y < cone.h; y++) {
        for (var x = 1; x < cone.w; x++) {
          final a = cone.alpha(x, y);
          maxStep = math.max(maxStep, (a - cone.alpha(x - 1, y)).abs());
          maxStep = math.max(maxStep, (a - cone.alpha(x, y - 1)).abs());
        }
      }
      expect(maxStep, lessThan(16));
    });

    test('warm- bis neutralweiß', () {
      final y = cone.row(5);
      final x = cone.line(5).indexOf(cone.rowMax(5));
      final r = cone.channel(x, y, 0), g = cone.channel(x, y, 1), b = cone.channel(x, y, 2);
      expect(r, greaterThan(240));
      expect(g, inInclusiveRange(215, 250));
      expect(b, inInclusiveRange(180, 240));
      expect(r, greaterThanOrEqualTo(g));
      expect(g, greaterThan(b)); // warm, nicht bläulich
    });

    test('leichte Asymmetrie: rechts etwas weiter', () {
      double side(double sign) {
        for (var d = headlightConeMeters; d > 0; d -= 0.25) {
          final l = cone.line(d);
          final x = (cone.w / 2 + sign * 1.6 * cone.pxPerMeter).round();
          if (l[x] > 25) return d;
        }
        return 0;
      }

      expect(side(1), greaterThan(side(-1)));
      expect(side(1) - side(-1), lessThan(4)); // nur subtil
    });

    test('Tag unsichtbar, Dämmerung sehr schwach, Nacht klar – stetig', () {
      expect(headlightOpacity(nightLevel(30)), 0); // Tag
      expect(headlightOpacity(nightLevel(6)), 0);
      expect(headlightOpacity(nightLevel(1)), inInclusiveRange(0.1, 0.25)); // Sonne knapp über dem Horizont
      expect(headlightOpacity(nightLevel(-1)), inInclusiveRange(0.25, 0.45)); // Dämmerung: schwach
      expect(headlightOpacity(0.25), inInclusiveRange(0.08, 0.2)); // beginnende Dämmerung: sehr schwach
      expect(headlightOpacity(nightLevel(-8)), inInclusiveRange(0.75, 0.95)); // Nacht, nicht dominant
      var last = 0.0;
      for (var i = 1; i <= 1000; i++) {
        final o = headlightOpacity(i / 1000);
        expect(o, greaterThanOrEqualTo(last));
        expect(o - last, lessThan(0.005)); // kein Umschalten
        last = o;
      }
    });

    test('folgt ausschließlich der Zugmaschine – auch bei Knick', () {
      // 90°-Kurve: Zugmaschine schon herum, Auflieger noch schräg.
      final pts = <LatLng>[const LatLng(48, 14)];
      for (var i = 0; i < 300; i++) {
        pts.add(destination(pts.last, 20, 0));
      }
      for (var a = 0; a <= 90; a += 3) {
        pts.add(destination(pts.last, 20, a.toDouble()));
      }
      for (var i = 0; i < 300; i++) {
        pts.add(destination(pts.last, 20, 90));
      }
      final path = TourPath([TourLeg(points: pts)]);
      var sawKnick = false;
      for (var m = 100.0; m < path.totalMeters; m += 37) {
        final pose = articulate(path, m, metersPerUnit: 40);
        final light = headlightPlacement(pose, metersPerUnit: 40);
        expect(light.heading, pose.tractorHeading);
        if (pose.knick.abs() > 5) sawKnick = true;
        // Ansatz vor der Vorderachse, genau in Zugmaschinenrichtung.
        const d = Distance(calculator: Haversine());
        final dir = (d.bearing(pose.frontAxle, light.apex) + 360) % 360;
        expect((dir - pose.tractorHeading + 540) % 360 - 180, closeTo(0, 0.01));
        expect(d(pose.frontAxle, light.apex), closeTo(0.9 * 40, 0.05));
        // Auflieger anders gestellt: Licht unverändert.
        final bent = ArticulatedPose(
          frontAxle: pose.frontAxle,
          kingpin: pose.kingpin,
          trailerAxle: pose.trailerAxle,
          tractorHeading: pose.tractorHeading,
          trailerHeading: (pose.trailerHeading + 40) % 360,
        );
        final same = headlightPlacement(bent, metersPerUnit: 40);
        expect(same.apex, light.apex);
        expect(same.heading, light.heading);
      }
      expect(sawKnick, isTrue);
    });

    test('deterministisch bei 1×/2×/4×: gleiches Bild, gleiche Lage je Streckenmeter', () async {
      expect(await headlightConePng(), cone.bytes); // Bild byte-gleich
      final pts = <LatLng>[const LatLng(48, 14)];
      for (var i = 0; i < 400; i++) {
        pts.add(destination(pts.last, 20, (i ~/ 40).isEven ? 10 : 80));
      }
      final path = TourPath([TourLeg(points: pts)]);
      Map<int, ({LatLng apex, double heading})> run(int speed) => {
            for (var m = 0; m <= path.totalMeters; m += 25 * speed)
              m: headlightPlacement(articulate(path, m.toDouble(), metersPerUnit: 40), metersPerUnit: 40),
          };
      final one = run(1), two = run(2), four = run(4);
      for (final m in four.keys) {
        expect(two[m]!.apex, one[m]!.apex);
        expect(four[m]!.apex, one[m]!.apex);
        expect(four[m]!.heading, one[m]!.heading);
      }
    });

    test('wächst wie der LKW: Verhältnis Licht/Fahrzeug in jedem Shot gleich', () {
      // Szene: Lichtgröße = headlightConeMeters · Punkte je Meter · 2^(Kamera − Folge-Zoom),
      // Fahrzeug = Punkte je Meter · 2^(Kamera − Folge-Zoom) – gleicher Faktor.
      final plan = CinematicPlan.standard(const Duration(seconds: 33));
      for (final p in [0.1, 0.29, 0.37, 0.49, 0.84]) {
        final f = math.pow(2, plan.at(p).zoom).toDouble();
        final light = headlightConeMeters * f, truck = 1.0 * f;
        expect(light / truck, headlightConeMeters);
      }
    });
  });

  group('Frontscheibe nachts', () {
    test('gleitend dunkler, nie schwarz', () {
      double lum(Color c) => c.computeLuminance();
      expect(windshieldColor(0), const Color(0xFF90CAF9));
      var last = lum(windshieldColor(0));
      for (var i = 1; i <= 8; i++) {
        final l = lum(windshieldColor(i / 8));
        expect(l, lessThan(last));
        last = l;
      }
      expect(last, greaterThan(0.01)); // dunkles Blau-Anthrazit, nicht schwarz
      final night = windshieldColor(1);
      expect(night.b, greaterThan(night.r)); // bläulich
    });

    test('Nachtfaktor in Achtelstufen – kleine, gleichmäßige Schritte', () {
      expect(nightStep(0), 0);
      expect(nightStep(1), 1);
      expect(nightStep(0.49), 0.5);
      expect(nightStep(0.07), 0.125);
      expect(nightStep(-1), 0);
      expect(nightStep(2), 1);
    });
  });

  group('Fahrzeuggröße', () {
    test('Normalfahrt kleiner, Shots über die Kamera wieder wie bisher', () {
      const follow = 0.62; // TourAnimationSceneMapLibre.followSize
      final plan = CinematicPlan.standard(const Duration(seconds: 33));
      // bisher: PASS +0,55 Zoom bei Größe 1
      final before = 1.0 * math.pow(2, 0.55);
      final now = follow * math.pow(2, plan.at(0.29).zoom);
      expect(now / before, closeTo(1, 0.05));
      expect(plan.at(0.1).zoom, 0); // Normalfahrt: kein Heranzoomen
    });
  });
}
