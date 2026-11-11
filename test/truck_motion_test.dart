import 'dart:math' as math;

import 'package:driverroute_eta/animation/articulation.dart';
import 'package:driverroute_eta/animation/camera_dramaturgy.dart';
import 'package:driverroute_eta/animation/cinematic_camera.dart';
import 'package:driverroute_eta/animation/tour_camera.dart';
import 'package:driverroute_eta/animation/tour_motion.dart';
import 'package:driverroute_eta/animation/tour_path.dart';
import 'package:driverroute_eta/animation/tour_story.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';

const _d = Distance(calculator: Haversine());

/// Maßstab wie im Bild: 1 Fahrzeugmeter = 40 Kartenmeter.
const _unit = 40.0;

/// Strecke aus Kursen: [(Länge in Fahrzeugmetern, Kurs °), …].
TourPath _course(List<(double, double)> legs) {
  final pts = <LatLng>[const LatLng(48, 14)];
  for (final (len, bearing) in legs) {
    final n = math.max(1, len.ceil());
    for (var i = 0; i < n; i++) {
      pts.add(destination(pts.last, len / n * _unit, bearing));
    }
  }
  return TourPath([TourLeg(points: pts)]);
}

/// Bogen mit Radius [r] (Fahrzeugmeter) über [angle]° ab Kurs [from].
List<(double, double)> _arc(double r, double from, double angle) {
  final n = (angle.abs() / 3).ceil();
  final step = angle / n;
  final seg = 2 * math.pi * r * (step.abs() / 360);
  return [for (var i = 0; i < n; i++) (seg, from + step * (i + 0.5))];
}

ArticulatedTrack _track(TourPath p) =>
    ArticulatedTrack(p, unitAt: (_) => _unit, inertia: cinematicTruckInertia);

/// Fahrt im Filmtempo mit 60 Bildern/s: Drehraten, Zittern, Knick, Tempo.
({
  double maxTurn,
  double p95Turn,
  int flips,
  double maxKnick,
  double maxKnickRate,
  double maxTrailerRate,
  List<(double, double)> speed, // (Meter, m/s)
  Duration drive,
}) _drive(TourPath p, {double speed = 1}) {
  final track = _track(p);
  final motion = TourMotion(path: p, oldDrive: tourAnimationDuration(p.totalMeters), track: track);
  final dt = speed / 60;
  final turns = <double>[];
  var flips = 0;
  double? lastH, lastT, lastK, lastSign, lastM;
  var maxK = 0.0, maxKr = 0.0, maxTr = 0.0;
  final sp = <(double, double)>[];
  final end = motion.duration.inMicroseconds / 1e6;
  for (var t = 0.0; t <= end; t += dt) {
    final m = motion.metersAt(t);
    final pose = track.pose(m, metersPerUnit: _unit);
    if (lastH != null) {
      final dh = angleDiff(lastH, pose.tractorHeading);
      turns.add(dh.abs() / dt);
      if (dh.abs() > 0.5 && lastSign != null && dh.sign != lastSign) flips++;
      if (dh.abs() > 0.5) lastSign = dh.sign;
      maxKr = math.max(maxKr, (pose.knick - lastK!).abs() / dt);
      maxTr = math.max(maxTr, angleDiff(lastT!, pose.trailerHeading).abs() / dt);
      sp.add((m, (m - lastM!) / dt));
    }
    maxK = math.max(maxK, pose.knick.abs());
    lastH = pose.tractorHeading;
    lastT = pose.trailerHeading;
    lastK = pose.knick;
    lastM = m;
  }
  final sorted = [...turns]..sort();
  return (
    maxTurn: sorted.last,
    p95Turn: sorted[(sorted.length * 0.95).floor()],
    flips: flips,
    maxKnick: maxK,
    maxKnickRate: maxKr,
    maxTrailerRate: maxTr,
    speed: sp,
    drive: motion.duration,
  );
}

double _speedNear(List<(double, double)> sp, double m) =>
    sp.reduce((a, b) => (a.$1 - m).abs() < (b.$1 - m).abs() ? a : b).$2;

