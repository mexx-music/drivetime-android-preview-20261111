import 'dart:async';
import 'dart:convert';
import 'dart:io' show Directory;
import 'dart:math' as math;

import 'package:driverroute_eta/animation/cinematic_camera.dart' show CameraMode;
import 'package:driverroute_eta/animation/country_borders.dart';
import 'package:driverroute_eta/animation/daylight.dart' show DayNightMode;
import 'package:driverroute_eta/animation/tour_path.dart';
import 'package:driverroute_eta/animation/tour_story.dart';
import 'package:driverroute_eta/export/live_recording/tab_capture.dart' show debugTabCaptureApiOverride;
import 'package:driverroute_eta/logic/eta_calculator.dart';
import 'package:driverroute_eta/main.dart';
import 'package:driverroute_eta/models/tour_draft.dart';
import 'package:driverroute_eta/services/cinematic_session.dart';
import 'package:driverroute_eta/services/maps_proxy.dart';
import 'package:driverroute_eta/services/truck_color_store.dart';
import 'package:driverroute_eta/services/personal_title_store.dart';
import 'package:driverroute_eta/tour/tour_scope.dart';
import 'package:driverroute_eta/ui/map_osm_view.dart';
import 'package:driverroute_eta/ui/tour_animation_scene_maplibre.dart';
import 'package:driverroute_eta/ui/tour_animation_view.dart';
import 'package:driverroute_eta/ui/tour_outro_overlay.dart' show TourOutroOverlay;
import 'package:driverroute_eta/ui/truck_sprites.dart' show TruckView;
import 'package:driverroute_eta/utils/polyline.dart' show decodePolyline;
import 'package:driverroute_eta/ui/tour_story_overlay.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show MethodChannel;
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:latlong2/latlong.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'helpers/fake_directions.dart';
import 'helpers/fake_tab_capture.dart';

/// Ersatz-Proxy: zählt jeden Aufruf; liefert eine Route Lambach → Hamburg.
class _Proxy {
  final List<http.Request> requests = [];
  bool zeroResults = false;

  /// Eigene Routengeometrie (Etappen); [straightOverview]: Googles Übersicht
  /// nur als Gerade Start → Ziel – die Animation darf sie nicht benutzen.
  List<List<double>>? geometry;
  bool straightOverview = false;

  /// Etappen ohne Polyline – dann bleibt nur Googles Übersichtslinie.
  bool noStepPolylines = false;

  int get providerCalls => requests
      .where((r) => const {'/api/directions', '/api/geocode', '/api/autocomplete'}.contains(r.url.path))
      .length;

  http.Response _j(int s, Object? b) =>
      http.Response(jsonEncode(b), s, headers: {'content-type': 'application/json'});

  Future<http.Response> handle(http.Request r) async {
    requests.add(r);
    final p = r.url.path;
    final body = r.body.isEmpty ? <String, Object?>{} : jsonDecode(r.body) as Map<String, Object?>;
    if (p == '/api/geocode') {
      final a = (body['address'] as String? ?? '').toLowerCase();
      final (name, lat, lng) = a.contains('hamburg')
          ? ('Hamburg, Deutschland', 53.55, 9.99)
          : ('Lambach, Österreich', 48.09, 13.87);
      return _j(200, {
        'status': 'OK',
        'results': [
          {'formatted_address': name, 'geometry': {'location': {'lat': lat, 'lng': lng}}}
        ],
      });
    }
    if (p == '/api/autocomplete') return _j(200, {'suggestions': []});
    if (zeroResults) return _j(200, {'status': 'ZERO_RESULTS', 'routes': []});
    final pts = geometry ?? densify([[48.09, 13.87], [49.45, 11.08], [53.55, 9.99]], stepKm: 20);
    final resp = directionsResponse([
      [pts]
    ]);
    final route0 = Map<String, dynamic>.from((resp['routes'] as List).first as Map);
    route0['overview_polyline'] = {
      'points': encodePolyline(straightOverview ? [pts.first, pts.last] : pts)
    };
    if (noStepPolylines) {
      for (final leg in (route0['legs'] as List).cast<Map<String, dynamic>>()) {
        for (final st in (leg['steps'] as List).cast<Map<String, dynamic>>()) {
          st.remove('polyline');
        }
      }
    }
    resp['routes'] = [route0];
    return _j(200, resp);
  }
}

List<LatLng> _line(LatLng a, LatLng b, int n) => [
      for (var i = 0; i < n; i++)
        LatLng(a.latitude + (b.latitude - a.latitude) * i / (n - 1),
            a.longitude + (b.longitude - a.longitude) * i / (n - 1)),
    ];


/// Zwei Testländer: AA westlich, BB östlich von Länge 1,0.
CountryIndex _squares() {
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

  return CountryIndex.fromJson({
    'q': 10000,
    'countries': [
      for (final (iso, name, w, e) in [('AT', 'Österreich', 0.0, 1.0), ('DE', 'Deutschland', 1.0, 2.0)])
        {
          'iso': iso,
          'name': name,
          'polygons': [
            [enc([(w, 0.0), (e, 0.0), (e, 1.0), (w, 1.0)])]
          ],
        }
    ],
  });
}

