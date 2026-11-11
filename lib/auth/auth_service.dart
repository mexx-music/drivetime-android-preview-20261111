import 'package:flutter/foundation.dart';

/// Angemeldeter Nutzer, soweit die App ihn kennen muss.
///
/// Bewusst ohne Plan, Kontingent oder Konto: all das entscheidet der Server.
/// Die App zeigt es später nur an, was der Server ihr sagt.
@immutable
class AuthUser {
  const AuthUser({required this.id, this.email});

  /// auth.users.id – serverseitig identisch mit cc.users.id.
  final String id;
  final String? email;

  @override
  bool operator ==(Object other) =>
      other is AuthUser && other.id == id && other.email == email;

  @override
  int get hashCode => Object.hash(id, email);
}

enum AuthFailureKind {
  invalidEmail,
  invalidCode,
  rateLimited,
  captchaRequired,
  network,
  unavailable,
  unknown,
}

class AuthFailure implements Exception {
  const AuthFailure(this.kind);

  final AuthFailureKind kind;

  /// Meldung für die Oberfläche. Nie die Rohmeldung des Servers.
  String get message => switch (kind) {
        AuthFailureKind.invalidEmail => 'Bitte eine gültige E-Mail-Adresse eingeben.',
        AuthFailureKind.invalidCode => 'Der Code ist falsch oder abgelaufen.',
        AuthFailureKind.rateLimited =>
          'Zu viele Versuche. Bitte in ein paar Minuten erneut probieren.',
        AuthFailureKind.captchaRequired => 'Bitte die Sicherheitsprüfung bestätigen.',
        AuthFailureKind.network => 'Keine Verbindung. Bitte später erneut versuchen.',
        AuthFailureKind.unavailable => 'Anmeldung ist gerade nicht möglich.',
        AuthFailureKind.unknown => 'Anmeldung fehlgeschlagen. Bitte erneut versuchen.',
      };

  @override
  String toString() => 'AuthFailure($kind)';
}

/// Anmeldung per E-Mail-Code (kein Passwort, kein Link).
///
/// Der Client meldet nur an und ab. Konto, Plan und Kontingent legt später
/// ausschließlich der Server an – anhand der geprüften Nutzer-ID aus dem Token.
abstract class AuthService {
  /// false: Login ist nicht eingerichtet, die App läuft ohne Anmeldung.
  bool get enabled;

  /// Aktueller Nutzer; null = nicht angemeldet.
  ValueListenable<AuthUser?> get user;

  /// Zugangstoken für spätere Proxy-Aufrufe (Authorization: Bearer …).
  String? get accessToken;

  /// Schickt einen Anmeldecode per E-Mail. Legt einen Auth-Nutzer an, falls
  /// es noch keinen gibt.
  Future<void> requestCode(String email, {String? captchaToken});

  /// Meldet mit dem Code aus der E-Mail an.
  Future<void> verifyCode(String email, String code);

  /// Meldet ab. Lokal immer, auch ohne Verbindung.
  Future<void> signOut();
}

/// Login ausgeschaltet: nichts anzeigen, nichts anfragen.
class DisabledAuthService implements AuthService {
  const DisabledAuthService();

  static final ValueNotifier<AuthUser?> _none = ValueNotifier<AuthUser?>(null);

  @override
  bool get enabled => false;

  @override
  ValueListenable<AuthUser?> get user => _none;

  @override
  String? get accessToken => null;

  @override
  Future<void> requestCode(String email, {String? captchaToken}) async =>
      throw const AuthFailure(AuthFailureKind.unavailable);

  @override
  Future<void> verifyCode(String email, String code) async =>
      throw const AuthFailure(AuthFailureKind.unavailable);

  @override
  Future<void> signOut() async {}
}

/// Gemeinsame Eingabeprüfung für alle Umsetzungen.
String normalizeEmail(String email) {
  final e = email.trim().toLowerCase();
  if (!RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$').hasMatch(e) || e.length > 254) {
    throw const AuthFailure(AuthFailureKind.invalidEmail);
  }
  return e;
}

String normalizeCode(String code) {
  final c = code.replaceAll(RegExp(r'\s'), '');
  // Supabase verschickt je nach Einstellung 6 bis 10 Ziffern.
  if (!RegExp(r'^[0-9]{6,10}$').hasMatch(c)) {
    throw const AuthFailure(AuthFailureKind.invalidCode);
  }
  return c;
}
