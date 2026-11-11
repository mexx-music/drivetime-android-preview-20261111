import 'dart:convert';

import 'package:driverroute_eta/account/account_service.dart';
import 'package:driverroute_eta/auth/auth_service.dart';
import 'package:driverroute_eta/main.dart';
import 'package:driverroute_eta/services/map_launcher.dart' as map_launcher;
import 'package:driverroute_eta/services/maps_proxy.dart';
import 'package:driverroute_eta/tour/tour_scope.dart';
import 'package:driverroute_eta/tour/tour_service.dart';
import 'package:driverroute_eta/ui/map_osm_view.dart';
import 'package:driverroute_eta/ui/map_point_picker.dart';
import 'package:driverroute_eta/animation/country_borders.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:latlong2/latlong.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'helpers/fake_directions.dart';

const _alice = AuthUser(id: '6f1c9a3e-2b7d-4e8a-9c1f-0a2b3c4d5e6f', email: 'alice@example.com');

class _Auth implements AuthService {
  _Auth(this._u);
  final ValueNotifier<AuthUser?> _u;
  @override
  bool get enabled => true;
  @override
  ValueListenable<AuthUser?> get user => _u;
  @override
  String? get accessToken => _u.value == null ? null : 'tok';
  @override
  Future<void> signOut() async => _u.value = null;
  @override
  Future<void> requestCode(String email, {String? captchaToken}) async {}
  @override
  Future<void> verifyCode(String email, String code) async {}
}

/// Ersatz-Proxy: zählt jeden Directions-Aufruf; Touren wie der echte Proxy.
class _Proxy {
  final List<http.Request> requests = [];
  bool zeroResults = false;
  ({int status, Object? body})? reserve;
  final Map<String, String> state = {};
  int _n = 0;

  int get directions => requests.where((r) => r.url.path == '/api/directions').length;
  int get providerCalls => requests
      .where((r) => const {'/api/directions', '/api/geocode', '/api/autocomplete'}.contains(r.url.path))
      .length;

  http.Response _j(int s, Object? b) =>
      http.Response(jsonEncode(b), s, headers: {'content-type': 'application/json'});

