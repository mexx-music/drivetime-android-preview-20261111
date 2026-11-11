import 'dart:math' as math;

import 'package:driverroute_eta/animation/articulation.dart';
import 'package:driverroute_eta/animation/cinematic_camera.dart';
import 'package:driverroute_eta/animation/country_borders.dart';
import 'package:driverroute_eta/animation/tour_camera.dart';
import 'package:driverroute_eta/animation/tour_outro.dart';
import 'package:driverroute_eta/animation/tour_path.dart';
import 'package:driverroute_eta/animation/tour_playback.dart';
import 'package:driverroute_eta/animation/tour_story.dart';
import 'package:driverroute_eta/ui/tour_outro_overlay.dart';
import 'package:driverroute_eta/ui/truck_sprites.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:latlong2/latlong.dart';

const _d = Distance(calculator: Haversine());

/// Testländer als Streifen: AT (Länge 0–1), DE (1–2), wieder AT (2–3).
CountryIndex _stripes() {
  List<int> enc(List<(double, double)> pts) {
    final out = <int>[];
    var lx = 0, ly = 0;
    for (final (x, y) in pts) {
      final qx = (x * 10000).round(), qy = (y * 10000).round();
      out
        ..add(qx - lx)
        ..add(qy - ly);
      lx = qx;
      ly = qy;
    }
    return out;
  }

  Map<String, Object> c(String iso, String name, List<(double, double)> xs) => {
        'iso': iso,
        'name': name,
        'polygons': [
          for (final (w, e) in xs)
            [enc([(w, 0.0), (e, 0.0), (e, 1.0), (w, 1.0)])]
        ],
      };
  return CountryIndex.fromJson({
    'q': 10000,
    'countries': [
      c('AT', 'Österreich', [(0.0, 1.0), (2.0, 3.0)]),
      c('DE', 'Deutschland', [(1.0, 2.0)]),
    ],
  });
}

OutroData _data(int n, {int ferries = 0}) => OutroData(
      from: 'İpsala',
      to: 'Odense',
      km: 2683.4,
      days: 4,
      ferries: ferries,
      countries: [for (var i = 0; i < n; i++) OutroCountry(['TR', 'GR', 'BG', 'RS', 'HU', 'AT', 'DE', 'DK'][i % 8], 'Land ${i + 1}')],
    );

CameraState _start() => const CameraState(
      target: LatLng(55.40, 10.39),
      bearing: 12,
      pitch: 42,
      zoom: 8.1,
      shot: 'FOLLOW',
      orbit: 0,
    );

OutroCamera _cam({double width = 390, double height = 700, int countries = 8}) => OutroCamera(
      from: _start(),
      truck: const LatLng(55.38, 10.38),
      heading: 20,
      followZoom: 7.6,
      truckPointsPerMeter: 3.1,
      width: width,
      height: height,
      timeline: OutroTimeline(countryCount: countries),
    );

