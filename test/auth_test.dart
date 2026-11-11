import 'dart:async';
import 'dart:convert';

import 'package:driverroute_eta/auth/account_button.dart';
import 'package:driverroute_eta/auth/auth_config.dart';
import 'package:driverroute_eta/auth/auth_service.dart';
import 'package:driverroute_eta/auth/supabase_auth_service.dart';
import 'package:driverroute_eta/main.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart' as sb;

// ---------------------------------------------------------------- Hilfen

String _b64(Map<String, Object?> m) =>
    base64Url.encode(utf8.encode(jsonEncode(m))).replaceAll('=', '');

String _jwt(Map<String, Object?> payload) =>
    '${_b64({'alg': 'ES256', 'typ': 'JWT'})}.${_b64(payload)}.c2lnbmF0dXI';

const _userId = '6f1c9a3e-2b7d-4e8a-9c1f-0a2b3c4d5e6f';

Map<String, Object?> _session({String email = 'fahrer@example.com'}) {
  final exp = DateTime.now().add(const Duration(hours: 1)).millisecondsSinceEpoch ~/ 1000;
  return {
    'access_token': _jwt({'sub': _userId, 'exp': exp, 'role': 'authenticated', 'aud': 'authenticated'}),
    'token_type': 'bearer',
    'expires_in': 3600,
    'expires_at': exp,
    'refresh_token': 'refresh-1',
    'user': {
      'id': _userId,
      'aud': 'authenticated',
      'email': email,
      'app_metadata': {'provider': 'email'},
      'user_metadata': <String, Object?>{},
      'created_at': '2026-09-27T10:00:00Z',
    },
  };
}

class _MemoryStorage extends sb.GotrueAsyncStorage {
  final Map<String, String> _data = {};
  @override
  Future<String?> getItem({required String key}) async => _data[key];
  @override
  Future<void> removeItem({required String key}) async => _data.remove(key);
  @override
  Future<void> setItem({required String key, required String value}) async =>
      _data[key] = value;
}

/// Ersatz für den Auth-Server von Supabase. Zählt jede Anfrage mit.
class _FakeGoTrue {
  final List<http.Request> requests = [];
  String validCode = '123456';
  bool expired = false;
  bool rateLimited = false;
  bool offline = false;
  bool mailFails = false;

  Future<http.Response> handle(http.Request r) async {
    requests.add(r);
    if (offline) throw http.ClientException('offline');
    final path = r.url.path;
    Map<String, Object?> body() => jsonDecode(r.body) as Map<String, Object?>;
    http.Response json(int status, Object body) => http.Response(
        jsonEncode(body), status,
        headers: {'content-type': 'application/json'});

    if (path.endsWith('/otp')) {
      if (mailFails) {
        // So antwortet Supabase, wenn der SMTP-Versand scheitert.
        return json(500, {'code': 500, 'error_code': 'unexpected_failure',
                          'msg': 'Error sending confirmation email'});
      }
      if (rateLimited) {
        return json(429, {'code': 429, 'error_code': 'over_email_send_rate_limit', 'msg': 'rate limit'});
      }
      return json(200, <String, Object?>{});
    }
    if (path.endsWith('/verify')) {
      final b = body();
      if (expired || b['token'] != validCode) {
        return json(403, {'code': 403, 'error_code': 'otp_expired', 'msg': 'Token has expired or is invalid'});
      }
      return json(200, _session(email: b['email'] as String));
    }
    if (path.endsWith('/logout')) return http.Response('', 204);
    return json(404, {'msg': 'unbekannt'});
  }
}

sb.GoTrueClient _client(_FakeGoTrue server) => sb.GoTrueClient(
      url: 'https://auth.test/auth/v1',
      headers: {'apikey': 'sb_publishable_test'},
      httpClient: MockClient(server.handle),
      asyncStorage: _MemoryStorage(),
      autoRefreshToken: false,
    );

/// Für Oberflächentests: steuerbarer Login ohne Netz.
class _FakeAuth implements AuthService {
  final ValueNotifier<AuthUser?> _user = ValueNotifier(null);
  final List<String> codesRequested = [];
  String validCode = '123456';