void main() {
  double progressOf(WidgetTester tester) =>
      tester.widget<LinearProgressIndicator>(find.byKey(const Key('tour-progress'))).value!;
  String kmOf(WidgetTester tester) => tester.widget<Text>(find.byKey(const Key('tour-km'))).data!;

  // ========================================================= Ansicht allein
  group('Animationsansicht', () {
    final path = TourPath([
      TourLeg(points: _line(const LatLng(48.09, 13.87), const LatLng(53.55, 9.99), 2000)),
    ]);
    final total = tourAnimationDuration(path.totalMeters);

    Future<void> pumpView(WidgetTester tester,
        {bool autoplay = true, MapController? controller}) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(1000, 1400);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      await tester.pumpWidget(MaterialApp(
        home: TourAnimationView(
          path: path,
          title: 'Lambach → Hamburg',
          autoplay: autoplay,
          showTiles: false,
          mapController: controller,
        ),
      ));
      await tester.pump();
    }

    testWidgets('Experiment: Standard bleibt 2D (flutter_map), 2.5D nur per Umschalter', (tester) async {
      await pumpView(tester, autoplay: false);
      expect(find.byKey(const Key('renderer-switch')), findsOneWidget);
      expect(find.byType(FlutterMap), findsOneWidget);
      expect(find.text('2.5D (Test)'), findsOneWidget);
    });

    testWidgets('startet bei 0 %, fährt los und endet bei 100 % am Ziel', (tester) async {
      await pumpView(tester);
      expect(find.text('Lambach → Hamburg'), findsOneWidget);
      expect(progressOf(tester), 0);
      expect(kmOf(tester), startsWith('🚛 0 / '));

      await tester.pump(total ~/ 2);
      final mid = progressOf(tester);
      expect(mid, inExclusiveRange(0.2, 0.8));

      await tester.pump(total);
      await tester.pumpAndSettle();
      expect(progressOf(tester), 1);
      final km = (path.roadMeters / 1000).round();
      expect(kmOf(tester), '🚛 $km / $km km');
      expect(find.text('Start'), findsOneWidget); // am Ende wieder startbar
    });

    testWidgets('Pause hält an, Weiter setzt an derselben Stelle fort', (tester) async {
      await pumpView(tester);
      await tester.pump(total ~/ 4);
      await tester.tap(find.text('Pause'));
      await tester.pump();
      final paused = progressOf(tester);
      await tester.pump(const Duration(seconds: 5));
      expect(progressOf(tester), paused);

      await tester.tap(find.text('Weiter'));
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      expect(progressOf(tester), greaterThan(paused));
      await tester.pump(total * 2);
      await tester.pumpAndSettle();
    });

    testWidgets('Neustart beginnt wieder am Start', (tester) async {
      await pumpView(tester);
      await tester.pump(total ~/ 2);
      await tester.tap(find.text('Neustart'));
      await tester.pump();
      expect(progressOf(tester), lessThan(0.05));
      await tester.pump(total * 2);
      await tester.pumpAndSettle();
    });

    testWidgets('ohne Autostart: steht am Start, bis „Start“ gedrückt wird', (tester) async {
      await pumpView(tester, autoplay: false);
      await tester.pump(const Duration(seconds: 3));
      expect(progressOf(tester), 0);
      await tester.tap(find.text('Start'));
      await tester.pump();
      await tester.pump(const Duration(seconds: 2));
      expect(progressOf(tester), greaterThan(0));
      await tester.pump(total * 2);
      await tester.pumpAndSettle();
    });

    group('Zoom', () {
      final auto = tourFollowZoom(path.totalMeters);
      bool autoActive(WidgetTester tester) =>
          tester.widget(find.byKey(const Key('tour-zoom-auto'))) is FilledButton;

      testWidgets('Standard: automatische Kameraführung folgt dem LKW', (tester) async {
        final map = MapController();
        await pumpView(tester, controller: map);
        expect(autoActive(tester), isTrue);
        await tester.pump(total ~/ 3);
        expect(map.camera.zoom, closeTo(auto, 1e-9));
        final pos = path.atFraction(progressOf(tester));
        expect(map.camera.center.latitude, closeTo(pos.point.latitude, 1e-6));
        await tester.pump(total * 2);
        await tester.pumpAndSettle();
      });

      testWidgets('+ / −: Zoom bleibt beim Folgen erhalten, „Auto“ schaltet zurück', (tester) async {
        final map = MapController();
        await pumpView(tester, controller: map);
        await tester.pump(total ~/ 5);
        await tester.tap(find.byTooltip('Näher heran'));
        await tester.pump();
        await tester.tap(find.byTooltip('Näher heran'));
        await tester.pump();
        expect(autoActive(tester), isFalse);
        expect(map.camera.zoom, closeTo(auto + 2, 1e-9));

        // Weiterfahrt: Kamera folgt, Zoom des Nutzers bleibt.
        final before = map.camera.center;
        await tester.pump(total ~/ 5);
        expect(map.camera.zoom, closeTo(auto + 2, 1e-9));
        expect(map.camera.center, isNot(before));
        final pos = path.atFraction(progressOf(tester));
        expect(map.camera.center.latitude, closeTo(pos.point.latitude, 1e-6));

        await tester.tap(find.byTooltip('Weiter weg'));
        await tester.pump();
        expect(map.camera.zoom, closeTo(auto + 1, 1e-9));

        await tester.tap(find.byKey(const Key('tour-zoom-auto')));
        await tester.pump();
        expect(autoActive(tester), isTrue);
        expect(map.camera.zoom, closeTo(auto, 1e-9));
        expect(progressOf(tester), lessThan(1)); // Animation lief weiter
        await tester.pump(total * 2);
        await tester.pumpAndSettle();
      });

      testWidgets('Zoom per Geste (Mausrad) wird übernommen und beim Folgen beibehalten',
          (tester) async {
        final map = MapController();
        await pumpView(tester, controller: map);
        await tester.pump(total ~/ 5);
        final center = tester.getCenter(find.byType(FlutterMap));
        tester.binding.handlePointerEvent(PointerScrollEvent(
            position: center, scrollDelta: const Offset(0, -300)));
        await tester.pump();
        final chosen = map.camera.zoom;
        expect(chosen, greaterThan(auto + 0.1));
        expect(autoActive(tester), isFalse);
        await tester.pump(total ~/ 5);
        expect(map.camera.zoom, closeTo(chosen, 1e-9));
        await tester.pump(total * 2);
        await tester.pumpAndSettle();
      });

      testWidgets('Grenzen: weder zu nah noch zu weit, Knöpfe werden inaktiv', (tester) async {
        final map = MapController();
        await pumpView(tester, autoplay: false, controller: map);
        for (var i = 0; i < 20; i++) {
          final plus = tester.widget<IconButton>(
              find.ancestor(of: find.byIcon(Icons.add), matching: find.byType(IconButton)));
          if (plus.onPressed == null) break;
          await tester.tap(find.byTooltip('Näher heran'));
          await tester.pump();
        }
        expect(map.camera.zoom, tourMaxZoom);
        for (var i = 0; i < 20; i++) {
          final minus = tester.widget<IconButton>(
              find.ancestor(of: find.byIcon(Icons.remove), matching: find.byType(IconButton)));
          if (minus.onPressed == null) break;
          await tester.tap(find.byTooltip('Weiter weg'));
          await tester.pump();
        }
        expect(map.camera.zoom, tourMinZoom);
      });

      testWidgets('Pause, Neustart und Tempo bleiben mit manuellem Zoom unberührt', (tester) async {
        final map = MapController();
        await pumpView(tester, controller: map);
        await tester.tap(find.byTooltip('Näher heran'));
        await tester.pump(total ~/ 4);
        await tester.tap(find.text('Pause'));
        await tester.pump();
        final paused = progressOf(tester);
        await tester.pump(const Duration(seconds: 3));
        expect(progressOf(tester), paused);
        await tester.tap(find.text('2×'));
        await tester.tap(find.text('Neustart'));
        await tester.pump();
        expect(progressOf(tester), lessThan(0.05));
        expect(map.camera.zoom, closeTo(auto + 1, 1e-9)); // Wahl bleibt
        await tester.pump(total);
        await tester.pumpAndSettle();
        expect(progressOf(tester), 1);
      });

      testWidgets('am Ziel: „Auto“ zeigt wieder die ganze Tour', (tester) async {
        final map = MapController();
        await pumpView(tester, controller: map);
        await tester.tap(find.byTooltip('Näher heran'));
        await tester.pump(total * 2);
        await tester.pumpAndSettle();
        expect(map.camera.zoom, closeTo(auto + 1, 1e-9)); // manuell: kein Übersichtssprung
        await tester.tap(find.byKey(const Key('tour-zoom-auto')));
        await tester.pump();
        // Übersicht über die ganze Tour: Mitte zwischen Start und Ziel.
        expect(autoActive(tester), isTrue);
        expect(map.camera.zoom, lessThan(auto + 0.5));
        final midLat = (path.start.latitude + path.end.latitude) / 2;
        expect(map.camera.center.latitude, closeTo(midLat, 0.3));
      });
    });

    testWidgets('Tempo 4× ist schneller als 1×', (tester) async {
      await pumpView(tester, autoplay: false);
      await tester.tap(find.text('4×'));
      await tester.tap(find.text('Start'));
      await tester.pump();
      await tester.pump(total ~/ 8);
      final fast = progressOf(tester);
      await tester.tap(find.text('Neustart'));
      await tester.tap(find.text('1×'));
      await tester.pump();
      await tester.pump(total ~/ 8);
      expect(fast, greaterThan(progressOf(tester)));
      await tester.pump(total * 2);
      await tester.pumpAndSettle();
    });
  });


  // ============================================================== Story
  group('Tour-Story', () {
    setUpAll(() => initializeDateFormatting('de'));

    // ~178 km entlang Breite 0,5; Grenze AT→DE bei Länge 1,0 (Mitte).
    final path = TourPath([
      TourLeg(points: _line(const LatLng(0.5, 0.2), const LatLng(0.5, 1.8), 400)),
    ]);
    final t0 = DateTime(2026, 10, 1, 6, 0);
    // Fahrabschnitte mit Dauer (1 km/min), damit die Fahrzeit bekannt ist.
    EtaStep drive(double km) => EtaStep('',
        type: EtaEventType.drive,
        distanceKm: km,
        start: t0,
        end: t0.add(Duration(minutes: km.round())));
    final eta = EtaResult([
      drive(40),
      EtaStep('', type: EtaEventType.breakTime, start: t0, end: t0.add(const Duration(minutes: 45))),
      drive(60),
      EtaStep('',
          type: EtaEventType.dailyRest,
          start: t0.add(const Duration(hours: 9)),
          end: t0.add(const Duration(hours: 20))),
      drive(78),
      const EtaStep('', type: EtaEventType.destination),
    ], null);

    Future<void> pumpStory(WidgetTester tester,
        {MapController? controller, TourStoryMode mode = TourStoryMode.cinematic}) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(1000, 1400);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      await tester.pumpWidget(MaterialApp(
        home: TourAnimationView(
          path: path,
          title: 'Lambach → Hamburg',
          showTiles: false,
          eta: eta,
          countries: Future.value(_squares()),
          mapController: controller,
          storyMode: mode,
          fromName: 'Lambach',
          toName: 'Hamburg',
        ),
      ));
      await tester.pump(); // Grenzen „geladen“
      await tester.pump();
    }

    /// Fährt in 50-ms-Schritten, bis [key] sichtbar ist; liefert die Zeit.
    Future<Duration> until(WidgetTester tester, String key, {Duration max = const Duration(seconds: 90)}) async {
      var t = Duration.zero;
      while (find.byKey(Key(key)).evaluate().isEmpty) {
        await tester.pump(const Duration(milliseconds: 50));
        t += const Duration(milliseconds: 50);
        if (t > max) fail('$key erscheint nicht');
      }
      return t;
    }

    /// Gefahrene km aus „🚛 40 / 178 km“.
    int kmAt(WidgetTester tester) =>
        int.parse(kmOf(tester).replaceAll('🚛 ', '').split(' / ').first.replaceAll('.', ''));

    /// Deckkraft einer Flagge der Leiste – steckt im Bild (DecorationImage),
    /// nicht in einem Opacity-Widget (siehe Regressionstest unten).
    double stripOpacity(WidgetTester tester, String key) {
      final inner = tester.widget<Container>(
          find.descendant(of: find.byKey(Key(key)), matching: find.byType(Container)).last);
      return (inner.decoration! as BoxDecoration).image!.opacity;
    }

    /// Alle Texte, die gerade sichtbar sind (außer Bedienleiste unten).
    Set<String> texts(WidgetTester tester) => {
          for (final el in find.byType(Text).evaluate())
            if ((el.widget as Text).data != null) (el.widget as Text).data!,
        };

    /// Fährt in 50-ms-Schritten, bis [f] etwas findet; liefert die Zeit.
    Future<Duration> untilFound(WidgetTester tester, Finder f,
        {Duration max = const Duration(seconds: 90)}) async {
      var t = Duration.zero;
      while (f.evaluate().isEmpty) {
        await tester.pump(const Duration(milliseconds: 50));
        t += const Duration(milliseconds: 50);
        if (t > max) fail('$f erscheint nicht');
      }
      return t;
    }

    final border = find.byType(PolygonLayer); // Länderfläche beim Grenzwechsel

    testWidgets('Cinematic: kompakte Fahrleiste, keine Story-Texte, Abschluss am Ziel',
        (tester) async {
      final map = MapController();
      await pumpStory(tester, controller: map);
      final auto = tourFollowZoom(path.totalMeters);
      final hud = find.byKey(const Key('tour-hud'));
      final hudSize = tester.getSize(hud);
      expect(hudSize.height, lessThan(90)); // niedrige Leiste
      // Feste Texte der Ansicht (Bedienung, Kartenhinweis) – sonst nichts.
      final allowed = {
        'Lambach → Hamburg', 'Tour animieren', 'Pause', 'Weiter', 'Start', 'Neustart',
        '1×', '2×', '4×', 'Auto', '© OpenStreetMap-Mitwirkende', "Made with 'flutter_map'",
        '2D', '2.5D (Test)', // Experiment-Umschalter in der Titelleiste
      };

      // Start: Österreich aktuell, Deutschland kommend.
      await tester.pump(const Duration(seconds: 1));
      expect(stripOpacity(tester, 'strip-0-AT'), 1);
      expect(stripOpacity(tester, 'strip-1-DE'), closeTo(0.28, 1e-9));

      // Bis kurz vor dem Ziel: nie ein Story-Text, keine Kamerabewegung,
      // Pause (km 40) und Tagesruhe (km 100) laufen unsichtbar mit.
      var sawBorder = false;
      while (progressOf(tester) < 0.97) {
        await tester.pump(const Duration(milliseconds: 50));
        final shown = texts(tester).where((t) => !t.startsWith('🚛') && !allowed.contains(t));
        expect(shown, isEmpty, reason: 'bei ${kmOf(tester)}');
        expect(find.byIcon(Icons.local_cafe), findsNothing);
        expect(find.byIcon(Icons.bedtime_outlined), findsNothing);
        expect(find.byIcon(Icons.wb_sunny_outlined), findsNothing);
        expect(map.camera.zoom, closeTo(auto, 1e-9));
        expect(tester.getSize(hud), hudSize);
        if (border.evaluate().isNotEmpty && !sawBorder) {
          sawBorder = true;
          expect(kmAt(tester), inInclusiveRange(89, 90)); // an der Grenze
        }
      }
      expect(sawBorder, isTrue);
      expect(stripOpacity(tester, 'strip-0-AT'), closeTo(0.5, 1e-9)); // durchfahren
      expect(stripOpacity(tester, 'strip-1-DE'), 1); // aktuell

      // Ziel: große Abschlussdarstellung ersetzt die Leiste.
      await untilFound(tester, find.byKey(const Key('story-arrival')));
      await tester.pump(const Duration(seconds: 6));
      expect(progressOf(tester), 1);
      final card = find.byKey(const Key('story-arrival'));
      Finder inCard(Finder f) => find.descendant(of: card, matching: f);
      expect(inCard(find.text('TOURÜBERSICHT')), findsOneWidget); // keine Aussage „abgeschlossen“
      expect(inCard(find.text('Lambach')), findsOneWidget);
      expect(inCard(find.text('Hamburg')), findsOneWidget);
      expect(inCard(find.text('178 km')), findsOneWidget);
      expect(inCard(find.text('2:58 h Fahrzeit · 2 Fahrtage')), findsOneWidget);
      expect(inCard(find.text('1 Lenkpause · 1 Tagesruhe')), findsOneWidget);
      expect(find.descendant(of: find.byKey(const Key('arrival-flags')), matching: find.byType(CountryFlag)),
          findsNWidgets(2)); // Länderfolge AT, DE
      expect(
          tester.widget<Opacity>(find.ancestor(of: hud, matching: find.byType(Opacity)).first).opacity,
          0); // Fahrleiste ausgeblendet
      await tester.pump(const Duration(seconds: 10));
      expect(card, findsOneWidget); // bleibt stehen
    });

    testWidgets('Simulation: vollständige Karten wie bisher (unverändert)', (tester) async {
      await pumpStory(tester, mode: TourStoryMode.simulation);

      await until(tester, 'story-break');
      expect(find.text('LENKPAUSE · 45 MIN'), findsOneWidget);
      expect(find.text('40 km gefahren'), findsOneWidget);
      expect(kmAt(tester), inInclusiveRange(40, 41));

      await until(tester, 'story-border');
      expect(find.text('Österreich'), findsOneWidget);
      expect(find.text('DEUTSCHLAND'), findsOneWidget);
      expect(find.byKey(const Key('flag-AT')), findsOneWidget);
      expect(find.byKey(const Key('flag-DE')), findsOneWidget);

      await until(tester, 'story-rest');
      expect(find.text('TAGESRUHE · 11:00 h'), findsOneWidget);
      expect(find.text('Tag 1 · 100 km'), findsOneWidget);
      await until(tester, 'story-next-day');
      expect(find.text('TAG 2'), findsOneWidget);
      expect(find.text('Weiterfahrt 02:00'), findsOneWidget);

      await until(tester, 'story-arrival');
      expect(find.text('ZIEL ERREICHT'), findsOneWidget);
      expect(find.text('178 km'), findsOneWidget);
      await tester.pump(const Duration(seconds: 10));
      await tester.pumpAndSettle();
    });

    testWidgets('Fahrzeug fährt durchgehend (auch an Pause, Grenze und Ruhe)', (tester) async {
      await pumpStory(tester);
      var last = progressOf(tester);
      while (progressOf(tester) < 0.97) {
        await tester.pump(const Duration(milliseconds: 250));
        expect(progressOf(tester), greaterThan(last));
        last = progressOf(tester);
      }
      await tester.pump(const Duration(seconds: 90));
      await tester.pumpAndSettle();
    });

    testWidgets('Länderfläche nur kurz hervorgehoben', (tester) async {
      await pumpStory(tester);
      await untilFound(tester, border);
      await tester.pump(const Duration(milliseconds: 1700));
      expect(border, findsNothing);
      await tester.pump(const Duration(seconds: 90));
      await tester.pumpAndSettle();
    });

    testWidgets('Neustart beginnt wieder im Startland', (tester) async {
      await pumpStory(tester);
      await untilFound(tester, border);
      await tester.tap(find.text('Neustart'));
      await tester.pump();
      expect(progressOf(tester), lessThan(0.05));
      expect(border, findsNothing);
      expect(stripOpacity(tester, 'strip-0-AT'), 1);
      expect(stripOpacity(tester, 'strip-1-DE'), closeTo(0.28, 1e-9));
      await untilFound(tester, border); // Grenze erneut
      await tester.pump(const Duration(seconds: 90));
      await tester.pumpAndSettle();
    });

    testWidgets('4× erreicht Grenze und Ziel schneller als 1×', (tester) async {
      await pumpStory(tester);
      final slow = await untilFound(tester, border);
      await tester.tap(find.text('Neustart'));
      await tester.tap(find.text('4×'));
      await tester.pump();
      final fast = await untilFound(tester, border);
      expect(fast.inMilliseconds, lessThan(slow.inMilliseconds / 3));
      await untilFound(tester, find.byKey(const Key('story-arrival')));
      expect(find.text('1 Lenkpause · 1 Tagesruhe'), findsOneWidget); // gleiche Werte
      await tester.pump(const Duration(seconds: 30));
      await tester.pumpAndSettle();
    });

    testWidgets('Kamera: nur der LKW bestimmt sie; manueller Zoom bleibt fest', (tester) async {
      final map = MapController();
      await pumpStory(tester, controller: map);
      final auto = tourFollowZoom(path.totalMeters);
      await tester.tap(find.byTooltip('Näher heran'));
      await tester.pump();
      while (progressOf(tester) < 0.9) {
        await tester.pump(const Duration(milliseconds: 100));
        expect(map.camera.zoom, closeTo(auto + 1, 1e-9));
      }
      await tester.pump(const Duration(seconds: 30));
      await tester.pumpAndSettle();
    });

    testWidgets('ohne Ländergrenzen (Datei fehlt): Fahrt und Abschluss trotzdem', (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(1000, 1400);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      final load = Completer<CountryIndex>();
      await tester.pumpWidget(MaterialApp(
        home: TourAnimationView(
          path: path,
          title: 'x',
          showTiles: false,
          eta: eta,
          countries: load.future,
        ),
      ));
      load.completeError(StateError('weg'));
      await tester.pump();
      await tester.pump();
      await untilFound(tester, find.byKey(const Key('story-arrival')));
      expect(find.text('1 Lenkpause · 1 Tagesruhe'), findsOneWidget);
      await tester.pump(const Duration(seconds: 10));
      await tester.pumpAndSettle();
    });

    test('Story-Modus: nur das Ziel verlängert die Animation', () {
      final drive = tourAnimationDuration(path.totalMeters);
      final t = TourTimeline(path: path, drive: drive, events: storyFromEta(eta, path));
      final expected = drive + storyTiming(TourStoryKind.arrival).hold;
      expect(t.total.inMicroseconds, closeTo(expected.inMicroseconds, 1000)); // Rundung
    });
  });

  // ============================================================= in der App
  group('in der App', () {
    late _Proxy proxy;

    setUp(() {
      proxy = _Proxy();
      debugMapsDirectCallsAllowed = false;
      debugMapsProxyBase = 'https://proxy.test';
      debugMapsProxyClient = MockClient(proxy.handle);
      SharedPreferences.setMockInitialValues({});
    });

    tearDown(() {
      TourScope.exit();
      debugMapsDirectCallsAllowed = null;
      debugMapsProxyBase = null;
      debugMapsProxyClient = null;
    });

    Finder field(String label) =>
        find.byWidgetPredicate((w) => w is TextField && w.decoration?.labelText == label);
    final animateButton = find.ancestor(
      of: find.text('Tour animieren'),
      matching: find.byWidgetPredicate((w) => w is OutlinedButton),
    );

    Future<void> pumpApp(WidgetTester tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(1280, 1800);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      await tester.pumpWidget(const DriverRouteApp());
      await tester.pumpAndSettle();
      await tester.enterText(field('Start eingeben'), 'Lambach');
      await tester.enterText(field('Ziel eingeben'), 'Hamburg');
      await tester.pump(const Duration(milliseconds: 600));
      await tester.pumpAndSettle();
    }

    Future<void> calculate(WidgetTester tester) async {
      final b = find.text('Route berechnen');
      await tester.ensureVisible(b);
      await tester.tap(b);
      await tester.pumpAndSettle();
    }

    testWidgets('Absicherung: erfolgreiche Berechnung sichert die Tour lokal', (tester) async {
      await pumpApp(tester);
      await calculate(tester);
      final prefs = await SharedPreferences.getInstance();
      final draft = TourDraft.decode(prefs.getString(CinematicSession.draftKey));
      expect(draft, isNotNull);
      expect(draft!.start, contains('Lambach'));
      expect(draft.dest, contains('Hamburg'));
    });

    testWidgets('nach unerwartetem Neuladen: Tour wiederherstellen ohne Provider-Aufruf', (tester) async {
      SharedPreferences.setMockInitialValues({
        CinematicSession.draftKey: TourDraft(
          start: 'Tuzla/Istanbul, Türkei',
          dest: 'Odense, Dänemark',
          startLat: 40.82,
          startLng: 29.30,
          destLat: 55.40,
          destLng: 10.40,
          stops: const ['Sofia, Bulgarien'],
          stopCoords: const [
            [42.70, 23.32]
          ],
          settings: const {'remainingDrivingMin': 480},
          savedAt: DateTime(2026, 10, 4),
        ).encode(),
        CinematicSession.sessionKey: jsonEncode({'km': 3175}),
      });
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(1280, 1800);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      await tester.pumpWidget(const DriverRouteApp());
      await tester.pumpAndSettle();
      expect(find.textContaining('unerwartet neu geladen'), findsOneWidget);
      final before = proxy.providerCalls;
      await tester.tap(find.text('Wiederherstellen'));
      await tester.pumpAndSettle();
      expect(tester.widget<TextField>(field('Start eingeben')).controller!.text, 'Tuzla/Istanbul, Türkei');
      expect(tester.widget<TextField>(field('Ziel eingeben')).controller!.text, 'Odense, Dänemark');
      await tester.ensureVisible(find.text('ZWISCHENSTOPPS'));
      await tester.tap(find.text('ZWISCHENSTOPPS'));
      await tester.pumpAndSettle();
      expect(find.text('1. Sofia, Bulgarien'), findsOneWidget);
      expect(proxy.providerCalls, before); // kein Google-Aufruf
      expect(find.textContaining('unerwartet neu geladen'), findsNothing);
      // Nur einmal angeboten.
      expect((await SharedPreferences.getInstance()).getString(CinematicSession.sessionKey), isNull);
    });

    testWidgets('vor der Berechnung: „Tour animieren“ ist aus', (tester) async {
      await pumpApp(tester);
      expect(tester.widget<OutlinedButton>(animateButton).onPressed, isNull);
    });

    testWidgets('komplette Animation samt Neustart: 0 zusätzliche Provider-Aufrufe', (tester) async {
      await pumpApp(tester);
      await calculate(tester);
      final afterCalc = proxy.requests.length;
      expect(proxy.providerCalls, greaterThan(0));

      // Ländergrenzen vorab real laden (Datei-Lesen braucht echte Zeit);
      // die App bekommt beim Öffnen dieselbe, schon geladene Datei.
      await tester.runAsync(() => CountryIndex.load());

      await tester.ensureVisible(animateButton);
      await tester.tap(animateButton);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 16)); // Seitenübergang
      final view = tester.widget<TourAnimationView>(find.byType(TourAnimationView));
      expect(view.title, 'Lambach → Hamburg');
      expect(view.path.legs.single.kind, TourLegKind.road);
      expect(view.eta, isNotNull); // Planung der Berechnung, nicht neu gerechnet

      // Die (schon geladene) Datei meldet sich in echter Zeit zurück.
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      await tester.pump();
      expect(find.text('Tour wird vorbereitet …'), findsNothing);

      // Bis zum Ziel fahren und dabei mitschreiben, welche Ereignisse kommen.
      final seen = <String>[];
      for (var i = 0; i < 2000 && progressOf(tester) < 1; i++) {
        await tester.pump(const Duration(milliseconds: 100));
        final now = [
          if (find.byType(PolygonLayer).evaluate().isNotEmpty) 'border',
          if (find.byKey(const Key('story-arrival')).evaluate().isNotEmpty) 'story-arrival',
        ];
        for (final k in now) {
          if (seen.isEmpty || seen.last != k) seen.add(k);
        }
      }
      await tester.pump(const Duration(seconds: 5));
      expect(progressOf(tester), 1);
      expect(seen, contains('border')); // Österreich → Deutschland
      expect(seen.last, 'story-arrival');
      expect(find.byType(PolygonLayer), findsNothing); // Hervorhebung vorbei
      expect(find.byKey(const Key('story-arrival')), findsOneWidget); // Ziel bleibt stehen

      await tester.tap(find.text('Neustart'));
      await tester.pump();
      expect(progressOf(tester), lessThan(0.05));
      expect(find.byKey(const Key('story-arrival')), findsNothing);
      await tester.tap(find.text('Pause'));
      await tester.pump();

      await tester.tap(find.byTooltip('Schließen'));
      await tester.pumpAndSettle();
      expect(find.byType(TourAnimationView), findsNothing);
      expect(proxy.requests.length, afterCalc); // weder Maps noch sonst etwas
    });

    testWidgets('Animation folgt der vollständigen Etappen-Geometrie, nicht der Übersichtslinie',
        (tester) async {
      // Umfahrung, Autobahnkreuz (Schleife) und enge Kurvenfolge.
      final geometry = <List<double>>[
        [48.09, 13.87],
        for (var i = 0; i < 12; i++) [48.40 + (i.isOdd ? 0.003 : -0.003), 13.60 - i * 0.004], // Kurven
        [48.70, 13.20],
        for (var k = 0; k <= 16; k++) // Kleeblatt-Schleife, Radius ~400 m
          [49.00 + 0.0036 * math.sin(k * math.pi / 8), 12.50 + 0.0055 * math.cos(k * math.pi / 8)],
        [49.30, 11.40],
        [49.40, 11.20], [49.38, 11.08], [49.42, 10.95], [49.50, 10.98], [49.55, 11.05], // Umfahrung
        [53.55, 9.99],
      ];
      await pumpApp(tester);
      proxy
        ..geometry = geometry
        ..straightOverview = true;
      await calculate(tester);
      await tester.runAsync(() => CountryIndex.load());
      await tester.ensureVisible(animateButton);
      await tester.tap(animateButton);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 16));
      final path = tester.widget<TourAnimationView>(find.byType(TourAnimationView)).path;

      // Genau die Etappen-Punkte (so wie Google sie kodiert liefert).
      final steps = decodePolyline(encodePolyline(densify(geometry)));
      expect(path.points.length, steps.length);
      const d = Distance(calculator: Haversine());
      for (var i = 0; i < steps.length; i += 7) {
        expect(d(path.points[i], steps[i]), lessThan(1.0));
      }
      // Jede Ecke von Kurven, Schleife und Umfahrung liegt auf der Animationslinie.
      for (final g in geometry) {
        final p = LatLng(g[0], g[1]);
        final nearest = path.points.map((q) => d(p, q)).reduce(math.min);
        expect(nearest, lessThan(2.0), reason: '$g');
      }
      // Länge = Etappen-Geometrie, nicht die Luftlinie.
      var len = 0.0;
      for (var i = 1; i < steps.length; i++) {
        len += d(steps[i - 1], steps[i]);
      }
      expect(path.totalMeters, closeTo(len, len * 0.001));
      expect(path.totalMeters, greaterThan(d(steps.first, steps.last) * 1.05));

      // Auch „Karte anzeigen“ zeigt dieselbe vollständige Geometrie.
      await tester.tap(find.byTooltip('Schließen'));
      await tester.pumpAndSettle();
      final mapButton = find.ancestor(
          of: find.text('Karte anzeigen'), matching: find.byWidgetPredicate((w) => w is OutlinedButton));
      await tester.ensureVisible(mapButton);
      await tester.tap(mapButton);
      await tester.pumpAndSettle();
      expect(tester.widget<MapOsmView>(find.byType(MapOsmView)).route.length, steps.length);
      Navigator.of(tester.element(find.byType(MapOsmView))).pop();
      await tester.pumpAndSettle();
    });

    testWidgets('Übersichtslinie nur als Rückfall, wenn Etappen keine Geometrie haben', (tester) async {
      final geometry = <List<double>>[[48.09, 13.87], [48.70, 13.20], [49.40, 11.20], [53.55, 9.99]];
      await pumpApp(tester);
      proxy
        ..geometry = geometry
        ..noStepPolylines = true;
      await calculate(tester);
      await tester.ensureVisible(animateButton);
      await tester.tap(animateButton);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 16));
      final path = tester.widget<TourAnimationView>(find.byType(TourAnimationView)).path;
      // Übersicht (hier = Rohpunkte) statt nichts – und nie eine Luftlinie.
      expect(path.points.length, decodePolyline(encodePolyline(geometry)).length);
      const d = Distance(calculator: Haversine());
      expect(path.totalMeters, greaterThan(d(path.start, path.end) * 1.01));
    });

    testWidgets('„Tour animieren“: 2.5D-Cinematic aus der Planung, 2D als Rückfall', (tester) async {
      await pumpApp(tester);
      await calculate(tester);
      final afterCalc = proxy.requests.length;
      await tester.ensureVisible(animateButton);
      await tester.tap(animateButton);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 16));
      final view = tester.widget<TourAnimationView>(find.byType(TourAnimationView));
      expect(view.startIn25D, isTrue);
      expect(view.cameraMode, CameraMode.cinematic);
      expect(view.truckView, TruckView.articulated);
      expect(view.dayNight, DayNightMode.plan); // Planzeit, keine Demo-Zeit
      expect(view.cinematicDemo, isFalse);
      // Öffentlicher Build: neutraler Lkw, Exportmodus und Hero-Bilder aus,
      // auch wenn die URL sie verlangt (nur im Film-Build DRIVETIME_FILM).
      expect(view.truckModel.branding.id, 'neutral');
      expect(view.videoExport, isFalse);
      expect(view.heroPhoto, isNull);
      expect(view.heroCutout, isNull);
      // Im Test lädt die Vektorkarte nicht (kein Netz): die Ansicht fällt
      // von selbst auf die bisherige 2D-Karte zurück und fährt dort.
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 200)));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 16));
      expect(find.byType(TourAnimationScene), findsOneWidget);
      expect(find.byType(TourAnimationSceneMapLibre), findsNothing);
      await tester.pump(const Duration(seconds: 2));
      expect(progressOf(tester), greaterThan(0));
      // Bis zum Ende: in 2D die bisherige Abschlusskarte, kein Cinematic-Outro.
      for (var i = 0; i < 60 && find.byKey(const Key('story-arrival')).evaluate().isEmpty; i++) {
        await tester.pump(const Duration(seconds: 1));
      }
      expect(find.byKey(const Key('story-arrival')), findsOneWidget);
      expect(find.byType(TourOutroOverlay), findsNothing);
      expect(proxy.requests.length, afterCalc); // kein Provider-Aufruf
      await tester.tap(find.byTooltip('Schließen'));
      await tester.pumpAndSettle();
    });

    testWidgets('„Tour live aufnehmen“: sauberer Film, Filmende, Download, zweiter Versuch – 0 Aufrufe',
        (tester) async {
      final api = FakeTabCaptureApi();
      debugTabCaptureApiOverride = api;
      addTearDown(() => debugTabCaptureApiOverride = null);
      // Mehrere 2D-Rückfälle mit echter Wartezeit: die Kachelablage von
      // flutter_map fragt dann nach einem Cache-Ordner (temporär, gelöscht).
      final cacheDir = Directory.systemTemp.createTempSync('drivetime_tiles_');
      addTearDown(() => cacheDir.deleteSync(recursive: true));
      const pathProvider = MethodChannel('plugins.flutter.io/path_provider');
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(pathProvider, (_) async => cacheDir.path);
      addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(pathProvider, null));
      await pumpApp(tester);
      await calculate(tester);
      final afterCalc = proxy.requests.length;
      await tester.runAsync(() => CountryIndex.load());

      final start = find.byKey(const Key('live-recording-start'));
      await tester.ensureVisible(start);
      await tester.tap(start);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('live-recording-confirm')));
      await tester.pump();
      expect(api.requests, 1);
      expect(find.byType(TourAnimationView), findsNothing); // erst nach Freigabe

      final stream = api.grant();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 16));
      final view = tester.widget<TourAnimationView>(find.byType(TourAnimationView));
      expect(view.cleanRecording, isTrue);
      expect(view.videoExport, isFalse); // normale Filmregie in Echtzeit
      expect(view.startIn25D, isTrue);
      expect(view.cameraMode, CameraMode.cinematic);
      Finder inView(Finder f) => find.descendant(of: find.byType(TourAnimationView), matching: f);
      expect(inView(find.byType(AppBar)), findsNothing);
      expect(inView(find.byKey(const Key('renderer-switch'))), findsNothing);
      expect(inView(find.text('Neustart')), findsNothing);
      expect(inView(find.text('1×')), findsNothing);

      // Vektorkarte lädt im Test nicht → 2D-Rückfall; die Fahrt startet.
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 200)));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 16));
      expect(api.recordersStarted, 1);
      expect(find.byType(TourAnimationView), findsOneWidget);
      expect(find.byTooltip('Näher heran'), findsNothing);

      // Bis zum Filmende – ohne irgendeine Bedienung.
      for (var i = 0; i < 120 && find.byType(TourAnimationView).evaluate().isNotEmpty; i++) {
        await tester.pump(const Duration(seconds: 1));
      }
      await tester.pumpAndSettle();
      expect(find.byType(TourAnimationView), findsNothing); // schließt selbst
      expect(stream.tracksStopped, isTrue);
      expect(stream.recorders.single.stopped, isTrue);
      final download = find.byKey(const Key('live-recording-download'));
      await tester.ensureVisible(download);
      await tester.tap(download);
      expect(api.videos.single.downloads.single, startsWith('drivetime_lambach-hamburg_'));
      expect(api.videos.single.downloads.single, endsWith('.webm'));

      // Zweiter Versuch ohne Neuladen: abgelehnt → keine Animation.
      await tester.ensureVisible(start);
      await tester.tap(start);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('live-recording-confirm')));
      await tester.pump();
      expect(api.requests, 2);
      expect(api.videos.single.released, isTrue);
      api.deny();
      await tester.pumpAndSettle();
      expect(find.byType(TourAnimationView), findsNothing);
      expect(find.textContaining('nicht erteilt'), findsOneWidget);

      // Dritter Versuch: Zurück während der Aufnahme verwirft das Teilvideo.
      await tester.tap(start);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('live-recording-confirm')));
      await tester.pump();
      final stream3 = api.grant();
      await tester.pump();
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 200)));
      await tester.pump();
      await tester.pump(const Duration(seconds: 3));
      expect(api.recordersStarted, 2);
      await tester.binding.handlePopRoute(); // Browser „Zurück“
      await tester.pumpAndSettle();
      expect(find.byType(TourAnimationView), findsNothing);
      expect(stream3.tracksStopped, isTrue);
      expect(stream3.recorders.single.aborted, isTrue);
      expect(api.videos, hasLength(1));
      expect(find.textContaining('verworfen'), findsOneWidget);

      // Normale „Tour animieren“ unverändert mit Bedienelementen.
      await tester.ensureVisible(animateButton);
      await tester.tap(animateButton);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(tester.widget<TourAnimationView>(find.byType(TourAnimationView)).cleanRecording, isFalse);
      expect(find.byTooltip('Schließen'), findsOneWidget);
      await tester.tap(find.byTooltip('Schließen'));
      await tester.pumpAndSettle();

      expect(proxy.requests.length, afterCalc); // kein Routen-/Provider-Aufruf
    });

    testWidgets('Truckfarbe: Blau Standard, Grün gilt für Animation und Live-Aufnahme, bleibt gespeichert',
        (tester) async {
      final api = FakeTabCaptureApi();
      debugTabCaptureApiOverride = api;
      addTearDown(() => debugTabCaptureApiOverride = null);
      await pumpApp(tester);
      final selector = find.byKey(const Key('truck-color'));
      TruckColor selected() => tester.widget<SegmentedButton<TruckColor>>(selector).selected.single;
      expect(selected(), TruckColor.blue); // Standard

      await tester.ensureVisible(selector);
      await tester.tap(find.descendant(of: selector, matching: find.text('Grün')));
      await tester.pumpAndSettle();
      expect(selected(), TruckColor.green);
      await calculate(tester);
      final afterCalc = proxy.requests.length;

      // „Tour animieren“: grüner Truck.
      await tester.ensureVisible(animateButton);
      await tester.tap(animateButton);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 16));
      expect(tester.widget<TourAnimationView>(find.byType(TourAnimationView)).truckModel.branding.id, 'neutral-green');
      await tester.tap(find.byTooltip('Schließen'));
      await tester.pumpAndSettle();

      // Live-Aufnahme: derselbe grüne Truck.
      final start = find.byKey(const Key('live-recording-start'));
      await tester.ensureVisible(start);
      await tester.tap(start);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('live-recording-confirm')));
      await tester.pump();
      api.grant();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 16));
      final live = tester.widget<TourAnimationView>(find.byType(TourAnimationView));
      expect(live.cleanRecording, isTrue);
      expect(live.truckModel.branding.id, 'neutral-green');
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(proxy.requests.length, afterCalc); // Farbwahl ohne Provider-Aufruf

      // Neustart der App: Auswahl wiederhergestellt.
      await tester.pumpWidget(const SizedBox());
      await tester.pumpWidget(const DriverRouteApp());
      await tester.pumpAndSettle();
      expect(selected(), TruckColor.green);
    });

    testWidgets('Persönlicher Titel: Animation und Live-Aufnahme gleich, nicht im Dateinamen, gespeichert, entfernbar',
        (tester) async {
      final api = FakeTabCaptureApi();
      debugTabCaptureApiOverride = api;
      addTearDown(() => debugTabCaptureApiOverride = null);
      final cacheDir = Directory.systemTemp.createTempSync('drivetime_tiles_');
      addTearDown(() => cacheDir.deleteSync(recursive: true));
      const pathProvider = MethodChannel('plugins.flutter.io/path_provider');
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(pathProvider, (_) async => cacheDir.path);
      addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(pathProvider, null));
      await pumpApp(tester);

      final field = find.byKey(const Key('personal-title'));
      TextField input() => tester.widget<TextField>(field);
      expect(input().controller!.text, isEmpty); // Standard leer
      expect(find.text('Titel im Tourvideo (optional)'), findsOneWidget);
      expect(find.text('Zum Beispiel „Manfreds Tour“. Bleibt auf diesem Gerät.'), findsOneWidget);
      expect(find.byKey(const Key('personal-title-clear')), findsNothing);

      await tester.ensureVisible(field);
      await tester.enterText(field, '  Manfreds Tour  ');
      await tester.pump();
      expect(find.byKey(const Key('personal-title-clear')), findsOneWidget);
      await calculate(tester);
      final afterCalc = proxy.requests.length;

      // „Tour animieren“: bereinigter Titel.
      await tester.ensureVisible(animateButton);
      await tester.tap(animateButton);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 16));
      expect(tester.widget<TourAnimationView>(find.byType(TourAnimationView)).personalTitle, 'Manfreds Tour');
      await tester.tap(find.byTooltip('Schließen'));
      await tester.pumpAndSettle();

      // Live-Aufnahme: derselbe Titel; Dateiname ohne Titel.
      final start = find.byKey(const Key('live-recording-start'));
      await tester.ensureVisible(start);
      await tester.tap(start);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('live-recording-confirm')));
      await tester.pump();
      api.grant();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 16));
      final live = tester.widget<TourAnimationView>(find.byType(TourAnimationView));
      expect(live.cleanRecording, isTrue);
      expect(live.personalTitle, 'Manfreds Tour');
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 200)));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 16));
      for (var i = 0; i < 120 && find.byType(TourAnimationView).evaluate().isNotEmpty; i++) {
        await tester.pump(const Duration(seconds: 1));
      }
      await tester.pumpAndSettle();
      final download = find.byKey(const Key('live-recording-download'));
      await tester.ensureVisible(download);
      await tester.tap(download);
      final fileName = api.videos.single.downloads.single;
      expect(fileName, startsWith('drivetime_lambach-hamburg_'));
      expect(fileName.toLowerCase(), isNot(contains('manfred')));
      expect(proxy.requests.length, afterCalc); // Titel ohne Server-/Provider-Aufruf

      // Neustart: Titel wiederhergestellt.
      await tester.pumpWidget(const SizedBox());
      await tester.pumpWidget(const DriverRouteApp());
      await tester.pumpAndSettle();
      expect(input().controller!.text, 'Manfreds Tour');

      // „Titel entfernen“: Feld leer, Speicher leer.
      await tester.ensureVisible(find.byKey(const Key('personal-title-clear')));
      await tester.tap(find.byKey(const Key('personal-title-clear')));
      await tester.pumpAndSettle();
      expect(input().controller!.text, isEmpty);
      expect(await PersonalTitleStore.load(), isNull);
    });

    testWidgets('ohne Streckenführung (manuelle km): Hinweis statt Animation, kein Aufruf',
        (tester) async {
      await pumpApp(tester);
      proxy.zeroResults = true;
      await calculate(tester);
      final afterCalc = proxy.requests.length;
      await tester.ensureVisible(animateButton);
      await tester.tap(animateButton);
      await tester.pump();
      expect(find.byType(TourAnimationView), findsNothing);
      expect(find.textContaining('nicht animieren'), findsOneWidget);
      expect(proxy.requests.length, afterCalc);
      await tester.pump(const Duration(seconds: 5));
      await tester.pumpAndSettle();
    });
  });
}
