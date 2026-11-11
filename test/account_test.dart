import 'dart:async';
import 'dart:convert';

import 'package:driverroute_eta/account/account_service.dart';
import 'package:driverroute_eta/auth/account_button.dart';
import 'package:driverroute_eta/auth/auth_service.dart';
import 'package:driverroute_eta/services/maps_proxy.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const _alice = AuthUser(id: '6f1c9a3e-2b7d-4e8a-9c1f-0a2b3c4d5e6f', email: 'alice@example.com');
const _bob = AuthUser(id: '0b3e5c7a-1d2f-4a6b-8c9d-e0f1a2b3c4d5', email: 'bob@example.com');
const _accountA = '1bce1a79-0000-4000-8000-00000000000a';

/// Meldet jede Zuweisung – auch dieselbe –, wie ein Token-Refresh es tun kann.
class _AlwaysNotify<T> extends ChangeNotifier implements ValueListenable<T> {
  _AlwaysNotify(this._value);
  T _value;
  @override
  T get value => _value;
  set value(T v) {
    _value = v;
    notifyListeners();
  }
}

class _FakeAuth implements AuthService {
  _FakeAuth({AuthUser? user, this.token}) : _user = _AlwaysNotify<AuthUser?>(user);

  final _AlwaysNotify<AuthUser?> _user;
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

/// Ersatz für den Proxy-Aufruf; zählt mit und liefert, was der Test vorgibt.
class _FakeBootstrap {
  final List<String> tokens = [];
  final List<Completer<({int status, Object? body})>> pending = [];
  ({int status, Object? body}) Function(int call) respond =
      (call) => (status: 200, body: _ok(created: call == 1));
  bool hold = false;
  Object? throwThis;

