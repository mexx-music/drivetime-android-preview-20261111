import 'dart:async';

import 'package:flutter/foundation.dart';

import '../auth/auth_service.dart';
import '../services/maps_proxy.dart';

/// Konto, wie der Proxy es bestätigt hat. Die App bestimmt nichts davon selbst.
@immutable
class AccountInfo {
  const AccountInfo({
    required this.accountId,
    required this.planKey,
    required this.status,
    required this.created,
  });

  final String accountId;
  final String planKey;
  final String status;

  /// true = beim ersten Aufruf gerade angelegt.
  final bool created;

  static final _uuid = RegExp(
      r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$',
      caseSensitive: false);

  /// Streng: fehlt oder passt ein Feld nicht, gibt es kein Konto.
  static AccountInfo? tryParse(Object? body) {
    if (body is! Map) return null;
    final id = body['account_id'];
    final plan = body['plan_key'];
    final status = body['status'];
    final created = body['created'];
    if (id is! String || !_uuid.hasMatch(id)) return null;
    if (plan is! String || plan.isEmpty) return null;
    if (status is! String || status.isEmpty) return null;
    if (created is! bool) return null;
    return AccountInfo(accountId: id, planKey: plan, status: status, created: created);
  }
}

enum AccountPhase {
  /// Login ist in diesem Build nicht eingerichtet.
  disabled,

  /// Niemand angemeldet.
  signedOut,

  /// Anmeldung da, Konto wird beim Proxy angefragt.
  loading,

  /// Proxy hat das Konto bestätigt.
  ready,

  /// Angemeldet, aber kein bestätigtes Konto. Kein Ersatz-Plan.
  error,
}

enum AccountErrorKind {
  /// 401: Token abgelehnt (abgelaufen, widerrufen, falsches Projekt).
  sessionRejected,

  /// 403: z. B. anonymer Nutzer oder nicht erlaubte Herkunft.
  forbidden,

  /// 429 oder 5xx: Proxy/Datenbank gerade nicht verfügbar.
  unavailable,

  /// Keine Verbindung zum Proxy.
  network,

  /// Proxy in diesem Build nicht eingerichtet.
  notConfigured,

  /// Antwort ohne gültige Kontodaten.
  invalidResponse,
}

@immutable
class AccountState {
  const AccountState._(this.phase, {this.info, this.error});

  const AccountState.disabled() : this._(AccountPhase.disabled);
  const AccountState.signedOut() : this._(AccountPhase.signedOut);
  const AccountState.loading() : this._(AccountPhase.loading);
  const AccountState.ready(AccountInfo info) : this._(AccountPhase.ready, info: info);
  const AccountState.failed(AccountErrorKind error) : this._(AccountPhase.error, error: error);

  final AccountPhase phase;

  /// Nur in [AccountPhase.ready] gesetzt.
  final AccountInfo? info;

  /// Nur in [AccountPhase.error] gesetzt.
  final AccountErrorKind? error;
}

/// Aufruf von POST /api/account/bootstrap; austauschbar für Tests.
typedef BootstrapCall = Future<({int status, Object? body})> Function(String accessToken);

/// Verbindet die Anmeldung mit dem Konto beim Proxy.
///
/// Nach einem Login und nach einer wiederhergestellten Sitzung wird genau
/// einmal je Nutzer der idempotente Bootstrap aufgerufen. Anmelde- und
/// Kontozustand bleiben getrennt: ein angemeldeter Nutzer ohne bestätigtes
/// Konto ist [AccountPhase.error] – nie stillschweigend "Free".
class AccountService {
  AccountService({required AuthService auth, BootstrapCall? bootstrap})
      : _auth = auth,
        _bootstrap = bootstrap ?? proxyAccountBootstrap {
    if (!auth.enabled) {
      _state.value = const AccountState.disabled();
      return;
    }
    auth.user.addListener(_onUserChanged);
    _onUserChanged();
  }

  final AuthService _auth;
  final BootstrapCall _bootstrap;
  final ValueNotifier<AccountState> _state =
      ValueNotifier<AccountState>(const AccountState.signedOut());

  /// Nutzer, für den der aktuelle Zustand gilt.
  String? _userId;

  /// Jeder neue Lauf und jedes Abmelden erhöht die Nummer. Eine Antwort, die
  /// danach eintrifft, gehört zu einem überholten Zustand und wird verworfen.
  int _generation = 0;

  ValueListenable<AccountState> get state => _state;

  void _onUserChanged() {
    final user = _auth.user.value;
    if (user == null) {
      _userId = null;
      _generation++;
      _state.value = const AccountState.signedOut();
      return;
    }
    final phase = _state.value.phase;
    if (user.id == _userId && (phase == AccountPhase.ready || phase == AccountPhase.loading)) {
      return; // gleicher Nutzer, z. B. nur Token aufgefrischt
    }
    _userId = user.id;
    unawaited(_run());
  }

  /// Erneut versuchen, etwa nach einem Fehler. Idempotent beim Proxy.
  Future<void> retry() async {
    if (_auth.user.value == null) return;
    await _run();
  }

  Future<void> _run() async {
    final generation = ++_generation;
    final token = _auth.accessToken;
    if (token == null) {
      _state.value = const AccountState.failed(AccountErrorKind.sessionRejected);
      return;
    }
    _state.value = const AccountState.loading();

    AccountState next;
    try {
      final res = await _bootstrap(token);
      next = _interpret(res.status, res.body);
    } on ProxyNotConfiguredException {
      next = const AccountState.failed(AccountErrorKind.notConfigured);
    } catch (_) {
      // Bewusst ohne Details: die könnten Adresse oder Token enthalten.
      next = const AccountState.failed(AccountErrorKind.network);
    }
    if (generation != _generation) return;
    _state.value = next;
  }

  static AccountState _interpret(int status, Object? body) {
    if (status == 200) {
      final info = AccountInfo.tryParse(body);
      return info == null
          ? const AccountState.failed(AccountErrorKind.invalidResponse)
          : AccountState.ready(info);
    }
    if (status == 401) return const AccountState.failed(AccountErrorKind.sessionRejected);
    if (status == 403) return const AccountState.failed(AccountErrorKind.forbidden);
    if (status == 429 || status >= 500) {
      return const AccountState.failed(AccountErrorKind.unavailable);
    }
    return const AccountState.failed(AccountErrorKind.invalidResponse);
  }

  void dispose() {
    _auth.user.removeListener(_onUserChanged);
    _generation++;
    _state.dispose();
  }
}
