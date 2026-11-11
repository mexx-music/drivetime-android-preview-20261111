import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:driverroute_eta/animation/articulation.dart';
import 'package:driverroute_eta/animation/cinematic_camera.dart';
import 'package:driverroute_eta/animation/country_borders.dart';
import 'package:driverroute_eta/animation/ferry_cinematic.dart';
import 'package:driverroute_eta/animation/tour_path.dart';
import 'package:driverroute_eta/logic/ferry_sea_routes.dart';
import 'package:driverroute_eta/models/route_candidate.dart';
import 'package:driverroute_eta/services/map_launcher.dart';
import 'package:driverroute_eta/ui/truck_sprites.dart';
import 'package:driverroute_eta/utils/polyline.dart' show encodePolyline;
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';

import 'helpers/fake_directions.dart' as fake;

const _d = Distance(calculator: Haversine());

double _len(List<LatLng> pts) {
  var m = 0.0;
  for (var i = 1; i < pts.length; i++) {
    m += _d(pts[i - 1], pts[i]);
  }
  return m;
}

void main() {
  final countries = CountryIndex.fromJson(
      jsonDecode(File('assets/geo/countries.json').readAsStringSync()) as Map<String, dynamic>);

  group('Lokale Seewege der bekannten Fähren', () {
    test('jede Verbindung aus ferries.json hat einen Seeweg (beide Richtungen)', () {
      final routes = (jsonDecode(File('assets/fahrplaene/ferries.json').readAsStringSync())['routes'] as List)
          .cast<Map<String, dynamic>>();
      for (final r in routes) {
        final sea = seaRouteBetween(r['from'] as String, r['to'] as String);
        expect(sea, isNotNull, reason: '${r['from']} → ${r['to']}');
        expect(sea!.length, greaterThan(10));
      }
    });

    test('Seeweg schneidet kein bekanntes Land (offene See und Kanäle)', () {
      // Prüfung gegen die Ländergrenzen (Natural Earth 1:10m, auf ~300 m
      // vereinfacht). Enge Fjorde und Hafenbecken löst diese Datei nicht auf;
      // dort gilt die Kartenprüfung (tool/check_ferry_sea_routes.mjs gegen die
      // Wasserflächen der angezeigten Karte, Ergebnis in
      // tool/ferry_sea_routes_check.txt: 0 Landpunkte auf allen 19 Wegen).
      for (final r in ferrySeaRoutes) {
        final pts = densifySeaRoute(r.points, 300);
        final total = _len(pts);
        var along = 0.0, land = 0;
        for (var i = 0; i < pts.length; i++) {
          if (i > 0) along += _d(pts[i - 1], pts[i]);
          if (countries.countryAt(pts[i]) == null) continue;
          land++;
          // Nie auf offener See: höchstens in den Zufahrten (äußere 10 %).
          expect(along < total * 0.1 || along > total * 0.9, isTrue,
              reason: '${r.portA}–${r.portB}: Land bei ${pts[i]}');
        }
        expect(land / pts.length, lessThan(0.03), reason: '${r.portA}–${r.portB}');
      }
    });

    test('Igoumenitsa → Bari: nicht mehr über Korfu', () {
      final corfu = [
        const LatLng(39.62, 19.92), // Korfu-Stadt
        const LatLng(39.75, 19.80),
        const LatLng(39.50, 19.95),
      ];
      final straight = densifySeaRoute([const LatLng(39.4985, 20.2470), const LatLng(41.1450, 16.8750)], 300);
      expect(straight.any((p) => countries.countryAt(p) != null), isTrue); // die alte Gerade über Land
      final sea = seaRouteBetween('Igoumenitsa', 'Bari', stepMeters: 300)!;
      for (final p in sea) {
        expect(countries.countryAt(p), isNull, reason: '$p');
      }
      for (final c in corfu) {
        expect(sea.map((p) => _d(p, c)).reduce(math.min), greaterThan(4000));
      }
    });

    test('Kartenplanung: Seestrecke über den Seeweg, unbekannte Häfen wie bisher', () {
      const igou = LatLng(39.50, 20.26), bari = LatLng(41.13, 16.87);
      final line = ferryLinePoints('Igoumenitsa', 'Bari', igou, bari);
      expect(line.first, igou);
      expect(line.last, bari);
      expect(line.length, greaterThan(100));
      // Unbekanntes Paar bzw. Hafenpunkt weit weg (anderer Hafen): Gerade.
      expect(ferryLinePoints('Nirgendwo', 'Irgendwo', igou, bari), [igou, bari]);
      expect(ferryLinePoints('Igoumenitsa', 'Bari', const LatLng(37.0, 22.0), bari), hasLength(2));
      // Gegenrichtung: derselbe Weg rückwärts.
      final back = ferryLinePoints('Bari', 'Igoumenitsa', bari, igou);
      expect(_len(back), closeTo(_len(line), 1));
    });

    test('Fähre in der Tour: LKW → Fähre → LKW über den Seeweg, ohne Luftlinie', () {
      const igou = LatLng(39.50, 20.26), bari = LatLng(41.13, 16.87);
      final a = densifySeaRoute([const LatLng(40.64, 22.94), igou], 2000);
      final b = densifySeaRoute([bari, const LatLng(44.49, 11.34)], 2000);
      final path = TourPath([
        TourLeg(points: a),
        TourLeg(points: ferryLinePoints('Igoumenitsa', 'Bari', igou, bari), kind: TourLegKind.ferry),
        TourLeg(points: b),
      ]);
      final c = ferryCrossings(path).single;
      // Genau die Länge des Seewegs (nicht die Luftlinie).
      expect(c.length, closeTo(_len(path.legs[1].points), 1));
      expect(path.legs[1].points.length, greaterThan(100));
      for (var m = c.startMeters; m < c.endMeters; m += c.length / 300) {
        final mix = vehicleAt(path, [c], m);
        final p = path.at(mix.shipMeters).point;
        final iso = countries.countryAt(p);
        // Nur die Hafenpunkte selbst liegen an Land.
        if (iso != null) {
          expect(math.min(_d(p, igou), _d(p, bari)), lessThan(3000), reason: '$p');
        }
      }
      expect(vehicleAt(path, [c], c.startMeters - 1e5).ship, 0);
      expect(vehicleAt(path, [c], (c.startMeters + c.endMeters) / 2).ship, 1);
      expect(vehicleAt(path, [c], c.endMeters + 1e5).ship, 0);
    });
  });

  group('Echte Straßengeometrie', () {
    test('Zwischenpunkt (Kartenpunkt) wird tatsächlich durchfahren', () {
      // Linz → Kartenpunkt bei Písek → Prag, zwei Teilstrecken wie bei Google.
      const via = [49.3088, 14.1475];
      final resp = fake.directionsResponse([
        [
          [[48.30, 14.29], [48.97, 14.47], via],
          [via, [49.60, 14.30], [50.08, 14.44]],
        ]
      ]);
      final route = RouteCandidate.fromRouteJson((resp['routes'] as List).first as Map<String, dynamic>);
      final plan = planRouteMap(hasResult: true, encodedPolyline: encodePolyline(route.points));
      final path = TourPath.fromMapPlan(plan)!;
      final wp = LatLng(via[0], via[1]);
      expect(path.points.map((p) => _d(p, wp)).reduce(math.min), lessThan(2));
      // Länger als die Luftlinie Start → Ziel: keine Abkürzung.
      expect(path.totalMeters, greaterThan(_d(path.start, path.end) * 1.05));
      // Die Fahrzeugposition läuft genau über den Punkt.
      var best = double.infinity;
      for (var m = 0.0; m <= path.totalMeters; m += 50) {
        best = math.min(best, _d(path.at(m).point, wp));
      }
      expect(best, lessThan(30));
    });

    test('Stadtumfahrung: Fahrzeug bleibt auf der Umfahrung (nie quer durch)', () {
      // Halbkreis um ein Stadtzentrum (R = 5 km).
      const centre = LatLng(49.45, 11.08);
      final ring = [
        for (var a = 180; a >= 0; a -= 5) destination(centre, 5000, (90 + a).toDouble()),
      ];
      final path = TourPath([TourLeg(points: [destination(centre, 20000, 270), ...ring, destination(centre, 20000, 90)])]);
      for (var m = 0.0; m <= path.totalMeters; m += 100) {
        final pose = articulate(path, m, metersPerUnit: 40);
        expect(_d(pose.frontAxle, centre), greaterThan(4900), reason: 'bei $m m');
      }
    });
  });

  group('Darstellung verändert nichts', () {
    TourPath ferryTour() {
      const igou = LatLng(39.50, 20.26), bari = LatLng(41.13, 16.87);
      return TourPath([
        TourLeg(points: densifySeaRoute([const LatLng(40.64, 22.94), igou], 2000)),
        TourLeg(points: ferryLinePoints('Igoumenitsa', 'Bari', igou, bari), kind: TourLegKind.ferry),
        TourLeg(points: densifySeaRoute([bari, const LatLng(44.49, 11.34)], 2000)),
      ]);
    }

    test('Cinematic-Shots verändern TourPath nicht', () {
      final path = ferryTour();
      final before = [...path.points];
      final total = path.totalMeters;
      final drive = tourAnimationDuration(total);
      final cam = CinematicCamera(path, plan: ferryAwarePlan(CinematicPlan.standard(drive), path, drive));
      for (var i = 0; i <= 2000; i++) {
        cam.step(total * i / 2000, const Duration(milliseconds: 16));
      }
      expect(path.points, before);
      expect(path.totalMeters, total);
      expect(path.at(total / 3).point, TourPath(path.legs).at(total / 3).point);
    });

    test('1×/2×/4× ändern nur das Tempo: gleiche Route, gleiche Pose je Streckenmeter', () {
      final path = ferryTour();
      final total = path.totalMeters;
      final c = ferryCrossings(path);
      // Bei 2× und 4× werden nur Zwischenbilder übersprungen.
      for (final speed in [1, 2, 4]) {
        for (var i = 0; i <= 400; i += speed) {
          final m = total * i / 400;
          final a = articulate(path, m, metersPerUnit: 40);
          final b = articulate(path, m, metersPerUnit: 40);
          expect(a.tractorHeading, b.tractorHeading);
          expect(vehicleAt(path, c, m).ship, vehicleAt(path, c, m).ship);
        }
      }
    });

    test('GARTNER-Testlackierung: Farben nach Referenz, Schriftzug nicht gespiegelt', () {
      const b = TruckBranding.gartnerTest;
      expect(b.livery, isTrue);
      expect(b.cab.g, greaterThan(b.cab.r)); // grüne Zugmaschine
      expect(b.roof!.r, greaterThan(b.roof!.b)); // gelbes Dach
      expect(b.trailer.computeLuminance(), greaterThan(0.85)); // weißer Auflieger
      expect(TruckBranding.neutral.livery, isFalse); // neutral unverändert
    });
  });
}
