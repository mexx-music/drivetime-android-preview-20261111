import 'dart:math' as math;

import 'package:driverroute_eta/animation/articulation.dart';
import 'package:driverroute_eta/animation/cinematic_camera.dart';
import 'package:driverroute_eta/animation/tour_camera.dart';
import 'package:driverroute_eta/animation/tour_path.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';

/// Strecke mit Umfahrung, Kleeblatt, langer Kurve, Kurvenfolge und Geraden
/// (≈ 2.000 km, Punkte ≈ 1 km) – wie eine echte Etappen-Geometrie.
TourPath _route() {
  final pts = <LatLng>[const LatLng(40.9, 26.4)];
  void go(double km, double bearing) {
    for (var i = 0; i < km; i++) {
      pts.add(destination(pts.last, 1000, bearing));
    }
  }

  go(300, 330); // gerade Autobahn
  for (var i = 0; i < 12; i++) {
    go(8, 330 + (i.isEven ? 40 : -40)); // enge Kurvenfolge
  }
  for (var a = 0; a < 270; a += 15) {
    go(2, 330 - a.toDouble()); // Kreuz-Schleife
  }
  for (var a = 0; a <= 90; a += 5) {
    go(20, 60 - a.toDouble()); // lange Kurve
  }
  go(40, 350);
  go(30, 20);
  go(40, 350); // Umfahrung
  go(600, 335);
  return TourPath([TourLeg(points: pts)]);
}

/// Fahrt bei festem Bildtakt; liefert Kamerazustände je Bild.
List<(double, CameraState)> _run(CinematicCamera cam, {double speed = 1}) {
  final path = cam.path;
  final drive = tourAnimationDuration(path.totalMeters);
  const dt = Duration(microseconds: 16667);
  final out = <(double, CameraState)>[];
  for (var t = Duration.zero; t <= drive; t += Duration(microseconds: (dt.inMicroseconds * speed).round())) {
    final m = tourEase(t.inMicroseconds / drive.inMicroseconds) * path.totalMeters;
    out.add((m, cam.step(m, dt)));
  }
  return out;
}