  Future<({int status, Object? body})> call(String token) {
    tokens.add(token);
    if (throwThis != null) return Future.error(throwThis!);
    if (hold) {
      final c = Completer<({int status, Object? body})>();
      pending.add(c);
      return c.future;
    }
    return Future.value(respond(tokens.length));
  }
}

Map<String, Object?> _ok({bool created = true, String id = _accountA}) =>
    {'account_id': id, 'plan_key': 'free', 'status': 'active', 'created': created};

Future<void> _settle() => Future<void>.delayed(Duration.zero);

void main() {
  group('AccountService', () {
    test('Login ausgeschaltet: kein Aufruf, Zustand disabled', () async {
      final boot = _FakeBootstrap();
      final s = AccountService(auth: const DisabledAuthService(), bootstrap: boot.call);
      await _settle();
      expect(s.state.value.phase, AccountPhase.disabled);
      expect(boot.tokens, isEmpty);
    });

    test('nicht angemeldet: kein Aufruf', () async {
      final boot = _FakeBootstrap();
      final s = AccountService(auth: _FakeAuth(), bootstrap: boot.call);
      await _settle();
      expect(s.state.value.phase, AccountPhase.signedOut);
      expect(boot.tokens, isEmpty);
    });

    test('Login → Bootstrap mit aktuellem Token → Konto laut Proxy', () async {
      final auth = _FakeAuth();
      final boot = _FakeBootstrap();
      final s = AccountService(auth: auth, bootstrap: boot.call);
      auth.signIn(_alice, 'token-alice-1');
      expect(s.state.value.phase, AccountPhase.loading);
      await _settle();
      expect(boot.tokens, ['token-alice-1']);
      final info = s.state.value.info!;
      expect(s.state.value.phase, AccountPhase.ready);
      expect(info.accountId, _accountA);
      expect(info.planKey, 'free');
      expect(info.status, 'active');
      expect(info.created, isTrue);
    });

    test('wiederhergestellte Sitzung → Bootstrap beim Start', () async {
      final auth = _FakeAuth(user: _alice, token: 'token-restored');
      final boot = _FakeBootstrap();
      final s = AccountService(auth: auth, bootstrap: boot.call);
      await _settle();
      expect(boot.tokens, ['token-restored']);
      expect(s.state.value.phase, AccountPhase.ready);
    });

    test('gleicher Nutzer erneut gemeldet (Token-Refresh): kein zweiter Aufruf', () async {
      final auth = _FakeAuth();
      final boot = _FakeBootstrap();
      final s = AccountService(auth: auth, bootstrap: boot.call);
      auth.signIn(_alice, 'token-1');
      await _settle();
      auth.signIn(_alice, 'token-2'); // derselbe Nutzer, neues Token
      await _settle();
      expect(boot.tokens, ['token-1']);
      expect(s.state.value.phase, AccountPhase.ready);
    });

    test('Wiederholung ist idempotent: gleiches Konto, created=false', () async {
      final auth = _FakeAuth(user: _alice, token: 't');
      final boot = _FakeBootstrap();
      final s = AccountService(auth: auth, bootstrap: boot.call);
      await _settle();
      final first = s.state.value.info!;
      await s.retry();
      final second = s.state.value.info!;
      expect(boot.tokens.length, 2);
      expect(second.accountId, first.accountId);
      expect(first.created, isTrue);
      expect(second.created, isFalse);
    });

    final cases = <int, AccountErrorKind>{
      401: AccountErrorKind.sessionRejected,
      403: AccountErrorKind.forbidden,
      429: AccountErrorKind.unavailable,
      500: AccountErrorKind.unavailable,
      503: AccountErrorKind.unavailable,
      404: AccountErrorKind.invalidResponse,
    };
    cases.forEach((status, kind) {
      test('HTTP $status → Fehler $kind, kein Ersatz-Plan', () async {
        final boot = _FakeBootstrap()
          ..respond = (_) => (status: status, body: {'error': 'x', 'plan_key': 'free'});
        final s = AccountService(auth: _FakeAuth(user: _alice, token: 't'), bootstrap: boot.call);
        await _settle();
        expect(s.state.value.phase, AccountPhase.error);
        expect(s.state.value.error, kind);
        expect(s.state.value.info, isNull);
      });
    });

    test('Netzfehler → Fehler network', () async {
      final boot = _FakeBootstrap()..throwThis = http.ClientException('offline');
      final s = AccountService(auth: _FakeAuth(user: _alice, token: 't'), bootstrap: boot.call);
      await _settle();
      expect(s.state.value.error, AccountErrorKind.network);
      expect(s.state.value.info, isNull);
    });

    test('Proxy nicht eingerichtet → Fehler notConfigured', () async {
      final boot = _FakeBootstrap()..throwThis = const ProxyNotConfiguredException();
      final s = AccountService(auth: _FakeAuth(user: _alice, token: 't'), bootstrap: boot.call);
      await _settle();
      expect(s.state.value.error, AccountErrorKind.notConfigured);
    });

    for (final body in <Object?>[
      null,
      'free',
      <String, Object?>{},
      {..._ok(), 'account_id': 'kein-uuid'},
      {..._ok(), 'plan_key': ''},
      {..._ok(), 'status': null},
      {..._ok(), 'created': 'true'},
    ]) {
      test('200 mit unbrauchbarem Körper ($body) → invalidResponse, kein Konto', () async {
        final boot = _FakeBootstrap()..respond = (_) => (status: 200, body: body);
        final s = AccountService(auth: _FakeAuth(user: _alice, token: 't'), bootstrap: boot.call);
        await _settle();
        expect(s.state.value.phase, AccountPhase.error);
        expect(s.state.value.error, AccountErrorKind.invalidResponse);
        expect(s.state.value.info, isNull);
      });
    }

    test('angemeldet, aber ohne Token → sessionRejected, kein Aufruf', () async {
      final boot = _FakeBootstrap();
      final s = AccountService(auth: _FakeAuth(user: _alice), bootstrap: boot.call);
      await _settle();
      expect(s.state.value.error, AccountErrorKind.sessionRejected);
      expect(boot.tokens, isEmpty);
    });

    test('Abmelden → signedOut, Konto vergessen', () async {
      final auth = _FakeAuth(user: _alice, token: 't');
      final boot = _FakeBootstrap();
      final s = AccountService(auth: auth, bootstrap: boot.call);
      await _settle();
      await auth.signOut();
      expect(s.state.value.phase, AccountPhase.signedOut);
      expect(s.state.value.info, isNull);
    });

    test('Abmelden während der Anfrage: späte Antwort wird verworfen', () async {
      final auth = _FakeAuth(user: _alice, token: 't');
      final boot = _FakeBootstrap()..hold = true;
      final s = AccountService(auth: auth, bootstrap: boot.call);
      await _settle();
      expect(s.state.value.phase, AccountPhase.loading);
      await auth.signOut();
      boot.pending.single.complete((status: 200, body: _ok()));
      await _settle();
      expect(s.state.value.phase, AccountPhase.signedOut);
    });

    test('Nutzerwechsel: Konto des neuen Nutzers, alte Antwort verworfen', () async {
      final auth = _FakeAuth(user: _alice, token: 'token-a');
      final boot = _FakeBootstrap()..hold = true;
      final s = AccountService(auth: auth, bootstrap: boot.call);
      await _settle();
      auth.signIn(_bob, 'token-b');
      await _settle();
      expect(boot.tokens, ['token-a', 'token-b']);
      const idB = '2bce1a79-0000-4000-8000-00000000000b';
      boot.pending[1].complete((status: 200, body: _ok(id: idB)));
      await _settle();
      boot.pending[0].complete((status: 200, body: _ok()));
      await _settle();
      expect(s.state.value.info!.accountId, idB);
    });

    test('nach Fehler: Wiederholen führt zum Konto', () async {
      var fail = true;
      final boot = _FakeBootstrap()
        ..respond = (_) => fail ? (status: 503, body: null) : (status: 200, body: _ok(created: false));
      final s = AccountService(auth: _FakeAuth(user: _alice, token: 't'), bootstrap: boot.call);
      await _settle();
      expect(s.state.value.error, AccountErrorKind.unavailable);
      fail = false;
      await s.retry();
      expect(s.state.value.phase, AccountPhase.ready);
    });
  });

  group('Proxy-Aufruf', () {
    late List<http.Request> requests;

    setUp(() {
      requests = [];
      debugMapsProxyBase = 'https://proxy.test/';
      debugMapsProxyClient = MockClient((r) async {
        requests.add(r);
        return http.Response(jsonEncode(_ok()), 200,
            headers: {'content-type': 'application/json'});
      });
    });

    tearDown(() {
      debugMapsProxyBase = null;
      debugMapsProxyClient = null;
    });

    test('POST /api/account/bootstrap mit Bearer-Token und leerem Körper', () async {
      final res = await proxyAccountBootstrap('token-xyz');
      final r = requests.single;
      expect(r.method, 'POST');
      expect(r.url.toString(), 'https://proxy.test/api/account/bootstrap');
      expect(r.headers['Authorization'], 'Bearer token-xyz');
      // Nutzer, Konto und Plan bestimmt allein der Proxy.
      expect(r.body, '{}');
      expect(res.status, 200);
      expect(AccountInfo.tryParse(res.body)?.accountId, _accountA);
    });

    test('ohne Proxy-Adresse: kein Aufruf, ProxyNotConfiguredException', () async {
      debugMapsProxyBase = '';
      await expectLater(proxyAccountBootstrap('t'), throwsA(isA<ProxyNotConfiguredException>()));
      expect(requests, isEmpty);
    });

    test('ganze Kette mit echtem Proxy-Aufruf: Login → Konto', () async {
      final auth = _FakeAuth();
      final s = AccountService(auth: auth); // Standard: proxyAccountBootstrap
      auth.signIn(_alice, 'token-chain');
      await pumpEventQueue();
      expect(requests.single.headers['Authorization'], 'Bearer token-chain');
      expect(s.state.value.info?.accountId, _accountA);
    });
  });

  group('Kontomenü', () {
    Future<void> pump(WidgetTester tester, AuthService auth, AccountService account) =>
        tester.pumpWidget(MaterialApp(
          home: Scaffold(appBar: AppBar(actions: [AccountButton(auth: auth, account: account)])),
        ));

    testWidgets('zeigt den Plan laut Proxy', (tester) async {
      final auth = _FakeAuth(user: _alice, token: 't');
      final account = AccountService(auth: auth, bootstrap: _FakeBootstrap().call);
      await pump(tester, auth, account);
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Konto'));
      await tester.pumpAndSettle();
      expect(find.text('Plan: free'), findsOneWidget);
      expect(find.text('Erneut versuchen'), findsNothing);
    });

    testWidgets('Fehler: kein Plan, sondern Hinweis und Wiederholen', (tester) async {
      var fail = true;
      final boot = _FakeBootstrap()
        ..respond = (_) => fail ? (status: 503, body: null) : (status: 200, body: _ok());
      final auth = _FakeAuth(user: _alice, token: 't');
      final account = AccountService(auth: auth, bootstrap: boot.call);
      await pump(tester, auth, account);
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('Konto'));
      await tester.pumpAndSettle();
      expect(find.text('Konto gerade nicht verfügbar'), findsOneWidget);
      expect(find.textContaining('Plan:'), findsNothing);

      fail = false;
      await tester.tap(find.text('Erneut versuchen'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Konto'));
      await tester.pumpAndSettle();
      expect(find.text('Plan: free'), findsOneWidget);
    });

    testWidgets('Abmelden: zurück zu Anmelden', (tester) async {
      final auth = _FakeAuth(user: _alice, token: 't');
      final account = AccountService(auth: auth, bootstrap: _FakeBootstrap().call);
      await pump(tester, auth, account);
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Konto'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Abmelden'));
      await tester.pumpAndSettle();
      expect(find.byTooltip('Anmelden'), findsOneWidget);
      expect(account.state.value.phase, AccountPhase.signedOut);
    });
  });
}
