import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:driverroute_eta/animation/articulation.dart';
import 'package:driverroute_eta/animation/cinematic_camera.dart';
import 'package:driverroute_eta/animation/daylight.dart';
import 'package:driverroute_eta/animation/ferry_cinematic.dart';
import 'package:driverroute_eta/animation/ship_model.dart';
import 'package:driverroute_eta/animation/tour_camera.dart';
import 'package:driverroute_eta/animation/tour_path.dart';
import 'package:driverroute_eta/animation/truck_projection.dart';
import 'package:driverroute_eta/logic/eta_calculator.dart';
import 'package:driverroute_eta/ui/ship_sprites.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';

const _d = Distance(calculator: Haversine());

/// Gerade Strecke aus [start] mit Punkten je km.
List<LatLng> _road(LatLng start, double km, double bearing) {
  final pts = <LatLng>[start];
  for (var i = 0; i < km; i++) {
    pts.add(destination(pts.last, 1000, bearing));
  }
  return pts;
}

/// Tour wie aus der Kartenplanung: Landweg, Seestrecke, Landweg.
/// [ferry] = Zwischenpunkte der Seestrecke (ohne Häfen) für eine Geometrie
/// mit mehr als zwei Punkten.
TourPath _ferryTour({double roadA = 300, double seaKm = 330, double roadB = 650, List<double> bends = const []}) {
  final a = _road(const LatLng(39.0, 21.0), roadA, 0);
  final sea = <LatLng>[a.last];
  if (bends.isEmpty) {
    sea.add(destination(a.last, seaKm * 1000, 300));
  } else {
    final part = seaKm / (bends.length);
    for (final b in bends) {
      sea.add(destination(sea.last, part * 1000, b));
    }
  }
  final b = _road(sea.last, roadB, 330);
  return TourPath([
    TourLeg(points: a, label: 'Anfahrt'),
    TourLeg(points: sea, kind: TourLegKind.ferry, label: 'Fähre'),
    TourLeg(points: b, label: 'Ziel'),
  ]);
}

TourPath _roadTour() => TourPath([TourLeg(points: _road(const LatLng(40.9, 26.4), 1200, 330))]);

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

CinematicPlan _plan(TourPath p) {
  final drive = tourAnimationDuration(p.totalMeters);
  return ferryAwarePlan(CinematicPlan.standard(drive), p, drive);
}

List<String> _shots(TourPath p, {double speed = 1, double aspect = 1.6}) {
  final cam = CinematicCamera(p, plan: _plan(p), aspect: aspect);
  final out = <String>[];
  for (final (_, c) in _run(cam, speed: speed)) {
    if (out.isEmpty || out.last != c.shot) out.add(c.shot);
  }
  return out;
}

/// Abstand eines Punktes zum Linienzug (Meter, lokal eben genähert).
double _distToPolyline(LatLng p, List<LatLng> line) {
  var best = double.infinity;
  for (var i = 1; i < line.length; i++) {
    final a = line[i - 1], b = line[i];
    final kx = math.cos(p.latitude * math.pi / 180);
    final ax = a.longitude * kx, ay = a.latitude, bx = b.longitude * kx, by = b.latitude;
    final px = p.longitude * kx, py = p.latitude;
    final vx = bx - ax, vy = by - ay;
    final t = (((px - ax) * vx + (py - ay) * vy) / (vx * vx + vy * vy)).clamp(0.0, 1.0);
    final q = LatLng(ay + vy * t, (ax + vx * t) / kx);
    best = math.min(best, _d(p, q));
  }
  return best;
}

