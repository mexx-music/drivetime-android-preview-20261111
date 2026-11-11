import 'dart:async';
import 'dart:convert';

import 'package:driverroute_eta/account/account_service.dart';
import 'package:driverroute_eta/auth/auth_service.dart';
import 'package:driverroute_eta/main.dart';
import 'package:driverroute_eta/services/maps_proxy.dart';
import 'package:driverroute_eta/tour/tour_scope.dart';
import 'package:driverroute_eta/tour/tour_service.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'helpers/fake_directions.dart';

// ---------------------------------------------------------------- Ersatz

const _alice = AuthUser(id: '6f1c9a3e-2b7d-4e8a-9c1f-0a2b3c4d5e6f', email: 'alice@example.com');
const _bob = AuthUser(id: '0b3e5c7a-1d2f-4a6b-8c9d-e0f1a2b3c4d5', email: 'bob@example.com');

class _Notify<T> extends ChangeNotifier implements ValueListenable<T> {
  _Notify(this._v);
  T _v;
  @override
  T get value => _v;
  set value(T v) {
    _v = v;
    notifyListeners();
  }
}

class _FakeAuth implements AuthService {
  _FakeAuth({AuthUser? user, this.token}) : _user = _Notify<AuthUser?>(user);
  final _Notify<AuthUser?> _user;
  String? token;
  @override
  bool get enabled => true;
  @override
  ValueListenable<AuthUser?> get user => _user;
  @override
  String? get accessToken => token;
  void signIn(AuthUser u, String t) {
    token = t;
    _user.value = u;
  }

  @override
  Future<void> signOut() async {
    token = null;
    _user.value = null;
  }

  @override
  Future<void> requestCode(String email, {String? captchaToken}) async {}
  @override
  Future<void> verifyCode(String email, String code) async {}
}

Future<({int status, Object? body})> _accountOk(String _) async => (
      status: 200,
      body: {
        'account_id': '1bce1a79-0000-4000-8000-00000000000a',
        'plan_key': 'free',
        'status': 'active',
        'created': false,
      }
    );

/// Ersatz für den Proxy: Touren wie die Datenbankfunktionen, Maps wie Google.
class _FakeProxy {
  final List<http.Request> requests = [];
  final Map<String, String> tourByKey = {}; // key -> tour id
  final Map<String, Map<String, Object?>> tours = {};
  final List<String> events = []; // reserve/complete/release/maps in Reihenfolge
  int _n = 0;

  // Steuerung
  ({int status, Object? body})? reserveResponse; // erzwingt eine Antwort
  bool reserveThrows = false;
  int? callBudget = 20;
  // Liefert je Maps-Aufruf (Zähler ab 1) eine erzwungene Antwort, sonst null.
  ({int status, Object? body})? Function(int n)? mapsOverride;
  Completer<void>? holdMaps;
  int mapsCalls = 0;

  List<http.Request> get maps => requests
      .where((r) => r.url.path == '/api/directions' || r.url.path == '/api/geocode')
      .toList();
  List<http.Request> get reserves => requests.where((r) => r.url.path == '/api/tours').toList();

  http.Response _json(int status, Object? body) =>
      http.Response(jsonEncode(body), status, headers: {'content-type': 'application/json'});