void main() {
  group('Fahrspur mit Trägheit', () {
    test('1 · lange Autobahngerade: ruhig, kein Knick, gleichmäßiges Tempo', () {
      final p = _course([(6000, 70)]);
      final r = _drive(p);
      expect(r.maxTurn, lessThan(1));
      expect(r.maxKnick, lessThan(0.5));
      final mid = r.speed.where((s) => s.$1 > p.totalMeters * 0.3 && s.$1 < p.totalMeters * 0.7).map((s) => s.$2);
      expect(mid.reduce(math.max) / mid.reduce(math.min), lessThan(1.02));
    });

    test('2 · leichte Autobahnkurve: kaum Drehung, kein Bremsen nötig', () {
      final p = _course([(2000, 0), ..._arc(800, 0, 25), (2000, 25)]);
      final r = _drive(p);
      expect(r.maxTurn, lessThan(60));
      expect(r.flips, 0);
    });

    test('3 · 90°-Kurve: Knick entsteht weich, Auflieger läuft nach und richtet sich wieder aus', () {
      final p = _course([(2000, 0), ..._arc(60, 0, 90), (2000, 90)]);
      final track = _track(p);
      final r = _drive(p);
      expect(r.flips, 0);
      expect(r.maxTurn, lessThan(170)); // Drehrate begrenzt (Ziel ≤ ≈ 100 °/s)
      expect(r.maxKnickRate, lessThan(120));
      // In der Kurve: Auflieger hinkt hinterher (Rechtskurve → Auflieger
      // steht links, Knick negativ), überholt nie.
      var minKnick = 0.0;
      for (var m = 2000 * _unit; m < 2000 * _unit + 400 * _unit; m += _unit) {
        minKnick = math.min(minKnick, track.pose(m, metersPerUnit: _unit).knick);
      }
      expect(minKnick, lessThan(-5));
      expect(r.maxKnick, lessThanOrEqualTo(70));
      // Danach wieder gerade.
      final after = track.pose(p.totalMeters - 200 * _unit, metersPerUnit: _unit);
      expect(after.knick.abs(), lessThan(1));
      expect(angleDiff(after.tractorHeading, 90).abs(), lessThan(1));
      // In der Kurve sichtbar langsamer als auf der Geraden.
      expect(_speedNear(r.speed, 2000 * _unit + 47 * _unit), lessThan(_speedNear(r.speed, 1000 * _unit) * 0.8));
    });

    test('4 · Autobahnkreuz (270°-Schleife): kein Schleudern, langsamer, Auflieger bleibt dahinter', () {
      final p = _course([(1500, 0), ..._arc(40, 0, -270), (1500, 90)]);
      final r = _drive(p);
      expect(r.flips, lessThanOrEqualTo(1));
      expect(r.maxTurn, lessThan(170));
      expect(r.maxKnick, lessThanOrEqualTo(70));
      expect(r.maxTrailerRate, lessThan(170));
    });

    test('5 · Links-rechts-Kurvenfolge: Richtung wechselt nur mit der Straße', () {
      final p = _course([
        (1500, 0),
        for (var i = 0; i < 6; i++) ..._arc(80, i.isEven ? 0 : 30, i.isEven ? 30 : -30),
        (1500, 0),
      ]);
      final r = _drive(p);
      expect(r.flips, lessThanOrEqualTo(6)); // höchstens ein Wechsel je Kurve
      expect(r.maxTurn, lessThan(120));
    });

    test('6 · Stadtumfahrung: Vorderachse exakt auf der Route, Sattelpunkt nah dran', () {
      const centre = LatLng(48.3, 14.2);
      final pts = [
        destination(centre, 400 * _unit, 270),
        for (var a = 180; a >= 0; a -= 3) destination(centre, 150 * _unit, (90 + a).toDouble()),
        destination(centre, 400 * _unit, 90),
      ];
      final p = TourPath([TourLeg(points: pts)]);
      final track = _track(p);
      for (var m = 0.0; m <= p.totalMeters; m += p.totalMeters / 300) {
        final pose = track.pose(m, metersPerUnit: _unit);
        expect(_d(pose.frontAxle, p.at(m).point), lessThan(0.01));
        // Nie durch die Stadt: der Sattelpunkt bleibt weit vom Zentrum.
        expect(_d(pose.kingpin, centre), greaterThan(140 * _unit));
      }
    });

    test('7 · enge Grenzregion (Schlenker kleiner als das Fahrzeug): kein Zittern', () {
      final p = _course([
        (1500, 0),
        for (var i = 0; i < 40; i++) (3, i.isEven ? 20 : -20), // Zickzack je 3 m
        (1500, 0),
      ]);
      final r = _drive(p);
      expect(r.flips, lessThanOrEqualTo(2));
      expect(r.maxTurn, lessThan(30));
      // Alt: die Zugmaschine sprang jedem Schlenker nach.
      final old = <double>[];
      for (var m = 1500.0 * _unit; m < 1620 * _unit; m += 10) {
        old.add(articulate(p, m, metersPerUnit: _unit).tractorHeading);
      }
      var oldFlips = 0;
      for (var i = 2; i < old.length; i++) {
        final a = angleDiff(old[i - 2], old[i - 1]), b = angleDiff(old[i - 1], old[i]);
        if (a.abs() > 0.5 && b.abs() > 0.5 && a.sign != b.sign) oldFlips++;
      }
      expect(oldFlips, greaterThan(r.flips));
    });
  });

  group('Filmtempo und Kamera', () {
    final p = _course([
      (8000, 0),
      ..._arc(60, 0, 90),
      (8000, 90),
      for (var i = 0; i < 6; i++) ..._arc(80, i.isEven ? 90 : 120, i.isEven ? 30 : -30),
      (8000, 90),
    ]);

    test('deutlich langsamer, Kamerafahrten behalten ihre Dauer in Sekunden', () {
      final old = tourAnimationDuration(p.totalMeters);
      final m = cinematicMotionFor(p);
      expect(m.motion.duration.inMilliseconds, greaterThan(old.inMilliseconds * 1.5));
      final before = CinematicPlan.standard(old).keys;
      final after = m.plan.keys.where((k) => !isDramaturgyShot(k.shot)).toList();
      expect(after.map((k) => k.shot).where((s) => s != 'FOLLOW'), before.map((k) => k.shot).where((s) => s != 'FOLLOW'));
      // Jede Kamerafahrt beginnt am selben Ort und dauert gleich lang.
      final oldWin = cameraWindows(CinematicPlan.standard(old));
      final newWin = cameraWindows(m.plan);
      expect(newWin.length, oldWin.length);
      for (var i = 0; i < oldWin.length; i++) {
        expect(newWin[i].$1, closeTo(oldWin[i].$1, 1e-9));
        final oldS = legacyDriveSeconds(oldWin[i].$2, old) - legacyDriveSeconds(oldWin[i].$1, old);
        final newS = m.motion.secondsAt(newWin[i].$2 * p.totalMeters) - m.motion.secondsAt(newWin[i].$1 * p.totalMeters);
        expect(newS, closeTo(oldS, 0.05));
      }
    });

    test('8 · Kamerafahrt in einer Kurve verändert die Fahrzeugpose nie', () {
      final m = cinematicMotionFor(p);
      final cam = CinematicCamera(p, plan: m.plan);
      final track = _track(p);
      for (var t = 0.0; t < m.motion.duration.inMicroseconds / 1e6; t += 1 / 30) {
        final meters = m.motion.metersAt(t);
        final a = track.pose(meters, metersPerUnit: _unit);
        cam.step(meters, const Duration(microseconds: 33333));
        final b = track.pose(meters, metersPerUnit: _unit);
        expect(b.tractorHeading, a.tractorHeading);
        expect(b.trailerHeading, a.trailerHeading);
      }
    });

    test('keine abrupten Tempowechsel; Zeitleiste nutzt das Filmtempo', () {
      final m = cinematicMotionFor(p);
      var last = m.motion.metersAt(0);
      double? lastV;
      var maxJump = 0.0;
      for (var t = 1 / 60; t < m.motion.duration.inMicroseconds / 1e6; t += 1 / 60) {
        final x = m.motion.metersAt(t);
        final v = (x - last) * 60;
        if (lastV != null && lastV > 0) maxJump = math.max(maxJump, (v - lastV).abs() / lastV);
        lastV = v;
        last = x;
      }
      expect(maxJump, lessThan(0.08)); // < 8 % Tempoänderung je Bild
      final tl = TourTimeline(path: p, drive: m.motion.duration, motion: m.motion);
      final half = Duration(microseconds: m.motion.duration.inMicroseconds ~/ 2);
      expect(tl.frameAt(half).meters, closeTo(m.motion.metersAt(half.inMicroseconds / 1e6), 1e-6));
      expect(tl.frameAt(m.motion.duration).meters, p.totalMeters);
    });

    test('deterministisch: gleiche Zeit → gleiche Stelle und Pose; 1×/2×/4× gleich', () {
      final a = cinematicMotionFor(p), b = cinematicMotionFor(p);
      expect(b.motion.duration, a.motion.duration);
      for (var t = 0.0; t < a.motion.duration.inMicroseconds / 1e6; t += 0.37) {
        expect(b.motion.metersAt(t), a.motion.metersAt(t));
      }
      final r1 = _drive(p), r4 = _drive(p, speed: 4);
      expect(r4.drive, r1.drive);
      expect(r4.maxKnick, closeTo(r1.maxKnick, 1.0));
    });
  });

  group('Filmische Führung (Standard)', () {
    test('Heck des Aufliegers klebt auf der gefahrenen Route, Vorderachse vorne', () {
      final p = _course([(3000, 0), ..._arc(60, 0, 90), (3000, 90), ..._arc(80, 90, -45), (3000, 45)]);
      final c = cinematicMotionFor(p);
      final h = c.heading!;
      expect(h.rearOnRoute, isTrue);
      final offs = <double>[];
      for (var m = p.totalMeters * 0.05; m < p.totalMeters; m += p.totalMeters / 300) {
        final u = h.unitAt!(p.at(m).point);
        final pose = h.pose(m, metersPerUnit: u);
        final dp = h.displayPath;
        // Vorderachse auf der Darstellungslinie (Route auf Lkw-Maßstab geglättet).
        expect(_d(pose.frontAxle, dp.at(h.displayMetersAt(m)).point), lessThan(0.01));
        // Die geglättete Linie bleibt nah an der echten Route (≤ ½ Lkw-Länge).
        expect(_d(pose.frontAxle, p.at(m).point), lessThan(8.4 * u));
        final rear = destination(pose.kingpin, CinematicHeading.trailerRearBehindKingpin * u,
            (pose.trailerHeading + 180) % 360);
        final onRoute = h.displayPath.at(h.rearMetersAt(m, pose.kingpin, u)).point;
        offs.add(_d(rear, onRoute) / u);
        expect(pose.knick.abs(), lessThanOrEqualTo(70));
      }
      offs.sort();
      // Fast immer genau auf der Route; nur wo der Schwenk begrenzt ist,
      // liegt das Heck kurz knapp daneben (in Fahrzeugmetern).
      expect(offs[(offs.length * 0.9).floor()], lessThan(0.15));
      expect(offs.last, lessThan(1));
    });
  });

  group('Kamera-Rhythmus', () {
    final p = _course([(20000, 0), ..._arc(60, 0, 90), (20000, 90)]);

    test('nah am Start, weit unterwegs, heran zum Ziel – Lkw nie vergrößert', () {
      final c = cinematicMotionFor(p, truckScale: 0.6, motionTruckScale: 1);
      final plan = c.plan;
      expect(plan.at(0).shot, 'START');
      expect(plan.at(0).zoom, greaterThan(1));
      expect(plan.at(1).shot, 'APPROACH');
      expect(plan.at(1).zoom, greaterThan(0.5));
      final shots = plan.keys.map((k) => k.shot).toSet();
      expect(shots, contains('WIDE'));
      // Weich: keine Sprünge in Zoom/Neigung.
      var last = plan.at(0);
      for (var i = 1; i <= 20000; i++) {
        final s = plan.at(i / 20000);
        expect((s.zoom - last.zoom).abs(), lessThan(0.03));
        expect((s.pitch - last.pitch).abs(), lessThan(0.5));
        last = s;
      }
      // Kleiner gezeichneter Lkw fährt die Tour nicht länger.
      expect(c.motion.duration, cinematicMotionFor(p).motion.duration);
    });

    test('nachts näher heran statt weit – von vorn', () {
      final long = _course([(80000, 0), ..._arc(60, 0, 90), (80000, 90)]);
      final day = cinematicMotionFor(long, nightAt: (_) => 0).plan.keys.map((k) => k.shot);
      final nightPlan = cinematicMotionFor(long, nightAt: (_) => 1).plan;
      final night = nightPlan.keys.map((k) => k.shot);
      // NIGHT-Stützpunkte liegen schräg vor dem Lkw (Bahnwinkel ≈ −150°).
      final orbits = nightPlan.keys.where((k) => k.shot == 'NIGHT').map((k) => ((k.orbit % 360) + 360) % 360);
      for (final o in orbits) {
        expect(o, closeTo(210, 1));
      }
      expect(day, contains('WIDE'));
      expect(night, contains('NIGHT'));
      expect(night, isNot(contains('WIDE')));
    });
  });
}
