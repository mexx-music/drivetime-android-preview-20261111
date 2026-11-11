import 'dart:math' as math;

import 'package:driverroute_eta/animation/tour_path.dart';
import 'package:driverroute_eta/animation/tour_playback.dart';
import 'package:driverroute_eta/logic/ferry_leg_plan.dart';
import 'package:driverroute_eta/services/map_launcher.dart';
import 'package:driverroute_eta/models/ferry_route.dart';
import 'package:driverroute_eta/models/route_candidate.dart';
import 'package:driverroute_eta/ui/tour_animation_view.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';

import 'helpers/fake_directions.dart';

const _hav = Distance(calculator: Haversine());

/// Gerade Linie mit [n] gleichmäßig verteilten Punkten.
List<LatLng> _line(LatLng a, LatLng b, int n) => [
      for (var i = 0; i < n; i++)
        LatLng(a.latitude + (b.latitude - a.latitude) * i / (n - 1),
            a.longitude + (b.longitude - a.longitude) * i / (n - 1)),
    ];

void main() {
  const lambach = LatLng(48.09, 13.87);
  const linz = LatLng(48.31, 14.29);
  const hamburg = LatLng(53.55, 9.99);

  group('Strecke und Interpolation', () {
    test('Start = 0 %, Ziel = 100 %, Mitte liegt auf halber Strecke', () {
      final path = TourPath([TourLeg(points: _line(lambach, linz, 2))]);
      expect(path.totalMeters, closeTo(_hav(lambach, linz), 0.5));
      final s = path.atFraction(0);
      final e = path.atFraction(1);
      expect(s.point, lambach);
      expect(s.meters, 0);
      expect(s.roadMeters, 0);
      expect(e.point, linz);
      expect(e.roadMeters, closeTo(path.roadMeters, 1e-6));
      final m = path.atFraction(0.5);
      expect(m.meters, closeTo(path.totalMeters / 2, 1e-6));
      expect(_hav(lambach, m.point), closeTo(path.totalMeters / 2, 50));
    });

    test('Werte außerhalb 0..1 werden auf Start bzw. Ziel begrenzt', () {
      final path = TourPath([TourLeg(points: _line(lambach, linz, 5))]);
      expect(path.atFraction(-1).point, lambach);
      expect(path.atFraction(2).point, linz);
      expect(path.at(-50).meters, 0);
      expect(path.at(path.totalMeters * 3).meters, path.totalMeters);
    });

    test('ungleiche Punktabstände: Fortschritt nach Strecke, nicht nach Punktnummer', () {
      // 3 Punkte: 1 km, dann fast 100 km. Nach Punktnummer läge die Mitte
      // beim zweiten Punkt (1 km) – nach Strecke bei ~50 km.
      const a = LatLng(0, 0);
      final b = const Distance().offset(a, 1000, 90);
      final c = const Distance().offset(a, 100000, 90);
      final path = TourPath([TourLeg(points: [a, b, c])]);
      final mid = path.atFraction(0.5);
      expect(mid.meters, closeTo(50000, 300));
      expect(_hav(a, mid.point), closeTo(50000, 300));
    });

    test('sehr kurze Route mit nur zwei Punkten', () {
      const a = LatLng(48.09, 13.87);
      final b = const Distance().offset(a, 120, 0);
      final path = TourPath([TourLeg(points: [a, b])]);
      expect(path.totalMeters, closeTo(120, 1));
      expect(path.atFraction(0.25).meters, closeTo(30, 0.5));
      expect(tourAnimationDuration(path.totalMeters), const Duration(milliseconds: 7500));
    });

    test('sehr lange Route mit vielen Punkten: gleichmäßig und monoton', () {
      // Athen → Hamburg mit 40.000 Punkten (etwa 2.000 km).
      final pts = _line(const LatLng(37.98, 23.73), hamburg, 40000);
      final path = TourPath([TourLeg(points: pts)]);
      expect(path.totalMeters / 1000, inInclusiveRange(1900, 2100));
      var last = -1.0;
      for (var i = 0; i <= 200; i++) {
        final p = path.atFraction(i / 200);
        expect(p.meters, greaterThanOrEqualTo(last));
        last = p.meters;
      }
      final d = tourAnimationDuration(path.totalMeters);
      expect(d.inSeconds, inInclusiveRange(25, 36));
    });

    test('Kurve: Fahrtrichtung folgt der Strecke', () {
      // Erst 50 km nach Osten, dann 50 km nach Norden.
      const a = LatLng(48, 14);
      final b = const Distance().offset(a, 50000, 90);
      final c = const Distance().offset(b, 50000, 0);
      final path = TourPath([
        TourLeg(points: [..._line(a, b, 50), ..._line(b, c, 50).skip(1)])
      ]);
      expect(path.atFraction(0.2).bearing, closeTo(90, 2));
      expect(path.atFraction(0.8).bearing, closeTo(0, 2));
    });

    test('Länder übergreifend: Kilometer summieren sich über alle Punkte', () {
      final pts = [lambach, const LatLng(48.57, 13.43), const LatLng(49.45, 11.08), hamburg];
      final path = TourPath([TourLeg(points: pts)]);
      var expected = 0.0;
      for (var i = 1; i < pts.length; i++) {
        expected += _hav(pts[i - 1], pts[i]);
      }
      expect(path.roadMeters, closeTo(expected, 1));
    });
  });

  group('Fähre und Abschnitte', () {
    const igou = LatLng(39.50, 20.26);
    const bari = LatLng(41.13, 16.87);
    final legA = _line(const LatLng(40.64, 22.94), igou, 30); // Thessaloniki → Igoumenitsa
    final legB = _line(bari, const LatLng(41.90, 12.50), 30); // Bari → Rom

    TourPath ferryPath() => TourPath([
          TourLeg(points: legA),
          const TourLeg(points: [igou, bari], kind: TourLegKind.ferry),
          TourLeg(points: legB),
        ]);

    test('Seestrecke zählt nicht als Straßenkilometer', () {
      final path = ferryPath();
      final sea = _hav(igou, bari);
      expect(path.totalMeters - path.roadMeters, closeTo(sea, 1));
    });

    test('auf der Fähre steht der Kilometerzähler still', () {
      final path = ferryPath();
      final legAm = _hav(legA.first, legA.last);
      final onBoard1 = path.at(legAm + 10000);
      final onBoard2 = path.at(legAm + 100000);
      expect(onBoard1.kind, TourLegKind.ferry);
      expect(onBoard2.kind, TourLegKind.ferry);
      expect(onBoard1.roadMeters, closeTo(onBoard2.roadMeters, 1e-6));
      expect(path.at(path.totalMeters - 1000).kind, TourLegKind.road);
    });

    test('Abschnitte ohne gemeinsamen Punkt werden ohne Straßenkilometer verbunden', () {
      final a = _line(lambach, linz, 3);
      final b = _line(const LatLng(48.32, 14.30), hamburg, 3);
      final path = TourPath([TourLeg(points: a), TourLeg(points: b)]);
      final gap = _hav(a.last, b.first);
      expect(path.totalMeters - path.roadMeters, closeTo(gap, 0.5));
    });
  });

  group('aus den Kartendaten der Berechnung', () {
    test('normale Route: berechnete Polyline', () {
      final pts = _line(lambach, hamburg, 100);
      final plan = planRouteMap(hasResult: true, encodedPolyline: _encode(pts));
      final path = TourPath.fromMapPlan(plan)!;
      expect(path.legs.single.kind, TourLegKind.road);
      expect(_hav(path.start, lambach), lessThan(5));
      expect(_hav(path.end, hamburg), lessThan(5));
    });

    test('ohne Streckenführung (nur Marker): keine Animation', () {
      final plan = planRouteMap(hasResult: true, startCoord: lambach, destCoord: hamburg);
      expect(plan.markersOnly, isTrue);
      expect(TourPath.fromMapPlan(plan), isNull);
    });

    test('vor der Berechnung: keine Animation', () {
      expect(TourPath.fromMapPlan(planRouteMap(hasResult: false)), isNull);
    });

    test('Fährroute: Landwege und Seestrecke als eigene Abschnitte', () {
      final plan = planRouteMap(
        hasResult: true,
        ferryLegs: _ferryPlan(),
      );
      final path = TourPath.fromMapPlan(plan)!;
      expect(path.legs.map((l) => l.kind),
          [TourLegKind.road, TourLegKind.ferry, TourLegKind.road]);
    });
  });

  group('gefahrene Strecke zum Zeichnen', () {
    final path = TourPath([TourLeg(points: _line(lambach, hamburg, 5000))]);

    test('am Start leer, am Ziel die ganze Strecke', () {
      expect(path.trailUpTo(0), isEmpty);
      final all = path.trailUpTo(path.totalMeters);
      expect(all.single.points.first, path.start);
      expect(all.single.points.last, path.end);
    });

    test('unterwegs endet die Spur genau beim Fahrzeug', () {
      final pos = path.atFraction(0.37);
      final trail = path.trailUpTo(pos.meters);
      expect(trail.single.points.last, pos.point);
    });

    test('ausgedünnt auf höchstens die verlangte Punktzahl (+ Fahrzeug)', () {
      final trail = path.trailUpTo(path.totalMeters, maxPointsPerLeg: 500);
      expect(trail.single.points.length, lessThanOrEqualTo(502));
    });
  });

  group('Dauer, Zoom, Bewegung', () {
    test('Dauer wächst mit der Strecke, bleibt aber in 7,5–36 s', () {
      final km = [0.1, 20, 100, 500, 1000, 2500, 5000, 100000];
      var last = Duration.zero;
      for (final k in km) {
        final d = tourAnimationDuration(k * 1000);
        expect(d, greaterThanOrEqualTo(last));
        expect(d.inMilliseconds, inInclusiveRange(7500, 36000));
        last = d;
      }
      expect(tourAnimationDuration(2500000).inSeconds, inInclusiveRange(30, 36));
      // Ruhigeres Grundtempo: 20 % langsamer als der erste Entwurf (Dauer × 1,25).
      expect(tourAnimationDuration(899000).inMilliseconds, closeTo(28300, 200)); // Lambach–Hamburg
      expect(tourAnimationDuration(2674000).inMilliseconds, closeTo(33800, 200)); // İpsala–Odense
      expect(tourAnimationDuration(45000).inMilliseconds, closeTo(13800, 200)); // Lambach–Linz
      expect(tourAnimationDuration(1e9), const Duration(seconds: 36)); // Deckel
      expect(tourAnimationDuration(30000).inSeconds, lessThan(15)); // Lambach–Linz
    });

    test('Kamera: kurze Tour nah, lange Tour als Region', () {
      expect(tourFollowZoom(30000), greaterThan(tourFollowZoom(2500000)));
      expect(tourFollowZoom(100), 12.5);
      expect(tourFollowZoom(5000000), 7);
    });

    test('manueller Zoom: Schritte innerhalb der Grenzen', () {
      expect(tourZoomStep(8, 1), 9);
      expect(tourZoomStep(8, -1), 7);
      expect(tourZoomStep(tourMaxZoom, 1), tourMaxZoom);
      expect(tourZoomStep(tourMinZoom, -1), tourMinZoom);
      // Automatische Stufen liegen immer innerhalb der manuellen Grenzen.
      for (final km in [0.1, 30, 1000, 5000]) {
        expect(tourFollowZoom(km * 1000), inInclusiveRange(tourMinZoom, tourMaxZoom));
      }
    });

    test('sanfter Anlauf und Auslauf: 0 → 0, 1 → 1, stetig und monoton', () {
      expect(tourEase(0), 0);
      expect(tourEase(1), closeTo(1, 1e-12));
      var last = 0.0;
      for (var i = 1; i <= 1000; i++) {
        final v = tourEase(i / 1000);
        expect(v, greaterThanOrEqualTo(last));
        expect(v - last, lessThan(0.002)); // keine Sprünge
        last = v;
      }
    });

    test('Fahrzeug-Symbol: nie kopfüber', () {
      expect(truckPose(90), (radians: 0.0, mirrored: false)); // Osten
      final west = truckPose(270);
      expect(west.mirrored, isTrue);
      expect(west.radians, closeTo(0, 1e-9));
      expect(truckPose(0).radians, closeTo(-math.pi / 2, 1e-9)); // Norden: nach oben
      expect(truckPose(0).mirrored, isFalse);
      for (var b = 0; b < 360; b += 5) {
        expect(truckPose(b.toDouble()).radians.abs(), lessThanOrEqualTo(math.pi / 2 + 1e-9));
      }
    });

    test('Kilometeranzeige mit Tausenderpunkt', () {
      expect(tourKmLabel(742400, 1026000), '742 / 1.026 km');
      expect(tourKmLabel(0, 899000), '0 / 899 km');
    });
  });

  group('Ablauf', () {
    test('Start, Pause, Weiter, Ende, Neustart', () {
      final p = TourPlayback(duration: const Duration(seconds: 10));
      expect(p.progress, 0);
      expect(p.playing, isFalse);
      expect(p.tick(const Duration(seconds: 1)), isFalse); // nicht gestartet

      p.play();
      p.tick(const Duration(seconds: 2));
      expect(p.progress, closeTo(0.2, 1e-9));

      p.pause();
      expect(p.tick(const Duration(seconds: 3)), isFalse);
      expect(p.progress, closeTo(0.2, 1e-9));

      p.play(); // weiter, nicht von vorn
      p.tick(const Duration(seconds: 3));
      expect(p.progress, closeTo(0.5, 1e-9));

      p.tick(const Duration(seconds: 60));
      expect(p.progress, 1);
      expect(p.finished, isTrue);
      expect(p.playing, isFalse);

      p.restart();
      expect(p.progress, 0);
      expect(p.playing, isTrue);
    });

    test('Abspielen nach dem Ende beginnt von vorn', () {
      final p = TourPlayback(duration: const Duration(seconds: 4))..play();
      p.tick(const Duration(seconds: 5));
      p.play();
      expect(p.progress, 0);
      expect(p.playing, isTrue);
    });

    test('Tempo 2× und 4×', () {
      final p = TourPlayback(duration: const Duration(seconds: 20))..play();
      p.speed = 2;
      p.tick(const Duration(seconds: 2));
      expect(p.progress, closeTo(0.2, 1e-9));
      p.speed = 4;
      p.tick(const Duration(seconds: 2));
      expect(p.progress, closeTo(0.6, 1e-9));
    });

    test('Bild für Bild mit festem Takt (z. B. späterer Export) ist reproduzierbar', () {
      List<double> frames() {
        final p = TourPlayback(duration: const Duration(seconds: 3))..play();
        return [
          for (var i = 0; i < 90; i++) (p..tick(const Duration(microseconds: 33333))).progress,
        ];
      }

      expect(frames(), frames());
    });
  });
}

String _encode(List<LatLng> pts) =>
    encodePolyline([for (final p in pts) [p.latitude, p.longitude]]);

RouteCandidate _leg(List<LatLng> pts) => RouteCandidate(
      km: 0, sec: 0, steps: const [], warnings: const [], legPoints: [pts], raw: const {});

FerryLegPlan _ferryPlan() => FerryLegPlan(
      ferry: FerryRoute(
        id: 'igou-bari',
        name: 'Igoumenitsa–Bari',
        from: 'Igoumenitsa',
        to: 'Bari',
        operators: const ['Example'],
        durationHours: 10,
        departuresLocal: const ['12:00'],
        tz: 'Europe/Athens',
        region: 'Griechenland/Italien',
        active: true,
        notes: '',
      ),
      legA: _leg(_line(const LatLng(40.64, 22.94), const LatLng(39.50, 20.26), 20)),
      legB: _leg(_line(const LatLng(41.13, 16.87), const LatLng(41.90, 12.50), 20)),
    );