  Future<http.Response> handle(http.Request r) async {
    requests.add(r);
    final path = r.url.path;
    final body = r.body.isEmpty ? <String, Object?>{} : jsonDecode(r.body) as Map<String, Object?>;

    if (path == '/api/tours') {
      events.add('reserve');
      if (reserveThrows) throw http.ClientException('offline');
      if (reserveResponse != null) return _json(reserveResponse!.status, reserveResponse!.body);
      final key = body['idempotency_key'] as String;
      final existing = tourByKey[key];
      if (existing != null) {
        return _json(200, {...tours[existing]!, 'tour_id': existing});
      }
      final id = '00000000-0000-4000-8000-${(++_n).toString().padLeft(12, '0')}';
      tourByKey[key] = id;
      tours[id] = {
        'state': 'reserved',
        'call_budget': callBudget,
        'calls_used': 0,
        'completed': false,
        'expires_at': DateTime.now().add(const Duration(minutes: 10)).toUtc().toIso8601String(),
      };
      return _json(201, {...tours[id]!, 'tour_id': id});
    }
    final m = RegExp(r'^/api/tours/([0-9a-f-]+)/(complete|release)$').firstMatch(path);
    if (m != null) {
      events.add(m.group(2)!);
      final t = tours[m.group(1)];
      if (t == null) return _json(404, {'error': 'not_found'});
      if (m.group(2) == 'complete') {
        if (t['state'] != 'consumed') return _json(409, {'error': 'not_consumed'});
        t['completed'] = true;
        return _json(200, {'status': 'completed'});
      }
      if (t['state'] == 'consumed') return _json(409, {'error': 'consumed'});
      t['state'] = 'released';
      return _json(200, {'status': 'released'});
    }

    // Maps
    final n = ++mapsCalls;
    events.add('maps');
    if (holdMaps != null) await holdMaps!.future;
    final forced = mapsOverride?.call(n);
    if (forced != null) return _json(forced.status, forced.body);
    final tid = body['tour_id'];
    if (tid is String && tours[tid] != null) {
      tours[tid]!['state'] = 'consumed'; // erster Erfolg verbraucht die Tour
    }
    if (path == '/api/geocode') {
      final a = (body['address'] as String? ?? '').toLowerCase();
      final hamburg = a.contains('hamburg');
      return _json(200, {
        'status': 'OK',
        'results': [
          {
            'formatted_address': hamburg ? 'Hamburg, Deutschland' : 'Lambach, Österreich',
            'geometry': {
              'location': hamburg ? {'lat': 53.55, 'lng': 9.99} : {'lat': 48.09, 'lng': 13.87}
            },
          }
        ],
      });
    }
    return _json(200, directionsResponse([
      [densify([[48.09, 13.87], [50.1, 11.5], [53.55, 9.99]], stepKm: 50)]
    ]));
  }
}

// ------------------------------------------------------------------ Tests

