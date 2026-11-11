import 'dart:async';
import 'dart:convert';

import 'package:driverroute_eta/account/account_service.dart';
import 'package:driverroute_eta/auth/auth_service.dart';
import 'package:driverroute_eta/main.dart';
import 'package:driverroute_eta/services/maps_proxy.dart';
import 'package:driverroute_eta/tour/input_auth.dart';
import 'package:driverroute_eta/tour/tour_scope.dart';
import 'package:driverroute_eta/tour/tour_service.dart';
import 'package:driverroute_eta/widgets/places_autocomplete.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'helpers/fake_directions.dart';

const _alice = AuthUser(id: '6f1c9a3e-2b7d-4e8a-9c1f-0a2b3c4d5e6f', email: 'alice@example.com');
const _bob = AuthUser(id: '0b3e5c7a-1d2f-4a6b-8c9d-e0f1a2b3c4d5', email: 'bob@example.com');

class _Auth implements AuthService {
  _Auth({AuthUser? user, this.token}) : _user = ValueNotifier<AuthUser?>(user);
  final ValueNotifier<AuthUser?> _user;
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
        'plan_key': 'free', 'status': 'active', 'created': false,
      }
    );

/// Ersatz-Proxy: protokolliert jede Anfrage; Antworten steuerbar.
class _Proxy {
  final List<http.Request> requests = [];
  ({int status, Object? body})? inputOverride;
  bool inputThrows = false;
  final Map<String, Completer<void>> hold = {};
  int _tours = 0;

  List<http.Request> get input => requests
      .where((r) => r.url.path == '/api/autocomplete' ||
          (r.url.path == '/api/geocode' && !(jsonDecode(r.body) as Map).containsKey('tour_id')))
      .toList();

  http.Response _j(int s, Object? b) =>
      http.Response(jsonEncode(b), s, headers: {'content-type': 'application/json'});

  Future<http.Response> handle(http.Request r) async {
    requests.add(r);
    final path = r.url.path;
    final body = r.body.isEmpty ? <String, Object?>{} : jsonDecode(r.body) as Map<String, Object?>;
    if (path == '/api/tours') {
      final id = '00000000-0000-4000-8000-${(++_tours).toString().padLeft(12, '0')}';
      return _j(201, {
        'tour_id': id, 'state': 'reserved', 'call_budget': 20, 'calls_used': 0, 'completed': false,
        'expires_at': DateTime.now().add(const Duration(minutes: 10)).toUtc().toIso8601String(),
      });
    }
    if (path.startsWith('/api/tours/')) return _j(200, {'status': 'completed'});
    final isInput = path == '/api/autocomplete' || (path == '/api/geocode' && body['tour_id'] == null);
    if (isInput) {
      final key = (body['input'] ?? body['address'] ?? '').toString();
      if (hold[key] != null) await hold[key]!.future;
      if (inputThrows) throw http.ClientException('offline');
      if (inputOverride != null) return _j(inputOverride!.status, inputOverride!.body);
    }
    if (path == '/api/autocomplete') {
      final q = (body['input'] as String).toLowerCase();
      final name = q.startsWith('ham') ? 'Hamburg, Deutschland' : 'Lambach, Österreich';
      return _j(200, {
        'suggestions': [
          {'placePrediction': {'placeId': 'id-$name', 'text': {'text': name}}}
        ]
      });
    }
    if (path == '/api/geocode') {
      final a = (body['address'] as String? ?? '').toLowerCase();
      final hamburg = a.contains('hamburg');
      return _j(200, {
        'status': 'OK',
        'results': [
          {
            'formatted_address': hamburg ? 'Hamburg, Deutschland' : 'Lambach, Österreich',
            'geometry': {'location': hamburg ? {'lat': 53.55, 'lng': 9.99} : {'lat': 48.09, 'lng': 13.87}},
          }
        ],
      });
    }
    final pts = densify([[48.09, 13.87], [53.55, 9.99]], stepKm: 50);
    final resp = directionsResponse([[pts]]);
    final r0 = Map<String, dynamic>.from((resp['routes'] as List).first as Map);
    r0['overview_polyline'] = {'points': encodePolyline(pts)};
    resp['routes'] = [r0];
    return _j(200, resp);
  }
}

