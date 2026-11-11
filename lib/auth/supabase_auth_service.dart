import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:supabase_flutter/supabase_flutter.dart' as sb;

import 'auth_config.dart';
import 'auth_service.dart';

/// Anmeldung über Supabase Auth mit E-Mail-Code.
///
/// Nur Auth: Die Data API wird nicht benutzt, der Client liest oder schreibt
/// keine einzige Tabelle. Die Sitzung liegt im Web im localStorage
/// (supabase_flutter-Standard) und wird nach einem Reload wiederhergestellt.
class SupabaseAuthService implements AuthService {
  SupabaseAuthService(this._client) {
    _user.value = _toUser(_client.currentSession?.user);
    _sub = _client.onAuthStateChange.listen(
      (state) => _user.value = _toUser(state.session?.user),
      // Ein Fehler beim Auffrischen darf die App nicht stören; die Sitzung
      // gilt dann einfach als beendet, sobald Supabase das meldet.
      onError: (Object error) => debugPrint('Auth-Zustand: $error'),
    );
  }

  /// Einmal beim App-Start. Stellt eine gespeicherte Sitzung wieder her.
  static Future<SupabaseAuthService> initialize(AuthConfig config) async {
    await sb.Supabase.initialize(
      url: config.url,
      publishableKey: config.publishableKey,
      authOptions: const sb.FlutterAuthClientOptions(
        authFlowType: sb.AuthFlowType.pkce,
        // Wir melden nur per Code an, nie über einen Link. Eine Sitzung aus
        // der Adresszeile wird deshalb gar nicht erst ausgewertet.
        detectSessionInUri: false,
      ),
    );
    return SupabaseAuthService(sb.Supabase.instance.client.auth);
  }

  final sb.GoTrueClient _client;
  final ValueNotifier<AuthUser?> _user = ValueNotifier<AuthUser?>(null);
  StreamSubscription<sb.AuthState>? _sub;

  static AuthUser? _toUser(sb.User? u) =>
      u == null ? null : AuthUser(id: u.id, email: u.email);

  @override
  bool get enabled => true;

  @override
  ValueListenable<AuthUser?> get user => _user;

  @override
  String? get accessToken => _client.currentSession?.accessToken;

  @override
  Future<void> requestCode(String email, {String? captchaToken}) async {
    final e = normalizeEmail(email);
    await _guard(() => _client.signInWithOtp(
          email: e,
          shouldCreateUser: true,
          captchaToken: captchaToken,
        ));
  }

  @override
  Future<void> verifyCode(String email, String code) async {
    final e = normalizeEmail(email);
    final c = normalizeCode(code);
    final res = await _guard(
        () => _client.verifyOTP(type: sb.OtpType.email, email: e, token: c));
    if (res.session == null) throw const AuthFailure(AuthFailureKind.invalidCode);
    _user.value = _toUser(res.session!.user);
  }

  @override
  Future<void> signOut() async {
    try {
      await _client.signOut();
    } catch (error) {
      // Supabase hat die Sitzung lokal bereits entfernt; nur der Widerruf
      // beim Server ist gescheitert (z. B. offline). Das Zugangstoken läuft
      // von selbst ab.
      debugPrint('Abmelden beim Server fehlgeschlagen: $error');
    }
    _user.value = null;
  }

  Future<void> dispose() async {
    await _sub?.cancel();
    _user.dispose();
  }

  /// Übersetzt Supabase-Fehler in eigene, anzeigbare Fehler.
  static Future<T> _guard<T>(Future<T> Function() run) async {
    try {
      return await run();
    } on sb.AuthRetryableFetchException catch (error) {
      // gotrue meldet echte Netzfehler UND jede Serverantwort ab 500 so.
      // Mit Statuscode hat der Server geantwortet – etwa wenn der
      // Mailversand scheitert. Das ist kein Verbindungsproblem.
      if (error.statusCode != null) {
        debugPrint('Auth-Server antwortete mit HTTP ${error.statusCode}');
        throw const AuthFailure(AuthFailureKind.unavailable);
      }
      throw const AuthFailure(AuthFailureKind.network);
    } on sb.AuthException catch (error) {
      throw AuthFailure(_kindFor(error));
    } on http.ClientException {
      throw const AuthFailure(AuthFailureKind.network);
    } on TimeoutException {
      throw const AuthFailure(AuthFailureKind.network);
    }
  }

  static AuthFailureKind _kindFor(sb.AuthException error) {
    switch (error.code) {
      case 'otp_expired':
        return AuthFailureKind.invalidCode;
      case 'over_email_send_rate_limit':
      case 'over_request_rate_limit':
        return AuthFailureKind.rateLimited;
      case 'captcha_failed':
        return AuthFailureKind.captchaRequired;
      case 'email_address_invalid':
      case 'validation_failed':
        return AuthFailureKind.invalidEmail;
      case 'signup_disabled':
      case 'otp_disabled':
      case 'email_provider_disabled':
      case 'email_address_not_authorized':
        return AuthFailureKind.unavailable;
    }
    if (error.statusCode == '429') return AuthFailureKind.rateLimited;
    return AuthFailureKind.unknown;
  }
}
