import 'package:flutter/foundation.dart';

import '../account/account_service.dart';
import '../auth/auth_service.dart';

enum InputFailureKind {
  sessionInvalid,
  accountNotReady,
  quotaNotConfigured,
  budgetExhausted,
  unavailable,
  network,
  invalidResponse,
}

/// Warum eine angemeldete Adresseingabe nicht zu Google durfte. Es gibt dann
/// keinen Ersatz über den öffentlichen Weg.
class InputFailure implements Exception {
  const InputFailure(this.kind);

  final InputFailureKind kind;

  String get message => switch (kind) {
        InputFailureKind.sessionInvalid =>
          'Anmeldung abgelaufen. Bitte neu anmelden, um Adressen zu suchen.',
        InputFailureKind.accountNotReady =>
          'Dein Konto ist noch nicht bereit. Bitte kurz warten.',
        InputFailureKind.quotaNotConfigured =>
          'Für deinen Plan ist die Adresssuche noch nicht freigeschaltet.',
        InputFailureKind.budgetExhausted =>
          'Dein Tageskontingent für die Adresssuche ist aufgebraucht.',
        InputFailureKind.unavailable =>
          'Adresssuche gerade nicht verfügbar. Bitte später erneut versuchen.',
        InputFailureKind.network => 'Keine Verbindung zur Adresssuche.',
        InputFailureKind.invalidResponse =>
          'Unerwartete Antwort der Adresssuche.',
      };

  @override
  String toString() => 'InputFailure($kind)';

  /// Antwort des Proxys auf einen angemeldeten Eingabe-Aufruf (nicht 200).
  static InputFailure fromResponse(int status, Object? body) {
    final code = body is Map ? body['error'] : null;
    switch (status) {
      case 401:
        return const InputFailure(InputFailureKind.sessionInvalid);
      case 403:
        return InputFailure(code == 'input_quota_not_configured'
            ? InputFailureKind.quotaNotConfigured
            : InputFailureKind.accountNotReady);
      case 429:
        return InputFailure(code == 'input_budget_exhausted'
            ? InputFailureKind.budgetExhausted
            : InputFailureKind.unavailable);
      case 503:
        return const InputFailure(InputFailureKind.unavailable);
    }
    return const InputFailure(InputFailureKind.invalidResponse);
  }
}

/// Antwort gehört zu einer Anmeldung, die es nicht mehr gibt.
class StaleInputResponse implements Exception {
  const StaleInputResponse();
}

/// Anmeldung für Adresseingaben (Autocomplete, Geocoding außerhalb einer Tour).
///
/// Angemeldet und Konto bestätigt: jeder Aufruf trägt das aktuelle Token, der
/// Proxy zählt ihn gegen das Tagesbudget des Kontos. Nutzer, Konto, Plan und
/// Limit bestimmt allein der Server.
///
/// Nicht angemeldet oder Login nicht eingerichtet: öffentlicher Weg wie
/// bisher, ohne Token.
///
/// Angemeldet, aber etwas fehlt (Konto, Token) oder der Proxy lehnt ab: es
/// geht NICHTS ohne Token hinaus.
class InputAuth {
  InputAuth._();

  static AuthService? _auth;
  static AccountService? _account;
  static String? _userId;
  static int _generation = 0;

  /// Letzte Ablehnung, zum Anzeigen in der Oberfläche.
  static final ValueNotifier<InputFailure?> lastFailure = ValueNotifier(null);

  static void configure(AuthService auth, AccountService? account) {
    _auth?.user.removeListener(_onUserChanged);
    _auth = auth;
    _account = account;
    _userId = auth.user.value?.id;
    _generation++;
    auth.user.addListener(_onUserChanged);
  }

  static void reset() {
    _auth?.user.removeListener(_onUserChanged);
    _auth = null;
    _account = null;
    _userId = null;
    _generation++;
    lastFailure.value = null;
  }

  // Abmelden oder anderer Nutzer: Antworten davor gehören nicht mehr dazu.
  // Ein Token-Refresh desselben Nutzers ändert nichts.
  static void _onUserChanged() {
    final id = _auth?.user.value?.id;
    if (id != _userId) {
      _userId = id;
      _generation++;
    }
  }

  /// Für einen Eingabe-Aufruf. null = öffentlicher Weg.
  /// Wirft [InputFailure], wenn angemeldet, aber nichts hinausgehen darf.
  static InputCall? forCall() {
    final auth = _auth;
    if (auth == null || !auth.enabled || auth.user.value == null) return null;
    if (_account?.state.value.phase != AccountPhase.ready) {
      throw report(const InputFailure(InputFailureKind.accountNotReady));
    }
    final token = auth.accessToken;
    if (token == null) {
      throw report(const InputFailure(InputFailureKind.sessionInvalid));
    }
    return InputCall._(_generation, token);
  }

  /// Wirft, wenn sich die Anmeldung seit dem Aufruf geändert hat.
  static void checkCurrent(InputCall call) {
    if (call._generation != _generation) throw const StaleInputResponse();
  }

  static InputFailure report(InputFailure failure) {
    lastFailure.value = failure;
    return failure;
  }
}

class InputCall {
  InputCall._(this._generation, this._token);

  final int _generation;
  final String _token;

  Map<String, String> get headers => {'Authorization': 'Bearer $_token'};
}