void main() {
  late _Proxy proxy;

  setUp(() {
    proxy = _Proxy();
    debugMapsDirectCallsAllowed = false;
    debugMapsProxyBase = 'https://proxy.test';
    debugMapsProxyClient = MockClient(proxy.handle);
    SharedPreferences.setMockInitialValues({});
  });

  tearDown(() {
    InputAuth.reset();
    TourScope.exit();
    debugMapsDirectCallsAllowed = null;
    debugMapsProxyBase = null;
    debugMapsProxyClient = null;
  });

  Future<_Auth> signedIn({AuthUser user = _alice}) async {
    final auth = _Auth(user: user, token: 'token-${user.email}');
    final account = AccountService(auth: auth, bootstrap: _accountOk);
    await pumpEventQueue();
    InputAuth.configure(auth, account);
    return auth;
  }

  Future<void> ac(String q) => proxyAutocomplete(input: q, sessionToken: 's');

  // ======================================================== Proxy-Client
  group('Eingabe-Aufrufe', () {
    test('angemeldet: Autocomplete, Geocoding und Rückwärts-Geocoding mit Token, ohne Tour', () async {
      await signedIn();
      await ac('Lam');
      await proxyGeocode('Lambach');
      await proxyReverseGeocode(48.09, 13.87);
      expect(proxy.requests.length, 3);
      for (final r in proxy.requests) {
        expect(r.headers['Authorization'], 'Bearer token-alice@example.com');
        final body = jsonDecode(r.body) as Map;
        expect(body.containsKey('tour_id'), isFalse);
        // Nichts, was Nutzer, Konto, Plan oder Budget bestimmen könnte.
        for (final k in ['user_id', 'account_id', 'plan_key', 'input_calls_per_day', 'limit']) {
          expect(body.containsKey(k), isFalse, reason: k);
        }
      }
    });

    test('öffentlicher Build (Login aus) und nicht angemeldet: kein Token', () async {
      InputAuth.configure(const DisabledAuthService(), null);
      await ac('Lam');
      final auth = _Auth();
      InputAuth.configure(auth, AccountService(auth: auth, bootstrap: _accountOk));
      await proxyGeocode('Lambach');
      expect(proxy.requests.length, 2);
      expect(proxy.requests.every((r) => !r.headers.containsKey('Authorization')), isTrue);
    });

    test('wiederhergestellte Sitzung: Token von Anfang an', () async {
      await signedIn(); // Nutzer schon beim Start da
      await ac('Lam');
      expect(proxy.requests.single.headers['Authorization'], isNotNull);
    });

    test('Konto noch nicht bereit: nichts geht hinaus, auch nicht öffentlich', () async {
      final auth = _Auth(user: _alice, token: 't');
      final pending = Completer<({int status, Object? body})>();
      InputAuth.configure(auth, AccountService(auth: auth, bootstrap: (_) => pending.future));
      await expectLater(ac('Lam'),
          throwsA(isA<InputFailure>().having((f) => f.kind, 'kind', InputFailureKind.accountNotReady)));
      expect(proxy.requests, isEmpty);
    });

    test('ohne Token trotz Anmeldung: nichts geht hinaus', () async {
      final auth = await signedIn();
      auth.token = null;
      await expectLater(proxyGeocode('Lambach'),
          throwsA(isA<InputFailure>().having((f) => f.kind, 'kind', InputFailureKind.sessionInvalid)));
      expect(proxy.requests, isEmpty);
    });

    for (final c in <(int, Object?, InputFailureKind)>[
      (429, {'error': 'input_budget_exhausted'}, InputFailureKind.budgetExhausted),
      (429, {'error': 'rate_limited'}, InputFailureKind.unavailable),
      (401, {'error': 'invalid_token'}, InputFailureKind.sessionInvalid),
      (403, {'error': 'input_quota_not_configured'}, InputFailureKind.quotaNotConfigured),
      (403, {'error': 'no_entitlement'}, InputFailureKind.accountNotReady),
      (503, {'error': 'quota_unavailable'}, InputFailureKind.unavailable),
      (500, null, InputFailureKind.invalidResponse),
    ]) {
      test('Antwort ${c.$1} ${c.$2}: ${c.$3}, genau eine Anfrage, kein öffentlicher Ersatz', () async {
        await signedIn();
        proxy.inputOverride = (status: c.$1, body: c.$2);
        await expectLater(ac('Lam'), throwsA(isA<InputFailure>().having((f) => f.kind, 'kind', c.$3)));
        await expectLater(proxyGeocode('Lambach'), throwsA(isA<InputFailure>()));
        expect(proxy.requests.length, 2);
        expect(proxy.requests.every((r) => r.headers['Authorization'] != null), isTrue);
        expect(InputAuth.lastFailure.value?.kind, c.$3);
      });
    }

    test('Netzfehler: InputFailure, danach Retry wieder mit Token', () async {
      await signedIn();
      proxy.inputThrows = true;
      await expectLater(ac('Lam'),
          throwsA(isA<InputFailure>().having((f) => f.kind, 'kind', InputFailureKind.network)));
      proxy.inputThrows = false;
      await ac('Lamb');
      expect(proxy.requests.length, 2);
      expect(proxy.requests.every((r) => r.headers['Authorization'] != null), isTrue);
    });

    test('Abmelden während der Anfrage: Antwort wird verworfen', () async {
      final auth = await signedIn();
      proxy.hold['Lam'] = Completer<void>();
      final f = ac('Lam');
      await pumpEventQueue();
      await auth.signOut();
      proxy.hold['Lam']!.complete();
      await expectLater(f, throwsA(isA<StaleInputResponse>()));
    });

    test('Nutzerwechsel während der Anfrage: alte Antwort verworfen, neuer Nutzer mit eigenem Token',
        () async {
      final auth = await signedIn();
      proxy.hold['Lam'] = Completer<void>();
      final f = ac('Lam');
      await pumpEventQueue();
      auth.signIn(_bob, 'token-bob');
      proxy.hold['Lam']!.complete();
      await expectLater(f, throwsA(isA<StaleInputResponse>()));
      await ac('Ham');
      expect(proxy.requests.last.headers['Authorization'], 'Bearer token-bob');
    });

    test('Token-Refresh: gleiche Anmeldung, nächster Aufruf mit neuem Token', () async {
      final auth = await signedIn();
      await ac('Lam');
      auth.token = 'token-refreshed';
      await ac('Lamb');
      expect(proxy.requests.last.headers['Authorization'], 'Bearer token-refreshed');
    });

    test('in einer Berechnung (Tour) läuft Geocoding im Tour-Budget, nicht als Eingabe', () async {
      await signedIn();
      TourScope.enter('00000000-0000-4000-8000-000000000009', () => 'tour-token');
      await proxyGeocode('Lambach');
      final body = jsonDecode(proxy.requests.single.body) as Map;
      expect(body['tour_id'], '00000000-0000-4000-8000-000000000009');
      expect(proxy.input, isEmpty);
    });
  });

  // ================================================== überholte Vorschläge
  testWidgets('schnelles Tippen: ältere, später eintreffende Antwort überschreibt nicht', (tester) async {
    await tester.runAsync(signedIn); // pumpEventQueue braucht echte Zeit
    final ctl = TextEditingController();
    addTearDown(ctl.dispose);
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: PlacesAutocompleteField(apiKey: '', controller: ctl, hintText: 'Start')),
    ));
    proxy.hold['Lam'] = Completer<void>();
    await tester.enterText(find.byType(TextField), 'Lam');
    await tester.pump(const Duration(milliseconds: 600)); // Anfrage "Lam" hängt
    await tester.enterText(find.byType(TextField), 'Ham');
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pumpAndSettle();
    expect(find.text('Hamburg'), findsOneWidget);
    proxy.hold['Lam']!.complete(); // alte Antwort kommt zu spät
    await tester.pumpAndSettle();
    expect(find.text('Hamburg'), findsOneWidget);
    expect(find.text('Lambach'), findsNothing);
  });

  // ============================================================ in der App
  group('in der App', () {
    Finder field(String label) =>
        find.byWidgetPredicate((w) => w is TextField && w.decoration?.labelText == label);

    Future<(_Auth, TourService)> pumpSignedIn(WidgetTester tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(1280, 1800);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      final auth = _Auth(user: _alice, token: 'token-alice');
      final account = AccountService(auth: auth, bootstrap: _accountOk);
      final tours = TourService(auth: auth, account: account);
      await tester.pumpWidget(DriverRouteApp(auth: auth, account: account, tours: tours));
      await tester.pumpAndSettle();
      return (auth, tours);
    }

    Future<void> pick(WidgetTester tester, String label, String typed, String short) async {
      await tester.enterText(field(label), typed);
      await tester.pump(const Duration(milliseconds: 600));
      await tester.pumpAndSettle();
      final s = find.descendant(of: find.byType(ListTile), matching: find.text(short));
      await tester.ensureVisible(s);
      await tester.tap(s);
      await tester.pumpAndSettle();
    }

    testWidgets('Tagesbudget erschöpft: verständliche Meldung, kein Aufruf ohne Token', (tester) async {
      await pumpSignedIn(tester);
      proxy.inputOverride = (status: 429, body: {'error': 'input_budget_exhausted'});
      await tester.enterText(field('Start eingeben'), 'Lam');
      await tester.pump(const Duration(milliseconds: 600));
      await tester.pumpAndSettle();
      expect(find.text(const InputFailure(InputFailureKind.budgetExhausted).message), findsOneWidget);
      expect(proxy.requests, isNotEmpty);
      expect(proxy.requests.every((r) => r.headers['Authorization'] == 'Bearer token-alice'), isTrue);
      await tester.pump(const Duration(seconds: 5));
      await tester.pumpAndSettle();
    });

    testWidgets('Eingabe mit Token außerhalb der Tour, danach genau eine Tour für die Berechnung',
        (tester) async {
      await pumpSignedIn(tester);
      await pick(tester, 'Start eingeben', 'Lam', 'Lambach');
      await pick(tester, 'Ziel eingeben', 'Ham', 'Hamburg');
      final inputBefore = proxy.input.length;
      expect(inputBefore, greaterThanOrEqualTo(4)); // 2 Autocomplete + 2 Vorschlags-Geocoding
      expect(proxy.input.every((r) => r.headers['Authorization'] == 'Bearer token-alice'), isTrue);
      expect(proxy.requests.where((r) => r.url.path == '/api/tours'), isEmpty);

      final b = find.text('Route berechnen');
      await tester.ensureVisible(b);
      await tester.tap(b);
      await tester.pumpAndSettle();
      expect(proxy.requests.where((r) => r.url.path == '/api/tours').length, 1);
      final directions = proxy.requests.where((r) => r.url.path == '/api/directions').toList();
      expect(directions, isNotEmpty);
      expect(directions.every((r) => (jsonDecode(r.body) as Map)['tour_id'] != null), isTrue);
      await tester.pump(const Duration(seconds: 5));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });
  });
}