  Future<http.Response> handle(http.Request r) async {
    requests.add(r);
    final p = r.url.path;
    final body = r.body.isEmpty ? <String, Object?>{} : jsonDecode(r.body) as Map<String, Object?>;
    if (p == '/api/tours') {
      if (reserve != null) return _j(reserve!.status, reserve!.body);
      final id = '00000000-0000-4000-8000-${(++_n).toString().padLeft(12, '0')}';
      state[id] = 'reserved';
      return _j(201, {
        'tour_id': id, 'state': 'reserved', 'call_budget': 20, 'calls_used': 0, 'completed': false,
        'expires_at': DateTime.now().add(const Duration(minutes: 10)).toUtc().toIso8601String(),
      });
    }
    final m = RegExp(r'^/api/tours/([0-9a-f-]+)/(complete|release)$').firstMatch(p);
    if (m != null) {
      final s = state[m.group(1)];
      if (m.group(2) == 'complete') {
        return s == 'consumed' ? _j(200, {'status': 'completed'}) : _j(409, {'error': 'not_consumed'});
      }
      return s == 'consumed' ? _j(409, {'error': 'consumed'}) : _j(200, {'status': 'released'});
    }
    final tid = body['tour_id'];
    if (tid is String) state[tid] = 'consumed';
    if (p == '/api/geocode') {
      final a = (body['address'] as String? ?? '').toLowerCase();
      final (name, lat, lng) = a.contains('hamburg')
          ? ('Hamburg, Deutschland', 53.55, 9.99)
          : a.contains('nürnberg') || a.contains('nuernberg')
              ? ('Nürnberg, Deutschland', 49.45, 11.08)
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
    final pts = densify([[48.09, 13.87], [49.45, 11.08], [53.55, 9.99]], stepKm: 50);
    final resp = directionsResponse([
      [pts]
    ]);
    // Wie bei Google: die Gesamtgeometrie der Route steht in overview_polyline.
    final route0 = Map<String, dynamic>.from((resp['routes'] as List).first as Map);
    route0['overview_polyline'] = {'points': encodePolyline(pts)};
    resp['routes'] = [route0];
    return _j(200, resp);
  }
}

void main() {
  late _Proxy proxy;

  setUp(() {
    debugMapPickerUseMapLibre = false; // MapLibre in Widget-Tests nicht darstellbar
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
  // OutlinedButton.icon erzeugt eine Unterklasse, deshalb per Typprüfung.
  final mapButton = find.ancestor(
    of: find.text('Karte anzeigen'),
    matching: find.byWidgetPredicate((w) => w is OutlinedButton),
  );

  Future<void> pumpApp(WidgetTester tester, {bool signedIn = false}) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1280, 1800);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    if (signedIn) {
      final auth = _Auth(ValueNotifier<AuthUser?>(_alice));
      final account = AccountService(
        auth: auth,
        bootstrap: (_) async => (status: 200, body: {
              'account_id': '1bce1a79-0000-4000-8000-00000000000a',
              'plan_key': 'free', 'status': 'active', 'created': false,
            }),
      );
      await tester.pumpWidget(DriverRouteApp(
          auth: auth, account: account, tours: TourService(auth: auth, account: account)));
    } else {
      await tester.pumpWidget(const DriverRouteApp());
    }
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

  /// Öffnet die Karte, liefert die angezeigte Ansicht und schließt sie wieder.
  Future<MapOsmView> openMap(WidgetTester tester) async {
    await tester.ensureVisible(mapButton);
    await tester.tap(mapButton);
    await tester.pumpAndSettle();
    final view = tester.widget<MapOsmView>(find.byType(MapOsmView));
    Navigator.of(tester.element(find.byType(MapOsmView))).pop();
    await tester.pumpAndSettle();
    return view;
  }

  Future<void> finish(WidgetTester tester) async {
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  }

  // ======================================================== in der App
  testWidgets('vor der Berechnung: Kartenknopf aus, kein Provider-Aufruf', (tester) async {
    await pumpApp(tester);
    expect(tester.widget<OutlinedButton>(mapButton).onPressed, isNull);
    await tester.ensureVisible(mapButton);
    await tester.tap(mapButton, warnIfMissed: false);
    await tester.pumpAndSettle();
    expect(find.byType(MapOsmView), findsNothing);
    expect(proxy.directions, 0);
    await finish(tester);
  });

  testWidgets('Produktion ohne Login: normale Route, Karte ohne weiteren Aufruf, auch zweimal',
      (tester) async {
    await pumpApp(tester);
    await calculate(tester);
    final afterCalc = proxy.providerCalls;
    expect(proxy.directions, greaterThan(0));

    final view = await openMap(tester);
    expect(view.route.length, greaterThan(2)); // berechnete Geometrie
    expect(proxy.providerCalls, afterCalc);

    await openMap(tester);
    expect(proxy.providerCalls, afterCalc);
    await finish(tester);
  });

  testWidgets('Route mit Zwischenstopp: Karte mit Stopp, kein weiterer Aufruf', (tester) async {
    await pumpApp(tester);
    await tester.ensureVisible(find.text('ZWISCHENSTOPPS'));
    await tester.tap(find.text('ZWISCHENSTOPPS'));
    await tester.pumpAndSettle();
    await tester.enterText(field('Adresse oder Ort eingeben'), 'Nürnberg');
    final add = find.text('Zwischenstopp hinzufügen');
    await tester.ensureVisible(add);
    await tester.tap(add);
    await tester.pumpAndSettle();

    await calculate(tester);
    final stopRequests = proxy.requests.where((r) =>
        r.url.path == '/api/directions' && (jsonDecode(r.body) as Map)['waypoints'] is List &&
        ((jsonDecode(r.body) as Map)['waypoints'] as List).isNotEmpty);
    expect(stopRequests, isNotEmpty); // die Berechnung kannte den Stopp
    final afterCalc = proxy.providerCalls;

    final view = await openMap(tester);
    expect(view.route.length, greaterThan(2));
    expect(view.stops.length, 1);
    expect(view.stops.single.latitude, closeTo(49.45, 0.01));
    expect(proxy.providerCalls, afterCalc);
    await finish(tester);
  });

  testWidgets('Kartenpunkt als Zwischenstopp: Koordinate an Directions, kein Geocoding',
      (tester) async {
    await pumpApp(tester);
    // Grenzdaten vorab real laden (Datei-Lesen braucht echte Zeit im Test).
    await tester.runAsync(() => CountryIndex.load());
    await tester.ensureVisible(find.text('ZWISCHENSTOPPS'));
    await tester.tap(find.text('ZWISCHENSTOPPS'));
    await tester.pumpAndSettle();

    final before = proxy.providerCalls;
    final pick = find.text('Auf Karte wählen');
    await tester.ensureVisible(pick);
    await tester.tap(pick);
    await tester.pumpAndSettle();
    expect(find.byType(MapPointPicker), findsOneWidget);

    await tester.tapAt(tester.getCenter(find.byType(FlutterMap)));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.runAsync(() => Future<void>.delayed(Duration.zero)); // Land (lokal)
    await tester.pump();
    await tester.tap(find.text('Als Zwischenpunkt übernehmen'));
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pumpAndSettle();
    expect(find.byType(MapPointPicker), findsNothing);

    // Liste: kurz und lesbar, Koordinate klein darunter.
    expect(find.textContaining('1. 📍 Kartenpunkt · Deutschland'), findsOneWidget);
    expect(find.textContaining('@'), findsNothing);
    expect(proxy.providerCalls, before); // Setzen kostet nichts

    await calculate(tester);
    final wps = [
      for (final r in proxy.requests)
        if (r.url.path == '/api/directions')
          for (final w in ((jsonDecode(r.body) as Map)['waypoints'] as List? ?? const [])) w as String,
    ];
    expect(wps, isNotEmpty);
    expect(wps.every((w) => RegExp(r'^-?\d+\.\d{6},-?\d+\.\d{6}$').hasMatch(w)), isTrue,
        reason: '$wps');
    // Geocoding nur für Start und Ziel – nicht für den Kartenpunkt.
    final geocoded = [
      for (final r in proxy.requests)
        if (r.url.path == '/api/geocode') (jsonDecode(r.body) as Map)['address']
    ];
    expect(geocoded.where((a) => a.toString().contains('Kartenpunkt')), isEmpty);
    expect(geocoded.where((a) => RegExp(r'^\d').hasMatch(a.toString())), isEmpty);

    // Die Karte zeigt den Punkt als Stopp – aus der gespeicherten Koordinate.
    final view = await openMap(tester);
    expect(view.stops, hasLength(1));
    await finish(tester);
  });

  testWidgets('Fährroute: Landwege und Seestrecke aus der Berechnung, kein weiterer Aufruf',
      (tester) async {
    SharedPreferences.setMockInitialValues({
      'ferries_json_cache_v2':
          '{"routes":[{"id":"igou_bari_grimaldi","name":"Igoumenitsa–Bari (Grimaldi)","from":"Igoumenitsa","to":"Bari","operators":["Grimaldi"],"duration_hours":10,"departures_local":[],"tz":"Europe/Athens","region":"Griechenland/Italien","active":true}]}',
    });
    await pumpApp(tester);
    await tester.scrollUntilVisible(find.text('FÄHRE'), 250, scrollable: find.byType(Scrollable).first);
    await tester.tap(find.text('FÄHRE'));
    await tester.pumpAndSettle();
    final search = find.byWidgetPredicate(
        (w) => w is TextField && w.decoration?.labelText == 'Fähre manuell suchen');
    await tester.ensureVisible(search);
    await tester.enterText(search, 'Igoumenitsa Bari');
    await tester.pumpAndSettle();
    final route = find.text('Igoumenitsa–Bari (Grimaldi)');
    await tester.ensureVisible(route);
    await tester.tap(route);
    await tester.pumpAndSettle();

    await calculate(tester);
    final afterCalc = proxy.providerCalls;
    final view = await openMap(tester);
    expect(view.segments.where((s) => s.isFerry).length, 1);
    expect(view.segments.where((s) => !s.isFerry).length, 2);
    expect(proxy.providerCalls, afterCalc);
    await finish(tester);
  });

  testWidgets('Berechnung ohne Streckenführung (manuelle km): Karte nur mit Markern, kein Aufruf',
      (tester) async {
    await pumpApp(tester);
    proxy.zeroResults = true; // Directions liefert keine Route -> 850 km manuell
    await calculate(tester);
    final afterCalc = proxy.providerCalls;
    final view = await openMap(tester);
    expect(view.route, isEmpty);
    expect(view.segments, isEmpty);
    expect(view.subtitle, contains(map_launcher.mapMarkersOnlyNote));
    expect(proxy.providerCalls, afterCalc);
    await finish(tester);
  });

  testWidgets('angemeldet (Tour-Modus): Karte ohne neuen Aufruf und ohne neue Tour', (tester) async {
    await pumpApp(tester, signedIn: true);
    await calculate(tester);
    final afterCalc = proxy.requests.length;
    await openMap(tester);
    await openMap(tester);
    expect(proxy.requests.length, afterCalc); // weder Maps noch /api/tours
    await finish(tester);
  });

  testWidgets('Tour abgelehnt: kein Ergebnis, keine Karte, kein öffentlicher Directions-Aufruf',
      (tester) async {
    await pumpApp(tester, signedIn: true);
    proxy.reserve = (status: 403, body: {'error': 'quota_not_configured'});
    await calculate(tester);
    expect(tester.widget<OutlinedButton>(mapButton).onPressed, isNull);
    await tester.ensureVisible(mapButton);
    await tester.tap(mapButton, warnIfMissed: false);
    await tester.pumpAndSettle();
    expect(find.byType(MapOsmView), findsNothing);
    expect(proxy.directions, 0);
    await finish(tester);
  });

  // =================================================== reine Planung
  group('planRouteMap', () {
    test('ohne Berechnung: keine Karte', () {
      final p = map_launcher.planRouteMap(hasResult: false, encodedPolyline: 'abc');
      expect(p.available, isFalse);
      expect(p.message, map_launcher.mapNeedsCalculation);
    });

    test('mit Geometrie der Berechnung: genau diese Linie', () {
      final enc = encodePolyline([[48.0, 13.0], [49.0, 12.0], [50.0, 11.0]]);
      final p = map_launcher.planRouteMap(hasResult: true, encodedPolyline: enc,
          stopCoords: const [LatLng(49, 12), null]);
      expect(p.available, isTrue);
      expect(p.route.length, 3);
      expect(p.stops.length, 1);
      expect(p.markersOnly, isFalse);
    });

    test('ohne Geometrie, aber mit Koordinaten: nur Marker, mit Hinweis', () {
      final p = map_launcher.planRouteMap(
          hasResult: true, startCoord: const LatLng(48, 13), destCoord: const LatLng(53, 10),
          routeNote: 'Über Dänemark');
      expect(p.markersOnly, isTrue);
      expect(p.subtitle, contains('Über Dänemark'));
      expect(p.subtitle, contains(map_launcher.mapMarkersOnlyNote));
    });

    test('ohne Geometrie und ohne Koordinaten: keine Karte', () {
      final p = map_launcher.planRouteMap(hasResult: true);
      expect(p.available, isFalse);
      expect(p.message, map_launcher.mapNoGeometry);
    });
  });
}