void main() {
  setUpAll(() => initializeDateFormatting('de'));

  group('Zeitplan und Marker', () {
    test('Reihenfolge der Musikmarker, 8–12 s, ≥ 2 s ruhiges Schlussbild', () {
      for (final n in [1, 3, 8, 14, 25]) {
        final tl = OutroTimeline(countryCount: n);
        final m = tl.markers.values.toList();
        for (var i = 1; i < m.length; i++) {
          // Tourdaten dürfen schon während der letzten Länder beginnen.
          final slack = tl.markers.keys.elementAt(i) == 'statsReveal' ? 0.4 + 1e-9 : 0;
          expect(m[i], greaterThanOrEqualTo(m[i - 1] - slack), reason: '${tl.markers}');
        }
        expect(tl.end, inInclusiveRange(8.0, 12.0), reason: 'n=$n');
        // Nach dem Logo bewegt sich nichts mehr (Einblendungen fertig).
        expect(tl.end - tl.finalLogo, greaterThanOrEqualTo(2.0 - 1e-9));
        final still = tl.finalLogo + 0.9;
        expect(tl.country(n - 1, still), 1);
        expect(tl.stats(still), 1);
        expect(tl.logo(still), 1);
        expect(tl.markers.keys, [
          'arrival', 'heroReveal', 'lightsOn', 'countriesStart', 'countriesComplete', 'statsReveal', 'finalLogo', 'end'
        ]);
      }
    });

    test('Länder nacheinander, 0,18–0,42 s Abstand, in Reihenfolge', () {
      final tl = OutroTimeline(countryCount: 8);
      expect(tl.countryStep, inInclusiveRange(0.3, 0.5)); // Richtwert für normale Touren
      for (var i = 1; i < 8; i++) {
        // Ein späteres Land ist nie weiter als ein früheres.
        for (var t = 0.0; t < tl.end; t += 0.05) {
          expect(tl.country(i, t), lessThanOrEqualTo(tl.country(i - 1, t)));
        }
      }
      expect(OutroTimeline(countryCount: 30).countryStep, 0.18);
    });

    test('Outro beginnt erst, wenn das Fahrzeug das Ziel erreicht', () {
      final pts = <LatLng>[const LatLng(48, 14)];
      for (var i = 0; i < 300; i++) {
        pts.add(destination(pts.last, 1000, 0));
      }
      final path = TourPath([TourLeg(points: pts)]);
      final tl = TourTimeline(
        path: path,
        drive: tourAnimationDuration(path.totalMeters),
        events: [TourStoryEvent(kind: TourStoryKind.arrival, meters: path.totalMeters, km: 300)],
      );
      final at = tl.arrivalAt;
      expect(tl.frameAt(at - const Duration(milliseconds: 100)).meters, lessThan(path.totalMeters));
      expect(tl.frameAt(at).meters, closeTo(path.totalMeters, 1));
      expect(at, lessThan(tl.total)); // bisherige Ankunftsphase folgt danach
    });

    test('Wiedergabe mit Outro verlängert: Stand, Tempo und Abspielen bleiben', () {
      final p = TourPlayback(duration: const Duration(seconds: 30))
        ..speed = 4
        ..play()
        ..tick(const Duration(seconds: 2));
      final q = p.withDuration(const Duration(seconds: 40));
      expect(q.elapsed, p.elapsed);
      expect(q.speed, 4);
      expect(q.playing, isTrue);
      expect(p.withDuration(const Duration(seconds: 5)).finished, isTrue);
    });
  });

  group('Kamera', () {
    test('beginnt exakt im letzten Zustand der Fahrt – kein Sprung', () {
      final c = _cam();
      final s = c.at(0);
      final f = _start();
      expect(s.bearing, closeTo(f.bearing, 1e-9));
      expect(s.zoom, closeTo(f.zoom, 1e-9));
      expect(s.pitch, closeTo(f.pitch, 1e-9));
      expect(_d(s.target, f.target), lessThan(0.01));
    });

    test('stetig: keine Sprünge in Richtung, Zoom, Neigung, Blickpunkt', () {
      final c = _cam();
      var last = c.at(0);
      for (var i = 1; i <= 1200; i++) {
        final s = c.at(i / 100); // 100 Bilder/s
        expect(angleDiff(last.bearing, s.bearing).abs(), lessThan(1.2), reason: 't=${i / 100}');
        expect((s.zoom - last.zoom).abs(), lessThan(0.03));
        expect((s.pitch - last.pitch).abs(), lessThan(0.3));
        expect(_d(s.target, last.target), lessThan(400));
        last = s;
      }
    });

    test('Hero: 3/4 von vorn links, näher (Zoom) statt größer, ruhig am Schluss', () {
      final c = _cam();
      final tl = c.timeline;
      final hero = c.at(tl.finalLogo);
      // Kamera blickt entgegen der Fahrtrichtung, schräg (Front + Seite).
      expect(angleDiff(hero.bearing, c.heading).abs(), inInclusiveRange(130, 170));
      expect(hero.zoom, greaterThan(_start().zoom + 1.2));
      expect(hero.pitch, closeTo(OutroCamera.heroPitch, 0.5));
      final end = c.at(tl.end), late = c.at(tl.end - 2.0);
      expect(angleDiff(late.bearing, end.bearing).abs(), lessThan(0.05));
      expect((late.zoom - end.zoom).abs(), lessThan(0.002));
    });

    test('Truck passt ins Bild (9:16 und Desktop)', () {
      for (final (w, h) in [(390.0, 700.0), (1080.0, 1920.0), (1280.0, 800.0)]) {
        final c = _cam(width: w, height: h);
        final s = c.at(c.timeline.end);
        // Truck-Länge auf dem Bildschirm = Folge-Größe × 2^(Zoom − Folge-Zoom).
        final len = 16.8 * c.truckPointsPerMeter * math.pow(2, s.zoom - c.followZoom);
        final comp = outroComposition(portrait: w < h);
        expect(len, lessThanOrEqualTo(math.min(comp.length * w, 0.5 * h) + 1));
        // Mitte des Trucks plus halbe Länge bleibt im Bild.
        expect(comp.x * w + len / 2, lessThanOrEqualTo(w));
        expect(comp.x * w - len / 2, greaterThanOrEqualTo(0));
      }
    });

    test('deterministisch: gleiche Zeit → gleicher Zustand, unabhängig vom Takt', () {
      final a = _cam(), b = _cam();
      for (var t = 0.0; t <= a.timeline.end; t += 0.25) {
        // b vorher mit anderem Takt „abgespielt“ – ohne Einfluss.
        for (var k = 0; k < 7; k++) {
          b.at(t * k / 7);
        }
        final x = a.at(t), y = b.at(t);
        expect(y.bearing, x.bearing);
        expect(y.zoom, x.zoom);
        expect(y.target, x.target);
      }
    });
  });

  group('Licht-Reveal', () {
    test('Rücklichter → Scheinwerfer → Lichtlauf, weich und deterministisch', () {
      final tl = OutroTimeline(countryCount: 8);
      expect(OutroLights.at(tl, 0).key, OutroLights.at(tl, 0).key);
      var tail = 0.0, head = 0.0;
      for (var t = 0.0; t <= tl.end; t += 1 / 30) {
        final l = OutroLights.at(tl, t);
        expect(l.tail, greaterThanOrEqualTo(tail));
        expect(l.head, greaterThanOrEqualTo(head));
        expect(l.tail - tail, lessThanOrEqualTo(0.25)); // höchstens eine Viertelstufe je Bild
        tail = l.tail;
        head = l.head;
        if (l.head > 0) expect(l.tail, greaterThan(0)); // Rücklichter zuerst
      }
      expect(OutroLights.at(tl, tl.lightsOn - 0.1).tail, 0); // vorher aus
      expect(tl.sweep(tl.lightsOn + 1.5), isNotNull);
      expect(tl.sweep(tl.end), isNull); // Schlussbild ohne Lichtlauf
      // Wenige Zustände: das Reveal braucht nur wenige große Bilder.
      final keys = {for (var t = 0.0; t <= tl.end; t += 1 / 60) OutroLights.at(tl, t).key};
      expect(keys.length, lessThan(20)); // wenige große Bilder
      // Performance-Vorschau: Lichtkegel in 4 statt 8 Stufen – weniger Bilder,
      // gleiche Ein-/Ausschaltpunkte.
      final coarse = {for (var t = 0.0; t <= tl.end; t += 1 / 60) OutroLights.at(tl, t, sweepSteps: 4).key};
      expect(coarse.length, lessThan(keys.length));
      expect(OutroLights.at(tl, tl.lightsOn - 0.1, sweepSteps: 4).tail, 0);
      expect(OutroLights.at(tl, tl.end, sweepSteps: 4).key, OutroLights.at(tl, tl.end).key);
    });

    test('Outro-Truck = derselbe Truck wie während der Fahrt (nur Licht dazu)', () async {
      const model = TruckModel(trailer: TrailerKind.reefer, branding: TruckBranding.gartnerTest);
      Future<List<int>> png({double? tail, double? head, double? sweep}) => truckArticulatedPng(model,
          tractorYaw: 150, knick: 0, pitchDeg: 55, pxPerMeter: 12, tailLights: tail, headLights: head, sweep: sweep);
      final drive = await png();
      expect(await png(tail: 0, head: 0), drive); // Licht aus = Fahrbild
      expect(await png(tail: 1, head: 1), isNot(drive)); // Licht an
      expect(await png(tail: 1, head: 1, sweep: 0.5), await png(tail: 1, head: 1, sweep: 0.5));
      // Neutrales Modell funktioniert genauso – nichts ist auf GARTNER verdrahtet.
      expect(
          await truckArticulatedPng(const TruckModel(), tractorYaw: 150, knick: 0, pitchDeg: 55, pxPerMeter: 12, tailLights: 1, headLights: 1),
          isNotEmpty);
    });
  });

  group('Daten aus der Tour', () {
    test('Länder aus den Grenzen in echter Reihenfolge (AT → DE → AT bleibt)', () {
      final index = _stripes();
      final pts = [for (var i = 0; i <= 120; i++) LatLng(0.5, 0.05 + i * 0.024)];
      final path = TourPath([TourLeg(points: pts)]);
      final events = storyFromBorders(detectBorderCrossings(path, index), index, path, path.roadMeters / 1000);
      final data = buildOutroData(path: path, events: events, countries: index, fromName: 'A', toName: 'B');
      expect([for (final c in data.countries) c.iso], ['AT', 'DE', 'AT']);
      expect([for (final c in data.countries) c.name], ['Österreich', 'Deutschland', 'Österreich']);
      expect(data.distinctCountries, 2); // „2 LÄNDER“, Liste zeigt die Reise
      expect(data.ferries, 0);
      expect(data.km, closeTo(path.roadMeters / 1000, 1e-6));
    });

    test('Kilometer und Fahrtage aus der Planung, Fähren aus der Linie', () {
      final path = TourPath([
        const TourLeg(points: [LatLng(39.5, 20.2), LatLng(39.6, 20.0)]),
        const TourLeg(points: [LatLng(39.6, 20.0), LatLng(41.1, 16.9)], kind: TourLegKind.ferry),
        const TourLeg(points: [LatLng(41.1, 16.9), LatLng(41.5, 15.5)]),
      ]);
      const summary = TourSummary(
          km: 812, driving: Duration(hours: 11), days: 3, breaks: 2, dailyRests: 2, weeklyRests: 0);
      final data = buildOutroData(path: path, events: const [], summary: summary, planKm: 812, fromName: 'X', toName: 'Y');
      expect(data.km, 812);
      expect(data.days, 3);
      expect(data.ferries, 1);
      expect(data.countries, isEmpty); // ohne Grenzdaten keine erfundenen Länder
    });
  });

  group('Einblendungen', () {
    Future<void> pump(WidgetTester tester, Size size, OutroData data, double t) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = size;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: TourOutroOverlay(data: data, timeline: OutroTimeline(countryCount: data.countries.length), t: t),
        ),
      ));
    }

    testWidgets('Tourdaten stimmen (auch Fähre), Signatur am Schluss', (tester) async {
      final data = _data(8, ferries: 1);
      await pump(tester, const Size(390, 700), data, 30);
      expect(find.text('2.683'), findsOneWidget);
      expect((tester.widget<Text>(find.byKey(const Key('outro-days')))).data, '4');
      expect((tester.widget<Text>(find.byKey(const Key('outro-countries')))).data, '${data.distinctCountries}');
      expect((tester.widget<Text>(find.byKey(const Key('outro-ferries')))).data, '1');
      expect(find.text('FÄHRE'), findsOneWidget);
      expect(find.text('İPSALA'), findsOneWidget);
      expect(find.text('ODENSE'), findsOneWidget);
      expect(find.byKey(const Key('outro-signature')), findsOneWidget);
      // Ohne Fähre keine Fährzeile.
      await pump(tester, const Size(390, 700), _data(8), 30);
      expect(find.byKey(const Key('outro-ferries')), findsNothing);
    });

    testWidgets('vor den Ländern ist die Liste unsichtbar, danach vollständig', (tester) async {
      final data = _data(8);
      final tl = OutroTimeline(countryCount: 8);
      double op(int i) => tester
          .widget<Opacity>(find.ancestor(of: find.byKey(Key('outro-country-$i')), matching: find.byType(Opacity)).first)
          .opacity;
      await pump(tester, const Size(390, 700), data, tl.countriesStart - 0.1);
      expect(op(0), 0);
      await pump(tester, const Size(390, 700), data, tl.countriesStart + 1.1 * tl.countryStep);
      expect(op(0), greaterThan(op(2)));
      await pump(tester, const Size(390, 700), data, tl.countriesComplete);
      for (var i = 0; i < 8; i++) {
        expect(op(i), 1);
      }
    });

    for (final (w, h) in [(360.0, 640.0), (390.0, 700.0), (1080.0, 1920.0), (1280.0, 760.0)]) {
      testWidgets('viele Länder (24) passen auf ${w.toInt()}×${h.toInt()}, lesbar, ohne Überlauf', (tester) async {
        final data = _data(24, ferries: 2);
        await pump(tester, Size(w, h), data, 30);
        expect(tester.takeException(), isNull);
        final stats = tester.getRect(find.byKey(const Key('outro-route')));
        final title = tester.getRect(find.byKey(const Key('outro-title')));
        for (var i = 0; i < 24; i++) {
          final r = tester.getRect(find.byKey(Key('outro-country-$i')));
          expect(r.left, greaterThanOrEqualTo(0));
          expect(r.right, lessThanOrEqualTo(w));
          expect(r.bottom, lessThanOrEqualTo(stats.top), reason: 'Land $i über den Tourdaten');
          expect(r.top, greaterThanOrEqualTo(title.bottom), reason: 'Land $i unter dem Titel');
          expect(r.height, greaterThanOrEqualTo(14));
        }
        final lay = TourOutroOverlay.countryLayout(24, h * 0.36, h);
        expect(lay.font, greaterThanOrEqualTo(11));
      });
    }

    testWidgets('gleiche Zeit → gleiches Bild (deterministisch, 1×/2×/4× egal)', (tester) async {
      final data = _data(8);
      final tl = OutroTimeline(countryCount: 8);
      List<double> opacities() => [
            for (final o in tester.widgetList<Opacity>(find.byType(Opacity))) o.opacity,
          ];
      for (final t in [0.0, 2.0, 4.2, 6.6, tl.end]) {
        await pump(tester, const Size(390, 700), data, t);
        final a = opacities();
        // „Anders abgespielt“: andere Zwischenzeiten vorher.
        await pump(tester, const Size(390, 700), data, t / 2);
        await pump(tester, const Size(390, 700), data, t / 4);
        await pump(tester, const Size(390, 700), data, t);
        expect(opacities(), a);
      }
    });
  });

  group('Reise-Übersicht vor dem Hero', () {
    OutroCamera cam({double overview = 4.4}) => OutroCamera(
          from: _start(),
          truck: const LatLng(55.38, 10.38),
          heading: 20,
          followZoom: 7.6,
          truckPointsPerMeter: 3.1,
          width: 390,
          height: 700,
          timeline: OutroTimeline(countryCount: 8, overview: overview),
          routeSouthWest: const LatLng(40.9, 9.9),
          routeNorthEast: const LatLng(55.4, 26.4),
        );

    test('steigt auf, ganze Route im Bild, dann weiter zum Hero – ohne Sprung', () {
      final c = cam();
      final tl = c.timeline;
      final ov = c.at(2.6);
      expect(ov.shot, 'OVERVIEW');
      expect(ov.zoom, lessThan(_start().zoom - 2)); // deutlich weiter weg
      expect(ov.target.latitude, closeTo((40.9 + 55.4) / 2, 0.5));
      // Ganze Route passt: Breite in Metern ≤ 80 % der Bildbreite.
      final mpp = metersPerScreenPoint(ov.zoom, ov.target.latitude);
      const d = Distance(calculator: Haversine());
      expect(d(const LatLng(48.15, 9.9), const LatLng(48.15, 26.4)) / mpp, lessThanOrEqualTo(390 * 0.8 + 1));
      // Stetig über die ganze Zeit.
      var last = c.at(0);
      for (var i = 1; i <= tl.end * 100; i++) {
        final s = c.at(i / 100);
        expect((s.zoom - last.zoom).abs(), lessThan(0.08), reason: 't=${i / 100}');
        expect(angleDiff(last.bearing, s.bearing).abs(), lessThan(1.5));
        last = s;
      }
      // Am Ende der Hero wie bisher.
      expect(angleDiff(c.at(tl.end).bearing, c.heroBearing).abs(), lessThan(8));
    });

    test('Strecke leuchtet einmal auf, Hero und Länder verschieben sich nach hinten', () {
      final tl = OutroTimeline(countryCount: 8, overview: 4.4), plain = OutroTimeline(countryCount: 8);
      expect(tl.routeGlow(0), 0);
      expect(tl.routeGlow(3.0), greaterThan(0.5));
      expect(tl.routeGlow(tl.heroReveal), 0);
      expect(plain.routeGlow(3.0), 0);
      expect(tl.heroReveal, plain.heroReveal + 4.4);
      expect(tl.countriesStart, plain.countriesStart + 4.4);
      expect(tl.end - plain.end, closeTo(4.4, 1e-9));
      expect(tl.markers.keys, containsAllInOrder(['arrival', 'routeOverview', 'routeGlow', 'heroReveal', 'end']));
    });
  });
}