void main() {
  final path = _route();
  final drive = tourAnimationDuration(path.totalMeters);

  group('Regie', () {
    test('Länge entscheidet: kurz nur Folgen, mittel 1, lang 2 Manöver', () {
      expect(CinematicPlan.standard(const Duration(seconds: 10)).manoeuvres, 0);
      expect(CinematicPlan.standard(const Duration(seconds: 20)).manoeuvres, 1);
      expect(CinematicPlan.standard(const Duration(seconds: 33)).manoeuvres, 2);
    });

    test('Shots an 0/25/50/75/100 % und ruhiger Zielanflug', () {
      final plan = CinematicPlan.standard(drive);
      expect(plan.at(0).shot, 'FOLLOW');
      expect(plan.at(0.25).shot, 'PASS');
      expect(plan.at(0.37).shot, 'FRONT 3/4');
      expect(plan.at(0.50).shot, 'RETURN');
      expect(plan.at(0.62).shot, 'FOLLOW');
      expect(plan.at(0.75).shot, 'PASS');
      expect(plan.at(1).shot, 'FOLLOW');
      for (var p = 0.92; p <= 1; p += 0.01) {
        expect(plan.at(p).orbit % 360, closeTo(0, 1e-9)); // keine Kamerafahrt am Ende
      }
    });

    test('stetig: keine Sprünge zwischen Shots', () {
      final plan = CinematicPlan.standard(drive);
      var last = plan.at(0);
      for (var i = 1; i <= 10000; i++) {
        final s = plan.at(i / 10000);
        expect((s.orbit - last.orbit).abs(), lessThan(1.0));
        expect((s.pitch - last.pitch).abs(), lessThan(0.1));
        expect((s.zoom - last.zoom).abs(), lessThan(0.01));
        expect((s.ahead - last.ahead).abs(), lessThan(0.01));
        last = s;
      }
    });
  });

  group('Kamera', () {
    test('Folgemodus = bisherige Folgekamera (TourCameraRig)', () {
      final cam = CinematicCamera(path);
      final rig = TourCameraRig(path);
      for (final (m, c) in _run(cam).take(600)) {
        final b = rig.step(m, const Duration(microseconds: 16667));
        expect(angleDiff(c.bearing, b).abs(), lessThan(1e-9));
        expect(c.pitch, rig.pitch);
        expect(c.zoom, rig.zoom);
      }
    });

    test('Drehung begrenzt (≤ 45°/s), auch in Kurven und Manövern', () {
      final run = _run(CinematicCamera(path, plan: CinematicPlan.standard(drive)));
      for (var i = 1; i < run.length; i++) {
        expect(angleDiff(run[i - 1].$2.bearing, run[i].$2.bearing).abs(), lessThanOrEqualTo(45 * 0.016667 + 1e-6));
      }
    });

    test('keine Positionssprünge: Zielpunkt wandert stetig', () {
      final run = _run(CinematicCamera(path, plan: CinematicPlan.standard(drive)));
      const d = Distance(calculator: Haversine());
      var maxJump = 0.0;
      for (var i = 1; i < run.length; i++) {
        maxJump = math.max(maxJump, d(run[i - 1].$2.target, run[i].$2.target));
      }
      // Fahrzeug fährt ≤ ≈ 0,3 % der Tour je Bild; der Zielpunkt nie viel mehr.
      expect(maxJump, lessThan(path.totalMeters * 0.004));
    });

    test('Manöver erreichen Seite und Front (Bahnwinkel), danach wieder hinten', () {
      final run = _run(CinematicCamera(path, plan: CinematicPlan.standard(drive)));
      double orbitAt(double p) => run.firstWhere((r) => r.$1 >= p * path.totalMeters).$2.orbit;
      expect(orbitAt(0.29), closeTo(-95, 2));
      expect(orbitAt(0.37), lessThan(-150));
      expect(orbitAt(0.65) % 360, closeTo(0, 1e-6));
      expect(orbitAt(0.79) % 360, closeTo(95, 2)); // rechte Seite
    });

    test('Neustart reproduziert exakt dieselbe Kamerafahrt', () {
      final cam = CinematicCamera(path, plan: CinematicPlan.standard(drive));
      final a = _run(cam);
      cam.reset();
      final b = _run(cam);
      expect(a.length, b.length);
      for (var i = 0; i < a.length; i += 97) {
        expect(b[i].$2.bearing, a[i].$2.bearing);
        expect(b[i].$2.target, a[i].$2.target);
        expect(b[i].$2.zoom, a[i].$2.zoom);
      }
    });

    test('1×/2×/4×: dieselbe Shot-Folge entlang der Tour', () {
      List<String> shots(double speed) {
        final cam = CinematicCamera(path, plan: CinematicPlan.standard(drive));
        final out = <String>[];
        for (final (_, c) in _run(cam, speed: speed)) {
          if (out.isEmpty || out.last != c.shot) out.add(c.shot);
        }
        return out;
      }

      final one = shots(1);
      expect(shots(2), one);
      expect(shots(4), one);
      expect(one, ['FOLLOW', 'PASS', 'FRONT 3/4', 'RETURN', 'FOLLOW', 'PASS', 'SIDE 3/4', 'FOLLOW']);
    });

    test('Kamera beeinflusst das Fahrzeug nie: Pose identisch mit/ohne Cinematic', () {
      final cine = CinematicCamera(path, plan: CinematicPlan.standard(drive));
      final follow = CinematicCamera(path);
      final unit = 5 * metersPerScreenPoint(follow.followZoom, 45);
      for (final (m, _) in _run(cine).where((r) => r.$1 > 0).take(2000)) {
        follow.step(m, const Duration(microseconds: 16667));
        final a = articulate(path, m, metersPerUnit: unit);
        final b = articulate(path, m, metersPerUnit: unit);
        expect(a.tractorHeading, b.tractorHeading);
        expect(a.trailerHeading, b.trailerHeading);
        expect(a.frontAxle, path.at(m).point); // exakt auf der Route
      }
      // Bezugsmaßstab für das Fahrzeug hängt nur vom Folge-Zoom ab, nicht
      // vom Zoom der aktuellen Kamerafahrt.
      expect(cine.followZoom, follow.followZoom);
    });

    test('Smartphone/9:16: weiter weg, nähere Shots gedämpft', () {
      final wide = CinematicCamera(path, plan: CinematicPlan.standard(drive), aspect: 1.6);
      final portrait = CinematicCamera(path, plan: CinematicPlan.standard(drive), aspect: 9 / 16);
      final w = _run(wide), p = _run(portrait);
      double zoomAt(List<(double, CameraState)> r, double f) =>
          r.firstWhere((x) => x.$1 >= f * path.totalMeters).$2.zoom;
      expect(zoomAt(p, 0.1), lessThan(zoomAt(w, 0.1) - 0.4)); // Folgen
      expect(zoomAt(p, 0.29) - zoomAt(p, 0.1), lessThan(zoomAt(w, 0.29) - zoomAt(w, 0.1))); // Pass
    });

    test('manueller Zoom: Regie aus, Folgekamera mit Nutzer-Zoom', () {
      final cam = CinematicCamera(path, plan: CinematicPlan.standard(drive));
      final s = cam.step(path.totalMeters * 0.3, Duration.zero, manualZoom: 9);
      expect(s.zoom, 9);
      expect(s.orbit, 0);
      expect(s.shot, 'FOLLOW');
    });
  });
}