void main() {
  late _FakeProxy proxy;

  setUp(() {
    proxy = _FakeProxy();
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

  ({_FakeAuth auth, AccountService account, TourService tours}) loggedIn({AuthUser user = _alice}) {
    final auth = _FakeAuth(user: user, token: 'token-${user.email}');
    final account = AccountService(auth: auth, bootstrap: _accountOk);
    return (auth: auth, account: account, tours: TourService(auth: auth, account: account));
  }

  // ======================================================== TourService
  group('TourService', () {
    test('reserviert mit Schlüssel, akzeptiert nur die tour_id des Proxys', () async {
      final s = loggedIn();
      await pumpEventQueue();
      final t = await s.tours.begin('A');
      final r = proxy.reserves.single;
      expect(r.headers['Authorization'], 'Bearer token-alice@example.com');
      final body = jsonDecode(r.body) as Map;
      expect(body.keys, ['idempotency_key']); // nichts sonst: kein Nutzer, Plan, Budget
      expect(t.tourId, proxy.tourByKey[body['idempotency_key']]);
    });

    test('nicht angemeldet / Konto nicht bestätigt: keine Reservierung', () async {
      final auth = _FakeAuth();
      final acc = AccountService(auth: auth, bootstrap: _accountOk);
      final tours = TourService(auth: auth, account: acc);
      expect(tours.required, isFalse);
      await expectLater(tours.begin('A'),
          throwsA(isA<TourFailure>().having((f) => f.kind, 'kind', TourFailureKind.notSignedIn)));

      final hold = Completer<({int status, Object? body})>();
      final auth2 = _FakeAuth(user: _alice, token: 't');
      final acc2 = AccountService(auth: auth2, bootstrap: (_) => hold.future);
      final tours2 = TourService(auth: auth2, account: acc2);
      await expectLater(tours2.begin('A'),
          throwsA(isA<TourFailure>().having((f) => f.kind, 'kind', TourFailureKind.accountNotReady)));
      expect(proxy.reserves, isEmpty);
    });

    final errors = <String, (int, Object?, TourFailureKind)>{
      '401': (401, {'error': 'invalid_token'}, TourFailureKind.sessionInvalid),
      '402': (402, {'error': 'quota_exhausted'}, TourFailureKind.quotaExhausted),
      '403 quota_not_configured': (403, {'error': 'quota_not_configured'}, TourFailureKind.quotaNotConfigured),
      '403 sonst': (403, {'error': 'no_entitlement'}, TourFailureKind.forbidden),
      '409': (409, {'error': 'idempotency_conflict'}, TourFailureKind.invalidResponse),
      '429': (429, {'error': 'rate_limited'}, TourFailureKind.unavailable),
      '503': (503, {'error': 'quota_unavailable'}, TourFailureKind.unavailable),
      '500': (500, null, TourFailureKind.invalidResponse),
      '201 ohne tour_id': (201, {'state': 'reserved', 'completed': false, 'expires_at': '2099-01-01T00:00:00Z'}, TourFailureKind.invalidResponse),
      '201 kaputte tour_id': (201, {'tour_id': 'x', 'state': 'reserved', 'completed': false, 'expires_at': '2099-01-01T00:00:00Z'}, TourFailureKind.invalidResponse),
    };
    errors.forEach((label, e) {
      test('Reservierung $label → ${e.$3}', () async {
        final s = loggedIn();
        await pumpEventQueue();
        proxy.reserveResponse = (status: e.$1, body: e.$2);
        await expectLater(s.tours.begin('A'),
            throwsA(isA<TourFailure>().having((f) => f.kind, 'kind', e.$3)));
      });
    });

    test('Netzfehler bei der Reservierung: Wiederholen nutzt denselben Schlüssel', () async {
      final s = loggedIn();
      await pumpEventQueue();
      proxy.reserveThrows = true;
      await expectLater(s.tours.begin('A'),
          throwsA(isA<TourFailure>().having((f) => f.kind, 'kind', TourFailureKind.network)));
      final key = s.tours.pendingKey;
      proxy.reserveThrows = false;
      await s.tours.begin('A');
      final keys = proxy.reserves.map((r) => (jsonDecode(r.body) as Map)['idempotency_key']).toSet();
      expect(keys, {key});
    });

    test('Retry nach verbrauchter, fehlgeschlagener Tour: dieselbe Tour', () async {
      final s = loggedIn();
      await pumpEventQueue();
      final t1 = await s.tours.begin('A');
      proxy.tours[t1.tourId]!['state'] = 'consumed';
      await s.tours.finish(t1, success: false); // release -> 409 consumed
      final t2 = await s.tours.begin('A');
      expect(t2.tourId, t1.tourId);
      expect(proxy.tours.length, 1);
    });

    test('nach Abschluss: neue Berechnung, neue Tour', () async {
      final s = loggedIn();
      await pumpEventQueue();
      final t1 = await s.tours.begin('A');
      proxy.tours[t1.tourId]!['state'] = 'consumed';
      await s.tours.finish(t1, success: true);
      expect(proxy.events.last, 'complete');
      final t2 = await s.tours.begin('A');
      expect(t2.tourId, isNot(t1.tourId));
    });

    test('Erfolg ohne verbrauchten Aufruf: complete 409 → release', () async {
      final s = loggedIn();
      await pumpEventQueue();
      final t = await s.tours.begin('A');
      await s.tours.finish(t, success: true);
      expect(proxy.events, ['reserve', 'complete', 'release']);
      expect(proxy.tours[t.tourId]!['state'], 'released');
      expect(s.tours.pendingKey, isNull);
    });

    test('Fehler vor dem ersten Erfolg: freigegeben, nächste Berechnung neue Tour', () async {
      final s = loggedIn();
      await pumpEventQueue();
      final t1 = await s.tours.begin('A');
      await s.tours.finish(t1, success: false);
      expect(proxy.tours[t1.tourId]!['state'], 'released');
      final t2 = await s.tours.begin('A');
      expect(t2.tourId, isNot(t1.tourId));
    });

    test('andere Eingaben: neue Berechnung, neuer Schlüssel', () async {
      final s = loggedIn();
      await pumpEventQueue();
      final t1 = await s.tours.begin('A');
      proxy.tours[t1.tourId]!['state'] = 'consumed';
      await s.tours.finish(t1, success: false);
      final t2 = await s.tours.begin('B');
      expect(t2.tourId, isNot(t1.tourId));
    });

    test('vom Proxy gemeldete beendete Tour wird nicht wiederverwendet', () async {
      final s = loggedIn();
      await pumpEventQueue();
      final t1 = await s.tours.begin('A');
      proxy.tours[t1.tourId]!['expires_at'] = '2000-01-01T00:00:00Z';
      await s.tours.finish(t1, success: false); // release scheitert nicht, aber Test: abgelaufen
      proxy.tours[t1.tourId]!['state'] = 'consumed';
      // Schlüssel noch offen? Dann kommt die abgelaufene Tour zurück -> neuer Schlüssel.
      final t2 = await s.tours.begin('A');
      expect(t2.tourId, isNot(t1.tourId));
    });

    test('Abmelden während der Reservierung: Antwort wird verworfen', () async {
      final s = loggedIn();
      await pumpEventQueue();
      final gate = Completer<void>();
      final orig = debugMapsProxyClient;
      debugMapsProxyClient = MockClient((r) async {
        await gate.future;
        return proxy.handle(r);
      });
      final f = s.tours.begin('A');
      await pumpEventQueue();
      await s.auth.signOut();
      gate.complete();
      await expectLater(f, throwsA(isA<TourFailure>().having((x) => x.kind, 'kind', TourFailureKind.sessionInvalid)));
      debugMapsProxyClient = orig;
    });

    test('Token nur für den Nutzer der Tour', () async {
      final s = loggedIn();
      await pumpEventQueue();
      final t = await s.tours.begin('A');
      expect(s.tours.tokenFor(t), isNotNull);
      s.auth.signIn(_bob, 'token-bob');
      expect(s.tours.tokenFor(t), isNull);
      await s.tours.finish(t, success: true);
      expect(proxy.events, ['reserve']); // nichts mit Bobs Token
    });
  });

  // ================================================ Proxy-Client + Scope
  group('Maps-Aufrufe im Tour-Modus', () {
    test('ohne Tour: unverändert, kein tour_id, kein Token', () async {
      await proxyDirections(origin: 'A', destination: 'B');
      await proxyGeocode('A');
      for (final r in proxy.maps) {
        expect((jsonDecode(r.body) as Map).containsKey('tour_id'), isFalse);
        expect(r.headers.containsKey('Authorization'), isFalse);
      }
    });

    test('mit Tour: Directions und Geocoding tragen tour_id und Token', () async {
      TourScope.enter('00000000-0000-4000-8000-000000000001', () => 'tok');
      await proxyDirections(origin: 'A', destination: 'B', avoidFerries: true);
      await proxyGeocode('A');
      for (final r in proxy.maps) {
        expect((jsonDecode(r.body) as Map)['tour_id'], '00000000-0000-4000-8000-000000000001');
        expect(r.headers['Authorization'], 'Bearer tok');
      }
      // avoid=ferries bleibt erhalten.
      expect((jsonDecode(proxy.maps.first.body) as Map)['avoid'], 'ferries');
    });

    test('Autocomplete und Reverse-Geocoding bleiben Adresseingabe (ohne Tour)', () async {
      TourScope.enter('00000000-0000-4000-8000-000000000001', () => 'tok');
      proxy.mapsOverride = null;
      await proxyAutocomplete(input: 'Lam', sessionToken: 's').catchError((_) => <String, dynamic>{});
      await proxyReverseGeocode(48, 13).catchError((_) => <String, dynamic>{});
      for (final r in proxy.requests) {
        expect((jsonDecode(r.body) as Map).containsKey('tour_id'), isFalse);
      }
    });

    for (final c in <(int, String, TourFailureKind)>[
      (429, 'call_budget_exhausted', TourFailureKind.callBudgetExhausted),
      (409, 'tour_expired', TourFailureKind.tourUnavailable),
      (401, 'invalid_token', TourFailureKind.sessionInvalid),
      (503, 'quota_unavailable', TourFailureKind.unavailable),
    ]) {
      test('Ablehnung ${c.$1}: danach geht nichts mehr hinaus – auch ohne Tour nicht', () async {
        TourScope.enter('00000000-0000-4000-8000-000000000001', () => 'tok');
        proxy.mapsOverride = (_) => (status: c.$1, body: {'error': c.$2});
        await expectLater(proxyDirections(origin: 'A', destination: 'B'), throwsException);
        expect(TourScope.failure?.kind, c.$3);
        final before = proxy.requests.length;
        await expectLater(proxyDirections(origin: 'A', destination: 'B'), throwsA(isA<TourFailure>()));
        await expectLater(proxyGeocode('A'), throwsA(isA<TourFailure>()));
        expect(proxy.requests.length, before);
      });
    }

    test('Google-Fehler (500) ist keine Ablehnung der Kostenkontrolle', () async {
      TourScope.enter('00000000-0000-4000-8000-000000000001', () => 'tok');
      proxy.mapsOverride = (n) => n == 1 ? (status: 500, body: {'error': 'Proxy failed'}) : null;
      await expectLater(proxyDirections(origin: 'A', destination: 'B'), throwsException);
      expect(TourScope.failure, isNull);
      await proxyDirections(origin: 'A', destination: 'B'); // Retry in derselben Tour
      expect((jsonDecode(proxy.maps.last.body) as Map)['tour_id'], isNotNull);
    });

    test('Token weg (abgemeldet): kein Aufruf, auch nicht ohne Token', () async {
      String? token = 'tok';
      TourScope.enter('00000000-0000-4000-8000-000000000001', () => token);
      await proxyDirections(origin: 'A', destination: 'B');
      token = null;
      await expectLater(proxyDirections(origin: 'A', destination: 'B'),
          throwsA(isA<TourFailure>().having((f) => f.kind, 'kind', TourFailureKind.sessionInvalid)));
      expect(proxy.maps.length, 1);
    });

    test('späte Ablehnung einer alten Berechnung wirkt nicht in die neue', () async {
      TourScope.enter('00000000-0000-4000-8000-000000000001', () => 'tok');
      final hold = Completer<void>();
      proxy.holdMaps = hold;
      proxy.mapsOverride = (_) => (status: 429, body: {'error': 'call_budget_exhausted'});
      final old = proxyDirections(origin: 'A', destination: 'B');
      await pumpEventQueue();
      TourScope.exit();
      TourScope.enter('00000000-0000-4000-8000-000000000002', () => 'tok');
      hold.complete();
      await expectLater(old, throwsException);
      expect(TourScope.failure, isNull);
    });
  });

  // ============================================== ganze Berechnung (_compute)
  group('Berechnung in der App', () {
    Finder field(String label) => find.byWidgetPredicate(
        (w) => w is TextField && w.decoration?.labelText == label);

    Future<void> pumpApp(WidgetTester tester, {AuthService? auth, AccountService? account, TourService? tours}) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(1280, 1800);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      await tester.pumpWidget(auth == null
          ? const DriverRouteApp()
          : DriverRouteApp(auth: auth, account: account, tours: tours));
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

    Future<void> finish(WidgetTester tester) async {
      await tester.pump(const Duration(seconds: 5));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    }

    Set<Object?> mapsTourIds() =>
        proxy.maps.map((r) => (jsonDecode(r.body) as Map)['tour_id']).toSet();

    testWidgets('ohne Supabase-Konfiguration (Produktion): unverändert, keine Tour', (tester) async {
      await pumpApp(tester);
      await calculate(tester);
      expect(proxy.reserves, isEmpty);
      expect(proxy.maps, isNotEmpty);
      expect(mapsTourIds(), {null});
      expect(proxy.maps.every((r) => !r.headers.containsKey('Authorization')), isTrue);
      await finish(tester);
    });

    testWidgets('angemeldet: eine Tour, alle Maps-Aufrufe darin, danach complete', (tester) async {
      final s = loggedIn();
      await pumpApp(tester, auth: s.auth, account: s.account, tours: s.tours);
      final start = proxy.events.length; // Eintippen löst Autocomplete aus
      await calculate(tester);
      expect(proxy.reserves.length, 1);
      expect(proxy.tours.length, 1);
      final tourId = proxy.tours.keys.single;
      expect(proxy.maps.length, greaterThan(1)); // mehrere Proxy-Aufrufe ...
      expect(mapsTourIds(), {tourId}); // ... alle in derselben Tour
      expect(proxy.maps.every((r) => r.headers['Authorization'] == 'Bearer token-alice@example.com'), isTrue);
      expect(proxy.events[start], 'reserve'); // Tour VOR dem ersten Maps-Aufruf
      expect(proxy.events.last, 'complete');
      expect(find.text('Route konnte nicht berechnet werden. Bitte Adressen, Distanz und Verbindung prüfen.'), findsNothing);
      await finish(tester);
    });

    testWidgets('neue Berechnung nach Erfolg: neue Tour', (tester) async {
      final s = loggedIn();
      await pumpApp(tester, auth: s.auth, account: s.account, tours: s.tours);
      await calculate(tester);
      await tester.pump(const Duration(seconds: 5));
      await calculate(tester);
      expect(proxy.tours.length, 2);
      expect(proxy.events.where((e) => e == 'complete').length, 2);
      await finish(tester);
    });

    testWidgets('Doppelklick: nur eine Tour', (tester) async {
      final s = loggedIn();
      await pumpApp(tester, auth: s.auth, account: s.account, tours: s.tours);
      final b = find.text('Route berechnen');
      await tester.ensureVisible(b);
      await tester.tap(b);
      await tester.tap(b, warnIfMissed: false);
      await tester.pumpAndSettle();
      expect(proxy.reserves.length, 1);
      await finish(tester);
    });

    testWidgets('quota_not_configured: keine Maps-Aufrufe, klare Meldung', (tester) async {
      final s = loggedIn();
      await pumpApp(tester, auth: s.auth, account: s.account, tours: s.tours);
      proxy.reserveResponse = (status: 403, body: {'error': 'quota_not_configured'});
      final mapsBefore = proxy.maps.length;
      await calculate(tester);
      expect(proxy.maps.length, mapsBefore); // kein Ausweg über den öffentlichen Pfad
      expect(find.text(const TourFailure(TourFailureKind.quotaNotConfigured).message), findsOneWidget);
      await finish(tester);
    });

    for (final c in <(int, String, TourFailureKind)>[
      (401, 'invalid_token', TourFailureKind.sessionInvalid),
      (402, 'quota_exhausted', TourFailureKind.quotaExhausted),
      (503, 'quota_unavailable', TourFailureKind.unavailable),
    ]) {
      testWidgets('Reservierung ${c.$1}: nicht gerechnet, kein Maps-Aufruf', (tester) async {
        final s = loggedIn();
        await pumpApp(tester, auth: s.auth, account: s.account, tours: s.tours);
        proxy.reserveResponse = (status: c.$1, body: {'error': c.$2});
        final mapsBefore = proxy.maps.length;
        await calculate(tester);
        expect(proxy.maps.length, mapsBefore);
        expect(find.text(TourFailure(c.$3).message), findsOneWidget);
        await finish(tester);
      });
    }

    testWidgets('Budget während der Berechnung erschöpft: kein Ergebnis, kein ungeschützter Aufruf',
        (tester) async {
      final s = loggedIn();
      await pumpApp(tester, auth: s.auth, account: s.account, tours: s.tours);
      final before = proxy.maps.length;
      final base = proxy.mapsCalls; // Zähler inkl. Autocomplete beim Eintippen
      proxy.mapsOverride = (n) => n > base + 1
          ? (status: 429, body: {'error': 'call_budget_exhausted'})
          : null;
      await calculate(tester);
      final during = proxy.maps.skip(before).toList();
      expect(during.every((r) => (jsonDecode(r.body) as Map)['tour_id'] != null), isTrue);
      expect(find.text(const TourFailure(TourFailureKind.callBudgetExhausted).message), findsOneWidget);
      // Tour war schon verbraucht: Freigabe wird versucht und verweigert, keine zweite Tour.
      expect(proxy.events.last, 'release');
      expect(proxy.tours.values.single['state'], 'consumed');
      await finish(tester);
    });

    testWidgets('Retry derselben Berechnung nach Fehler: dieselbe Tour', (tester) async {
      final s = loggedIn();
      await pumpApp(tester, auth: s.auth, account: s.account, tours: s.tours);
      final base = proxy.mapsCalls;
      proxy.mapsOverride = (n) => n > base + 1
          ? (status: 429, body: {'error': 'call_budget_exhausted'})
          : null;
      await calculate(tester);
      proxy.mapsOverride = null;
      await tester.pump(const Duration(seconds: 5));
      await calculate(tester);
      expect(proxy.tours.length, 1);
      final keys = proxy.reserves.map((r) => (jsonDecode(r.body) as Map)['idempotency_key']).toSet();
      expect(keys.length, 1);
      expect(proxy.events.last, 'complete');
      await finish(tester);
    });

    testWidgets('Fehler vor dem ersten Erfolg: Tour wird freigegeben', (tester) async {
      final s = loggedIn();
      await pumpApp(tester, auth: s.auth, account: s.account, tours: s.tours);
      proxy.mapsOverride = (_) => (status: 503, body: {'error': 'quota_unavailable'});
      await calculate(tester);
      expect(proxy.events.last, 'release');
      expect(proxy.tours.values.single['state'], 'released');
      await finish(tester);
    });

    testWidgets('Abmelden während der Berechnung: kein Ergebnis, nichts mehr hinaus', (tester) async {
      final s = loggedIn();
      await pumpApp(tester, auth: s.auth, account: s.account, tours: s.tours);
      final hold = Completer<void>();
      proxy.holdMaps = hold;
      final b = find.text('Route berechnen');
      await tester.ensureVisible(b);
      await tester.tap(b);
      await tester.pump();
      await tester.pump();
      final sentBefore = proxy.maps.length;
      await s.auth.signOut();
      hold.complete();
      proxy.holdMaps = null;
      await tester.pumpAndSettle();
      // Nach dem Abmelden ging kein weiterer Maps-Aufruf hinaus, auch keiner ohne Tour.
      expect(proxy.maps.length, sentBefore);
      expect(proxy.events.contains('complete'), isFalse);
      expect(find.text(const TourFailure(TourFailureKind.sessionInvalid).message), findsOneWidget);
      await finish(tester);
    });

    testWidgets('Nutzerwechsel während der Berechnung: alte Tour nicht mit neuem Token', (tester) async {
      final s = loggedIn();
      await pumpApp(tester, auth: s.auth, account: s.account, tours: s.tours);
      final hold = Completer<void>();
      proxy.holdMaps = hold;
      final b = find.text('Route berechnen');
      await tester.ensureVisible(b);
      await tester.tap(b);
      await tester.pump();
      await tester.pump();
      final sentBefore = proxy.maps.length;
      s.auth.signIn(_bob, 'token-bob');
      hold.complete();
      proxy.holdMaps = null;
      await tester.pumpAndSettle();
      expect(proxy.maps.length, sentBefore);
      expect(proxy.requests.any((r) => r.headers['Authorization'] == 'Bearer token-bob' &&
          r.url.path != '/api/tours'), isFalse);
      await finish(tester);
    });

    testWidgets('Token-Refresh während der Berechnung: gleiche Tour, neues Token', (tester) async {
      final s = loggedIn();
      await pumpApp(tester, auth: s.auth, account: s.account, tours: s.tours);
      proxy.mapsOverride = (n) {
        if (n == 3) s.auth.token = 'token-refreshed';
        return null;
      };
      await calculate(tester);
      expect(proxy.tours.length, 1);
      expect(mapsTourIds().length, 1);
      expect(proxy.maps.any((r) => r.headers['Authorization'] == 'Bearer token-refreshed'), isTrue);
      expect(proxy.events.last, 'complete');
      await finish(tester);
    });

    testWidgets('Fährroute (manuell gewählt): mehrere Directions, eine Tour', (tester) async {
      SharedPreferences.setMockInitialValues({
        'ferries_json_cache_v2':
            '{"routes":[{"id":"igou_bari_grimaldi","name":"Igoumenitsa–Bari (Grimaldi)","from":"Igoumenitsa","to":"Bari","operators":["Grimaldi"],"duration_hours":10,"departures_local":[],"tz":"Europe/Athens","region":"Griechenland/Italien","active":true}]}',
      });
      final s = loggedIn();
      await pumpApp(tester, auth: s.auth, account: s.account, tours: s.tours);
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

      final before = proxy.maps.length;
      await calculate(tester);
      final directions = proxy.maps.skip(before).where((r) => r.url.path == '/api/directions').toList();
      expect(directions.length, greaterThan(1));
      expect(proxy.tours.length, 1);
      expect(directions.map((r) => (jsonDecode(r.body) as Map)['tour_id']).toSet(),
          {proxy.tours.keys.single});
      // Getrennte Landwege mit avoid=ferries bleiben erhalten.
      expect(directions.any((r) => (jsonDecode(r.body) as Map)['avoid'] == 'ferries'), isTrue);
      await finish(tester);
    });

    testWidgets('Sitzung beim Start wiederhergestellt: gleicher Ablauf', (tester) async {
      final s = loggedIn(); // Nutzer schon beim Start da
      await pumpApp(tester, auth: s.auth, account: s.account, tours: s.tours);
      expect(s.account.state.value.phase, AccountPhase.ready);
      await calculate(tester);
      expect(proxy.tours.length, 1);
      expect(proxy.events.last, 'complete');
      await finish(tester);
    });
  });
}