void main() {
  group('Fährdaten aus der Tour', () {
    test('Tour ohne Fähre: unverändert (gleiche Regie, nur LKW)', () {
      final p = _roadTour();
      final drive = tourAnimationDuration(p.totalMeters);
      final base = CinematicPlan.standard(drive);
      expect(ferryCrossings(p), isEmpty);
      expect(identical(ferryAwarePlan(base, p, drive), base), isTrue);
      for (var m = 0.0; m <= p.totalMeters; m += p.totalMeters / 97) {
        final mix = vehicleAt(p, const [], m);
        expect(mix.ship, 0);
        expect(mix.truckMeters, m);
      }
      expect(_shots(p), ['FOLLOW', 'PASS', 'FRONT 3/4', 'RETURN', 'FOLLOW', 'PASS', 'SIDE 3/4', 'FOLLOW']);
    });

    test('genau eine Fähre: Bereich = Fährabschnitt der Linie', () {
      final p = _ferryTour();
      final c = ferryCrossings(p);
      expect(c, hasLength(1));
      final spans = p.legSpans;
      expect(c.single.startMeters, spans[0].to);
      expect(c.single.endMeters, spans[2].from);
      expect(c.single.length, closeTo(330000, 500));
      expect(c.single.label, 'Fähre');
      expect(p.at(c.single.startMeters + 1000).kind, TourLegKind.ferry);
    });

    test('Fähre folgt exakt der vorhandenen Fährgeometrie (auch mit Knicken)', () {
      for (final p in [_ferryTour(), _ferryTour(bends: [280, 320, 300])]) {
        final c = ferryCrossings(p).single;
        final sea = p.legs[1].points;
        for (var m = c.startMeters; m <= c.endMeters; m += c.length / 53) {
          final mix = vehicleAt(p, [c], m);
          expect(_distToPolyline(p.at(mix.shipMeters).point, sea), lessThan(1), reason: 'bei $m');
        }
      }
    });

    test('Kurs des Schiffs = Richtung der Fährgeometrie, auch am Kai', () {
      final p = _ferryTour();
      final c = ferryCrossings(p).single;
      final expected = (_d.bearing(p.legs[1].points.first, p.legs[1].points.last) + 360) % 360;
      for (final m in [c.startMeters - 20000, c.startMeters, c.startMeters + c.length / 2, c.endMeters, c.endMeters + 20000]) {
        final mix = vehicleAt(p, [c], m);
        final h = shipHeading(p, c, mix.shipMeters);
        // Großkreis über 330 km dreht leicht – an jeder Stelle nahe der Sehne.
        expect(angleDiff(h, expected).abs(), lessThan(2.5), reason: 'bei $m');
      }
    });
  });

  group('Übergänge', () {
    final p = _ferryTour();
    final c = ferryCrossings(p).single;
    final fade = ferryFadeMeters(p, c);

    test('LKW → Fähre: weich, LKW hält am Hafen, Fähre legt erst danach ab', () {
      var last = 0.0;
      for (var m = c.startMeters - 2 * fade; m <= c.startMeters + 2 * fade; m += fade / 50) {
        final mix = vehicleAt(p, [c], m);
        expect(mix.ship, greaterThanOrEqualTo(last - 1e-12)); // nur zunehmend
        expect(mix.ship - last, lessThan(0.04)); // kein Schnitt
        last = mix.ship;
        if (mix.ship > 0) {
          expect(mix.truckMeters, lessThanOrEqualTo(c.startMeters)); // nicht aufs Wasser
          expect(mix.shipMeters, greaterThanOrEqualTo(c.startMeters)); // nicht an Land
        }
      }
      expect(vehicleAt(p, [c], c.startMeters - fade - 1).ship, 0);
      expect(vehicleAt(p, [c], c.startMeters + fade).ship, 1);
    });

    test('Fähre → LKW: weich, LKW fährt am Zielhafen weiter', () {
      var last = 1.0;
      for (var m = c.endMeters - 2 * fade; m <= c.endMeters + 2 * fade; m += fade / 50) {
        final mix = vehicleAt(p, [c], m);
        expect(mix.ship, lessThanOrEqualTo(last + 1e-12));
        expect(last - mix.ship, lessThan(0.04));
        last = mix.ship;
        if (mix.crossing != null && mix.ship < 1) {
          expect(mix.truckMeters, greaterThanOrEqualTo(c.endMeters));
          expect(mix.shipMeters, lessThanOrEqualTo(c.endMeters));
        }
      }
      expect(vehicleAt(p, [c], c.endMeters + fade + 1).ship, 0);
      expect(vehicleAt(p, [c], c.endMeters + fade + 1).truckMeters, c.endMeters + fade + 1);
    });

    test('Kamera: FOLLOW → TO PORT → FERRY FOLLOW … TO DEST PORT → FOLLOW, stetig', () {
      final plan = _plan(p);
      final total = p.totalMeters;
      expect(plan.at(c.startMeters / total - 0.05).shot, shotToPort);
      expect(plan.at(c.startMeters / total + 0.05).shot, shotFerryFollow);
      expect(plan.at(c.endMeters / total - 0.003).shot, shotToDestPort);
      expect(plan.at(math.min(1, c.endMeters / total + 0.09)).shot, 'FOLLOW');
      // Höher (weiter weg) beim Übergang, ohne Sprünge.
      expect(plan.at(c.startMeters / total - 0.01).zoom, lessThan(0));
      var last = plan.at(0);
      for (var i = 1; i <= 20000; i++) {
        final s = plan.at(i / 20000);
        expect((s.orbit - last.orbit).abs(), lessThan(1.0), reason: 'Bahn bei ${i / 20000}');
        expect((s.zoom - last.zoom).abs(), lessThan(0.02));
        expect((s.pitch - last.pitch).abs(), lessThan(0.5));
        expect((s.ahead - last.ahead).abs(), lessThan(0.03));
        last = s;
      }
      // Stützpunkte streng geordnet.
      for (var i = 1; i < plan.keys.length; i++) {
        expect(plan.keys[i].p, greaterThan(plan.keys[i - 1].p));
      }
      // Danach wieder hinter dem LKW (keine Extrarunde).
      expect(plan.at(1).orbit % 360, closeTo(0, 1e-9));
    });

    test('Drehung auch mit Fähre begrenzt (≤ 45°/s)', () {
      final run = _run(CinematicCamera(p, plan: _plan(p)));
      for (var i = 1; i < run.length; i++) {
        expect(angleDiff(run[i - 1].$2.bearing, run[i].$2.bearing).abs(), lessThanOrEqualTo(45 * 0.016667 + 1e-6));
      }
    });
  });

  group('Shots auf See', () {
    List<String> sea(List<String> shots) => [
          for (final s in shots)
            if ([shotFerryFollow, shotFerrySide, shotHighDrone].contains(s)) s,
        ];

    test('kurze Fähre: keine Kamerafahrt auf See', () {
      final shots = _shots(_ferryTour(seaKm: 25, roadB: 900));
      expect(sea(shots), [shotFerryFollow]);
      expect(shots, containsAllInOrder([shotToPort, shotFerryFollow, shotToDestPort, 'FOLLOW']));
    });

    test('mittlere Fähre: ein ruhiger Wechsel (seitlich)', () {
      final shots = _shots(_ferryTour(seaKm: 330));
      expect(sea(shots), [shotFerryFollow, shotFerrySide, shotFerryFollow]);
    });

    test('lange Fähre: seitlich, dann hoch, dann wieder folgen', () {
      final shots = _shots(_ferryTour(roadA: 250, seaKm: 900, roadB: 500));
      expect(sea(shots), [shotFerryFollow, shotFerrySide, shotHighDrone, shotFerryFollow]);
    });

    test('Anzahl nach Dauer auf See', () {
      expect(ferrySeaShots(2), 0);
      expect(ferrySeaShots(5), 1);
      expect(ferrySeaShots(12), 2);
    });

    test('1×/2×/4× und Neustart: dieselbe Shot-Folge', () {
      final p = _ferryTour(roadA: 250, seaKm: 900, roadB: 500);
      final one = _shots(p);
      expect(_shots(p, speed: 2), one);
      expect(_shots(p, speed: 4), one);
      final cam = CinematicCamera(p, plan: _plan(p));
      final a = _run(cam);
      cam.reset();
      final b = _run(cam);
      for (var i = 0; i < a.length; i += 61) {
        expect(b[i].$2.bearing, a[i].$2.bearing);
        expect(b[i].$2.zoom, a[i].$2.zoom);
        expect(b[i].$2.shot, a[i].$2.shot);
      }
    });

    test('Fahrzeug unabhängig von der Kamera: nur von der Streckenposition', () {
      final p = _ferryTour();
      final c = ferryCrossings(p);
      for (var m = 0.0; m < p.totalMeters; m += p.totalMeters / 211) {
        final x = vehicleAt(p, c, m), y = vehicleAt(p, c, m);
        expect(x.ship, y.ship);
        expect(x.shipMeters, y.shipMeters);
      }
    });
  });

  group('Tag/Nacht auf der Fähre', () {
    final p = _ferryTour();
    final c = ferryCrossings(p).single;
    final kmA = p.legSpans[0].to / 1000, kmB = (p.legSpans[2].to - p.legSpans[2].from) / 1000;
    final t0 = DateTime.utc(2026, 10, 5, 10);
    final arrivePort = t0.add(const Duration(hours: 4, minutes: 17));
    final depart = DateTime.utc(2026, 10, 5, 18, 30);
    final arrive = DateTime.utc(2026, 10, 6, 4, 30);
    final eta = EtaResult([
      EtaStep('', type: EtaEventType.drive, distanceKm: kmA, start: t0, end: arrivePort),
      EtaStep('', type: EtaEventType.wait, start: arrivePort, end: depart),
      EtaStep('', type: EtaEventType.ferry, start: depart, end: arrive),
      EtaStep('', type: EtaEventType.drive, distanceKm: kmB, start: arrive, end: arrive.add(const Duration(hours: 9))),
    ], null);
    final clock = TourClock.fromEta(eta, p)!;

    test('Überfahrt nach Plan: Abfahrt am Hafen, Ankunft am Zielhafen', () {
      expect(clock.at(c.startMeters), arrivePort); // Ankunft am Hafen
      expect(clock.at(c.startMeters + 1), isA<DateTime>());
      final mid = clock.at(c.startMeters + c.length / 2);
      expect(mid.difference(depart).inMinutes, closeTo(arrive.difference(depart).inMinutes / 2, 2));
      expect(clock.at(c.endMeters), arrive);
      // Danach weiter mit der Fahrt ab dem Zielhafen.
      expect(clock.at(c.endMeters + 1).difference(arrive).inMinutes, lessThan(2));
      expect(clock.at(p.totalMeters), arrive.add(const Duration(hours: 9)));
    });

    test('Tag am Start → Nacht auf See → Morgen danach', () {
      double night(double m) {
        final pt = p.at(m).point;
        return nightLevel(sunElevation(pt.latitude, pt.longitude, clock.at(m)));
      }

      expect(night(0), 0);
      expect(night(c.startMeters + c.length * 0.5), 1);
      expect(night(p.totalMeters), 0);
    });

    test('Tour ohne Fähre: Uhr wie bisher', () {
      final r = _roadTour();
      final km = r.roadMeters / 1000;
      final t = DateTime.utc(2026, 10, 5, 6);
      final e = EtaResult([
        EtaStep('', type: EtaEventType.drive, distanceKm: km / 2, start: t, end: t.add(const Duration(hours: 4))),
        EtaStep('', type: EtaEventType.drive, distanceKm: km / 2,
            start: t.add(const Duration(hours: 5)), end: t.add(const Duration(hours: 9))),
      ], null);
      final cl = TourClock.fromEta(e, r)!;
      expect(cl.at(0), t);
      expect(cl.at(r.totalMeters / 4), t.add(const Duration(hours: 2)));
      expect(cl.at(r.totalMeters / 2), t.add(const Duration(hours: 4)));
      expect(cl.at(r.totalMeters), t.add(const Duration(hours: 9)));
    });
  });

  group('Schiff', () {
    test('Bug spitz, Heck breit, Brücke vorn, Schornstein achtern', () {
      final o = FerryShipModel.hullOutline();
      final bow = o.reduce((a, b) => a.$1 > b.$1 ? a : b);
      expect(bow.$1, FerryShipModel.bowF);
      expect(bow.$2, 0);
      final stern = o.where((x) => x.$1 == FerryShipModel.sternF).toList();
      expect(stern.map((x) => x.$2), containsAll([-FerryShipModel.halfBeam, FerryShipModel.halfBeam]));
      final bridge = FerryShipModel.superstructure.firstWhere((b) => b.name == 'bridge');
      final funnel = FerryShipModel.superstructure.firstWhere((b) => b.name == 'funnel');
      expect(bridge.fromF, greaterThan(0));
      expect(funnel.toF, lessThan(0));
    });

    test('Rumpfseiten zeigen zum Betrachter (fährt weg: Heck sichtbar, kommt entgegen: Bug)', () {
      final away = visibleHullFaces(TruckProjection(pitchDeg: 45, yawDeg: 0));
      expect(away.any((f) => f.stern), isTrue);
      final toward = visibleHullFaces(TruckProjection(pitchDeg: 45, yawDeg: 180));
      expect(toward.any((f) => f.stern), isFalse);
    });

    test('Smartphone-Hochformat: Schiff passt in jedem Shot ins Bild', () {
      // Größter Fähren-Zoom (seitlich +0,85, im Hochformat halbiert), LKW-Größe
      // wie in der Szene (5 · truckScale · 0,62).
      const phoneWidth = 390.0;
      const maxZoom = 0.85 * 0.5;
      /// Breite des projizierten Schiffs (Meter) – mit oder ohne Kielwasser.
      double span(TruckProjection pr, {required bool wake}) {
        final xs = <double>[];
        void see(double f, double r, double z) => xs.add(pr.project(pr.world(f, r, z)).x);
        for (final (f, r) in FerryShipModel.hullOutline()) {
          see(f, r, 0);
        }
        for (final b in FerryShipModel.superstructure) {
          for (final f in [b.fromF, b.toF]) {
            for (final r in [-b.halfWidth, b.halfWidth]) {
              see(f, r, b.toZ);
            }
          }
        }
        if (wake) {
          see(FerryShipModel.sternF - shipWakeLength, -20, 0);
          see(FerryShipModel.sternF - shipWakeLength, 20, 0);
        }
        return xs.reduce(math.max) - xs.reduce(math.min);
      }

      for (final (scale, wake) in [(1.0, true), (1.8, false)]) {
        final ppm = shipPointsPerMeter(5 * scale * 0.62, FerryShipModel.length) * math.pow(2, maxZoom);
        var w = 0.0;
        for (var yaw = 0; yaw < 360; yaw += 4) {
          for (var pitch = 20; pitch <= 60; pitch += 5) {
            w = math.max(w, span(TruckProjection(pitchDeg: pitch.toDouble(), yawDeg: yaw.toDouble()), wake: wake));
          }
        }
        expect(w * ppm, lessThan(phoneWidth * 0.8), reason: 'truckScale $scale');
        // Aber deutlich größer als der LKW (gut sichtbar).
        expect(FerryShipModel.length * ppm / math.pow(2, maxZoom), greaterThan(2 * truckLengthMeters * 5 * scale * 0.62));
      }
    });

    test('Bild deterministisch; nachts dunkler mit Fenstern und Positionslichtern', () async {
      Future<(ui.Image, List<int>)> render(double yaw, double night) async {
        final png = await ferryShipPng(yawDeg: yaw, pitchDeg: 45, night: night);
        final img = (await (await ui.instantiateImageCodec(png)).getNextFrame()).image;
        final data = (await img.toByteData(format: ui.ImageByteFormat.rawStraightRgba))!;
        return (img, data.buffer.asUint8List().toList());
      }

      ({int red, int green, int lit, double lum}) stats(List<int> px) {
        var red = 0, green = 0, lit = 0, n = 0;
        var lum = 0.0;
        for (var i = 0; i < px.length; i += 4) {
          if (px[i + 3] < 200) continue;
          final r = px[i], g = px[i + 1], b = px[i + 2];
          n++;
          lum += (r + g + b) / 3;
          if (r > 200 && g < 110 && b < 110) red++;
          if (g > 150 && r < 120 && b < 150) green++;
          if (r > 220 && g > 190 && b < 170) lit++;
        }
        return (red: red, green: green, lit: lit, lum: lum / n);
      }

      final a = await ferryShipPng(yawDeg: 160, pitchDeg: 45, night: 0);
      expect(await ferryShipPng(yawDeg: 160, pitchDeg: 45, night: 0), a);
      final day = stats((await render(160, 0)).$2);
      final night = stats((await render(160, 1)).$2);
      expect(night.lum, lessThan(day.lum)); // leicht dunkler …
      expect(night.lum, greaterThan(day.lum * 0.6)); // … aber nicht schwarz
      expect(day.red + day.green, 0); // Tag: keine Lichter
      expect(night.red, greaterThan(0)); // Backbord rot
      expect(night.green, greaterThan(0)); // Steuerbord grün
      expect(night.lit, greaterThan(day.lit + 20)); // beleuchtete Fenster
    });
  });

  test('keine Netzaufrufe in den Fähren-Bausteinen', () {
    for (final f in [
      'lib/animation/ferry_cinematic.dart',
      'lib/animation/ship_model.dart',
      'lib/ui/ship_sprites.dart',
    ]) {
      final src = File(f).readAsStringSync();
      expect(src.contains('package:http'), isFalse, reason: f);
      expect(src.contains('Uri.parse'), isFalse, reason: f);
      expect(src.contains('fetch'), isFalse, reason: f);
    }
  });
}