  @override
  bool get enabled => true;
  @override
  ValueListenable<AuthUser?> get user => _user;
  @override
  String? get accessToken => _user.value == null ? null : 'token';
  @override
  Future<void> requestCode(String email, {String? captchaToken}) async {
    codesRequested.add(normalizeEmail(email));
  }

  @override
  Future<void> verifyCode(String email, String code) async {
    if (normalizeCode(code) != validCode) {
      throw const AuthFailure(AuthFailureKind.invalidCode);
    }
    _user.value = AuthUser(id: _userId, email: normalizeEmail(email));
  }

  @override
  Future<void> signOut() async => _user.value = null;
}

// ------------------------------------------------------------------ Tests

void main() {
  group('AuthConfig', () {
    const anonJwt =
        'eyJhbGciOiJIUzI1NiJ9.eyJyb2xlIjoiYW5vbiIsImlzcyI6InN1cGFiYXNlIn0.c2ln';
    const serviceJwt =
        'eyJhbGciOiJIUzI1NiJ9.eyJyb2xlIjoic2VydmljZV9yb2xlIiwiaXNzIjoic3VwYWJhc2UifQ.c2ln';

    test('ohne Werte ist der Login aus', () {
      expect(AuthConfig.parse('', ''), isNull);
      // Ein normaler Build setzt keine Werte.
      expect(AuthConfig.fromEnvironment(), isNull);
    });

    test('öffentliche Schlüssel werden akzeptiert', () {
      expect(AuthConfig.parse('https://abc.supabase.co', 'sb_publishable_xyz'), isNotNull);
      expect(AuthConfig.parse('https://abc.supabase.co', anonJwt), isNotNull);
      expect(AuthConfig.parse('http://127.0.0.1:54321', 'sb_publishable_xyz'), isNotNull);
    });

    test('geheime Schlüssel werden abgewiesen, ohne sie zu nennen', () {
      for (final key in ['sb_secret_abc', serviceJwt, 'irgendwas']) {
        expect(
          () => AuthConfig.parse('https://abc.supabase.co', key),
          throwsA(isA<ArgumentError>().having(
              (e) => e.message.toString(), 'Meldung', isNot(contains(key)))),
        );
      }
    });

    test('unsichere oder halbe Konfiguration wird abgewiesen', () {
      expect(() => AuthConfig.parse('http://abc.supabase.co', 'sb_publishable_x'),
          throwsArgumentError);
      expect(() => AuthConfig.parse('https://abc.supabase.co', ''), throwsArgumentError);
      expect(() => AuthConfig.parse('', 'sb_publishable_x'), throwsArgumentError);
    });
  });

  group('Eingaben', () {
    test('E-Mail wird normalisiert und geprüft', () {
      expect(normalizeEmail('  Fahrer@Example.COM '), 'fahrer@example.com');
      expect(() => normalizeEmail('kein-at'), throwsA(isA<AuthFailure>()));
    });
    test('Code: nur 6 bis 10 Ziffern, Leerzeichen egal', () {
      expect(normalizeCode('123 456'), '123456');
      expect(() => normalizeCode('12345'), throwsA(isA<AuthFailure>()));
      expect(() => normalizeCode('abcdef'), throwsA(isA<AuthFailure>()));
    });
  });

  group('SupabaseAuthService gegen einen Ersatz-Auth-Server', () {
    late _FakeGoTrue server;
    late sb.GoTrueClient client;
    late SupabaseAuthService auth;

    setUp(() {
      server = _FakeGoTrue();
      client = _client(server);
      auth = SupabaseAuthService(client);
    });

    tearDown(() => auth.dispose());

    test('nicht eingeloggt: kein Nutzer, kein Token', () {
      expect(auth.enabled, isTrue);
      expect(auth.user.value, isNull);
      expect(auth.accessToken, isNull);
    });

    test('Code anfordern: E-Mail normalisiert, Nutzer darf entstehen, kein Link', () async {
      await auth.requestCode(' Fahrer@Example.com ', captchaToken: 'cap-1');
      final r = server.requests.single;
      expect(r.url.path, endsWith('/otp'));
      final body = jsonDecode(r.body) as Map<String, Object?>;
      expect(body['email'], 'fahrer@example.com');
      expect(body['create_user'], isTrue);
      expect((body['gotrue_meta_security'] as Map)['captcha_token'], 'cap-1');
      expect(r.url.queryParameters.containsKey('redirect_to'), isFalse);
      expect(auth.user.value, isNull);
    });

    test('ungültige E-Mail erreicht den Server gar nicht', () async {
      await expectLater(auth.requestCode('nix'), throwsA(isA<AuthFailure>()));
      expect(server.requests, isEmpty);
    });

    test('zu viele Anfragen: verständlicher Fehler', () async {
      server.rateLimited = true;
      await expectLater(
        auth.requestCode('fahrer@example.com'),
        throwsA(isA<AuthFailure>().having((f) => f.kind, 'kind', AuthFailureKind.rateLimited)),
      );
    });

    test('falscher Code: Fehler, weiterhin abgemeldet', () async {
      await expectLater(
        auth.verifyCode('fahrer@example.com', '999999'),
        throwsA(isA<AuthFailure>().having((f) => f.kind, 'kind', AuthFailureKind.invalidCode)),
      );
      expect(auth.user.value, isNull);
    });

    test('abgelaufener Code: Fehler, weiterhin abgemeldet', () async {
      server.expired = true;
      await expectLater(
        auth.verifyCode('fahrer@example.com', '123456'),
        throwsA(isA<AuthFailure>().having((f) => f.kind, 'kind', AuthFailureKind.invalidCode)),
      );
      expect(auth.user.value, isNull);
      expect(auth.accessToken, isNull);
    });

    test('richtiger Code: angemeldet, Token vorhanden, Zustand gemeldet', () async {
      final seen = <AuthUser?>[];
      auth.user.addListener(() => seen.add(auth.user.value));

      await auth.verifyCode('fahrer@example.com', '123 456');

      final verify = server.requests.single;
      expect(verify.url.path, endsWith('/verify'));
      final body = jsonDecode(verify.body) as Map<String, Object?>;
      expect(body['type'], 'email');
      expect(body['token'], '123456');

      expect(auth.user.value, const AuthUser(id: _userId, email: 'fahrer@example.com'));
      expect(auth.accessToken, isNotNull);
      expect(seen.last, isNotNull);
    });

    test('Abmelden: Server benachrichtigt, lokal abgemeldet', () async {
      await auth.verifyCode('fahrer@example.com', '123456');
      await auth.signOut();
      expect(server.requests.last.url.path, endsWith('/logout'));
      expect(auth.user.value, isNull);
      expect(auth.accessToken, isNull);
      expect(client.currentSession, isNull);
    });

    test('Abmelden ohne Verbindung meldet trotzdem lokal ab', () async {
      await auth.verifyCode('fahrer@example.com', '123456');
      server.offline = true;
      await auth.signOut();
      expect(auth.user.value, isNull);
      expect(client.currentSession, isNull);
    });

    test('Serverfehler (z. B. Mailversand): nicht als Verbindungsproblem', () async {
      server.mailFails = true;
      await expectLater(
        auth.requestCode('fahrer@example.com'),
        throwsA(isA<AuthFailure>().having((f) => f.kind, 'kind', AuthFailureKind.unavailable)),
      );
    });

    test('ohne Verbindung: Netzwerkfehler statt Absturz', () async {
      server.offline = true;
      await expectLater(
        auth.requestCode('fahrer@example.com'),
        throwsA(isA<AuthFailure>().having((f) => f.kind, 'kind', AuthFailureKind.network)),
      );
    });

    test('Sitzung nach Reload: gespeicherte Sitzung wird übernommen', () async {
      // So stellt supabase_flutter eine Sitzung aus dem localStorage wieder her.
      final restored = _client(_FakeGoTrue());
      await restored.setInitialSession(jsonEncode(_session()));
      final restoredAuth = SupabaseAuthService(restored);
      expect(restoredAuth.user.value?.id, _userId);
      expect(restoredAuth.accessToken, isNotNull);
      await restoredAuth.dispose();
    });

    test('Abmelden von außen (z. B. anderer Tab) wird übernommen', () async {
      await auth.verifyCode('fahrer@example.com', '123456');
      final done = Completer<void>();
      auth.user.addListener(() {
        if (auth.user.value == null && !done.isCompleted) done.complete();
      });
      await client.signOut();
      await done.future.timeout(const Duration(seconds: 2));
      expect(auth.user.value, isNull);
    });
  });

  group('Oberfläche', () {
    Future<void> pump(WidgetTester tester, AuthService auth) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(appBar: AppBar(actions: [AccountButton(auth: auth)])),
      ));
    }

    testWidgets('Login aus: kein Anmeldeknopf', (tester) async {
      await pump(tester, const DisabledAuthService());
      expect(find.byTooltip('Anmelden'), findsNothing);
      expect(find.byTooltip('Konto'), findsNothing);
    });

    testWidgets('Anmelden mit Code, falscher Code, Abmelden', (tester) async {
      final auth = _FakeAuth();
      await pump(tester, auth);

      await tester.tap(find.byTooltip('Anmelden'));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('login-email')), findsOneWidget);
      expect(find.byKey(const Key('login-code')), findsNothing);

      await tester.enterText(find.byKey(const Key('login-email')), 'Fahrer@Example.com');
      await tester.tap(find.text('Code senden'));
      await tester.pumpAndSettle();
      expect(auth.codesRequested, ['fahrer@example.com']);
      expect(find.byKey(const Key('login-code')), findsOneWidget);

      await tester.enterText(find.byKey(const Key('login-code')), '000000');
      await tester.tap(find.widgetWithText(FilledButton, 'Anmelden'));
      await tester.pumpAndSettle();
      expect(find.text('Der Code ist falsch oder abgelaufen.'), findsOneWidget);
      expect(auth.user.value, isNull);

      await tester.enterText(find.byKey(const Key('login-code')), '123456');
      await tester.tap(find.widgetWithText(FilledButton, 'Anmelden'));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('login-code')), findsNothing); // Blatt geschlossen
      expect(find.byTooltip('Konto'), findsOneWidget);

      await tester.tap(find.byTooltip('Konto'));
      await tester.pumpAndSettle();
      expect(find.text('fahrer@example.com'), findsOneWidget);
      await tester.tap(find.text('Abmelden'));
      await tester.pumpAndSettle();
      expect(auth.user.value, isNull);
      expect(find.byTooltip('Anmelden'), findsOneWidget);
    });

    testWidgets('ungültige E-Mail: Hinweis, kein Code-Schritt', (tester) async {
      final auth = _FakeAuth();
      await pump(tester, auth);
      await tester.tap(find.byTooltip('Anmelden'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('login-email')), 'kein-at');
      await tester.tap(find.text('Code senden'));
      await tester.pumpAndSettle();
      expect(find.text('Bitte eine gültige E-Mail-Adresse eingeben.'), findsOneWidget);
      expect(find.byKey(const Key('login-code')), findsNothing);
      expect(auth.codesRequested, isEmpty);
    });

    testWidgets('App ohne Login-Konfiguration sieht aus wie bisher', (tester) async {
      SharedPreferences.setMockInitialValues({});
      await tester.pumpWidget(const DriverRouteApp());
      await tester.pumpAndSettle();
      expect(find.text('ROUTE PLANEN'), findsOneWidget);
      expect(find.byTooltip('Anmelden'), findsNothing);
    });

    testWidgets('App mit Login zeigt den Anmeldeknopf', (tester) async {
      SharedPreferences.setMockInitialValues({});
      await tester.pumpWidget(DriverRouteApp(auth: _FakeAuth()));
      await tester.pumpAndSettle();
      expect(find.text('ROUTE PLANEN'), findsOneWidget);
      expect(find.byTooltip('Anmelden'), findsOneWidget);
    });
  });
}
