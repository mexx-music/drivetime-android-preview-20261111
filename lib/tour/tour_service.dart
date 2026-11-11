import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';

import '../account/account_service.dart';
import '../auth/auth_service.dart';
import '../services/maps_proxy.dart';

enum TourFailureKind {
  notSignedIn,
  accountNotReady,
  quotaNotConfigured,
  quotaExhausted,
  callBudgetExhausted,

  /// Tour abgelaufen, abgeschlossen, freigegeben oder unbekannt.
  tourUnavailable,

  /// Token abgelehnt, abgemeldet oder Nutzer gewechselt.
  sessionInvalid,
  forbidden,

  /// Proxy oder Datenbank gerade nicht verfügbar (auch Not-Aus, Rate-Limit).
  unavailable,
  network,
  invalidResponse,
}

/// Grund, warum eine Berechnung im Tour-Modus nicht (weiter) laufen darf.
/// Es gibt dann KEINEN Ausweg ohne Tour.
class TourFailure implements Exception {
  const TourFailure(this.kind);

  final TourFailureKind kind;

  String get message => switch (kind) {
        TourFailureKind.notSignedIn => 'Bitte anmelden, um zu rechnen.',
        TourFailureKind.accountNotReady =>
          'Dein Konto ist noch nicht bereit. Bitte kurz warten oder erneut anmelden.',
        TourFailureKind.quotaNotConfigured =>
          'Für deinen Plan sind noch keine Tourenplanungen freigeschaltet.',
        TourFailureKind.quotaExhausted =>
          'Dein Kontingent an Tourenplanungen ist für diesen Zeitraum aufgebraucht.',
        TourFailureKind.callBudgetExhausted =>
          'Diese Berechnung hat ihr Abfragebudget ausgeschöpft.',
        TourFailureKind.tourUnavailable =>
          'Die Berechnung ist abgelaufen. Bitte erneut starten.',
        TourFailureKind.sessionInvalid => 'Anmeldung abgelaufen. Bitte neu anmelden.',
        TourFailureKind.forbidden => 'Keine Berechtigung für diese Berechnung.',
        TourFailureKind.unavailable =>
          'Tourenplanung gerade nicht verfügbar. Bitte später erneut versuchen.',
        TourFailureKind.network => 'Keine Verbindung. Bitte später erneut versuchen.',
        TourFailureKind.invalidResponse =>
          'Unerwartete Antwort des Servers. Bitte später erneut versuchen.',
      };

  @override
  String toString() => 'TourFailure($kind)';

  /// Ablehnung eines Maps-Aufrufs durch die Kostenkontrolle des Proxys.
  /// null = keine Ablehnung der Kostenkontrolle (z. B. ein Google-Fehler).
  static TourFailure? fromMapsRejection(int status, Object? body) {
    final code = body is Map ? body['error'] : null;
    switch (status) {
      case 401:
        return const TourFailure(TourFailureKind.sessionInvalid);
      case 403:
        return const TourFailure(TourFailureKind.forbidden);
      case 404:
      case 409:
      case 428:
        return const TourFailure(TourFailureKind.tourUnavailable);
      case 429:
        return code == 'call_budget_exhausted'
            ? const TourFailure(TourFailureKind.callBudgetExhausted)
            : const TourFailure(TourFailureKind.unavailable);
      case 503:
        return const TourFailure(TourFailureKind.unavailable);
    }
    return null;
  }
}

/// Die vom Proxy bestätigte Tour einer Berechnung.
@immutable
class TourTicket {
  const TourTicket({
    required this.tourId,
    required this.idempotencyKey,
    required this.userId,
  });

  /// Ausschließlich vom Proxy geliefert.
  final String tourId;
  final String idempotencyKey;
  final String userId;
}

/// Aufruf eines geschützten Proxy-Endpunkts; austauschbar für Tests.
typedef AuthedPost = Future<({int status, Object? body})> Function(
    String path, Map<String, Object?> body, String accessToken);

/// Tour-Lebenszyklus beim Proxy: reservieren, abschließen, freigeben.
///
/// Eine Berechnung = eine Tour. Der Idempotenzschlüssel bleibt stabil, solange
/// dieselbe Berechnung (gleiche Eingaben, gleicher Nutzer) nicht abgeschlossen
/// oder freigegeben ist – ein Wiederholen nach einem Fehler bekommt also
/// dieselbe Tour. Nach einem Abschluss oder einer Freigabe gibt es für die
/// nächste Berechnung einen neuen Schlüssel und damit eine neue Tour.
///
/// Nutzer, Konto, Plan, Budget, Kontingent und Tourzustand bestimmt allein
/// der Proxy. Der Client schickt nur den Schlüssel.
class TourService {
  TourService({
    required AuthService auth,
    required AccountService account,
    AuthedPost? post,
  })  : _auth = auth,
        _account = account,
        _post = post ?? proxyAuthedPost;

  final AuthService _auth;
  final AccountService _account;
  final AuthedPost _post;
  static const _uuid = Uuid();

  // Offene Berechnung: Schlüssel, Eingaben und Nutzer, bis sie abgeschlossen
  // oder freigegeben ist.
  String? _pendingKey;
  String? _pendingInputs;
  String? _pendingUser;

  static final _uuidPattern = RegExp(
      r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$',
      caseSensitive: false);

  /// Muss die Berechnung in einer Tour laufen? Ja, sobald jemand angemeldet
  /// ist. Ohne Login-Konfiguration oder ohne Anmeldung: öffentlicher Modus
  /// wie bisher (der Proxy verlangt dort noch keine Tour).
  bool get required => _auth.enabled && _auth.user.value != null;

  /// Token für Aufrufe dieser Tour – nur solange derselbe Nutzer angemeldet ist.
  String? tokenFor(TourTicket ticket) =>
      _auth.user.value?.id == ticket.userId ? _auth.accessToken : null;

  /// Reserviert die Tour für eine Berechnung mit den Eingaben [inputs].
  /// Wirft [TourFailure]; dann darf nicht gerechnet werden.
  Future<TourTicket> begin(String inputs) async {
    final user = _auth.user.value;
    if (user == null) throw const TourFailure(TourFailureKind.notSignedIn);
    if (_account.state.value.phase != AccountPhase.ready) {
      throw const TourFailure(TourFailureKind.accountNotReady);
    }
    if (_pendingKey == null || _pendingUser != user.id || _pendingInputs != inputs) {
      _pendingKey = _uuid.v4();
      _pendingUser = user.id;
      _pendingInputs = inputs;
    }

    // Höchstens einmal neu reservieren: wenn die offene Tour inzwischen
    // abgelaufen oder beendet ist, gehört sie nicht mehr zu einer Berechnung.
    for (var attempt = 0; attempt < 2; attempt++) {
      final result = await _reserve(user.id, _pendingKey!);
      if (result != null) return result;
      _pendingKey = _uuid.v4();
    }
    throw const TourFailure(TourFailureKind.tourUnavailable);
  }

  /// Merkt sich die Eingaben nach einer fehlgeschlagenen Berechnung. Die App
  /// ersetzt beim Rechnen Freitext durch die aufgelöste Adresse – ein
  /// Wiederholen soll trotzdem als dieselbe Berechnung gelten.
  void rememberInputs(TourTicket ticket, String inputs) {
    if (_pendingKey == ticket.idempotencyKey) _pendingInputs = inputs;
  }

  /// null = die gefundene Tour ist beendet, neuer Schlüssel nötig.
  Future<TourTicket?> _reserve(String userId, String key) async {
    final token = _auth.accessToken;
    if (token == null) throw const TourFailure(TourFailureKind.sessionInvalid);
    final ({int status, Object? body}) res;
    try {
      res = await _post('/api/tours', {'idempotency_key': key}, token);
    } on ProxyNotConfiguredException {
      throw const TourFailure(TourFailureKind.unavailable);
    } catch (_) {
      // Ob die Tour angelegt wurde, ist offen. Der Schlüssel bleibt – ein
      // Wiederholen bekommt dieselbe Tour statt einer zweiten.
      throw const TourFailure(TourFailureKind.network);
    }
    // Inzwischen abgemeldet oder anderer Nutzer: Antwort gehört nicht mehr hierher.
    if (_auth.user.value?.id != userId) {
      throw const TourFailure(TourFailureKind.sessionInvalid);
    }

    final body = res.body;
    final code = body is Map ? body['error'] : null;
    switch (res.status) {
      case 200:
      case 201:
        return _ticketFrom(body, key, userId);
      case 401:
        throw const TourFailure(TourFailureKind.sessionInvalid);
      case 402:
        throw const TourFailure(TourFailureKind.quotaExhausted);
      case 403:
        throw TourFailure(code == 'quota_not_configured'
            ? TourFailureKind.quotaNotConfigured
            : TourFailureKind.forbidden);
      case 409:
        _pendingKey = null; // Schlüssel passt nicht mehr, nicht wiederverwenden
        throw const TourFailure(TourFailureKind.invalidResponse);
      case 429:
      case 503:
        throw const TourFailure(TourFailureKind.unavailable);
    }
    throw const TourFailure(TourFailureKind.invalidResponse);
  }

  TourTicket? _ticketFrom(Object? body, String key, String userId) {
    if (body is! Map) throw const TourFailure(TourFailureKind.invalidResponse);
    final id = body['tour_id'];
    final state = body['state'];
    final completed = body['completed'];
    final expires = DateTime.tryParse('${body['expires_at']}');
    if (id is! String || !_uuidPattern.hasMatch(id) ||
        state is! String || completed is! bool || expires == null) {
      throw const TourFailure(TourFailureKind.invalidResponse);
    }
    if (state == 'released' || completed || !expires.isAfter(DateTime.now())) {
      return null;
    }
    if (state != 'reserved' && state != 'consumed') {
      throw const TourFailure(TourFailureKind.invalidResponse);
    }
    return TourTicket(tourId: id.toLowerCase(), idempotencyKey: key, userId: userId);
  }

  /// Nach der Berechnung. Erfolg → abschließen; sonst freigeben, falls der
  /// Proxy das zulässt (nur ohne erfolgreichen Aufruf). Wirft nie.
  Future<void> finish(TourTicket ticket, {required bool success}) async {
    final token = tokenFor(ticket);
    if (token == null) {
      // Abgemeldet oder Nutzer gewechselt: nichts mehr zu tun, die Tour
      // läuft beim Server ab. Die offene Berechnung gehört nicht mehr zu uns.
      if (_pendingUser != _auth.user.value?.id) _clearPending();
      return;
    }
    try {
      if (success) {
        final r = await _post('/api/tours/${ticket.tourId}/complete', const {}, token);
        if (r.status == 200) return _clearPending(ticket);
        if (r.status == 409 && _code(r.body) == 'not_consumed') {
          await _release(ticket, token);
        }
        return;
      }
      await _release(ticket, token);
    } catch (_) {
      // Offen lassen: ein Wiederholen bekommt dieselbe Tour.
    }
  }

  Future<void> _release(TourTicket ticket, String token) async {
    final r = await _post('/api/tours/${ticket.tourId}/release', const {}, token);
    // Freigegeben: die nächste Berechnung bekommt eine neue Tour.
    // Verbraucht (409 consumed): Schlüssel behalten – ein Wiederholen läuft
    // in derselben, schon bezahlten Tour weiter.
    if (r.status == 200) _clearPending(ticket);
  }

  static Object? _code(Object? body) => body is Map ? body['error'] : null;

  void _clearPending([TourTicket? ticket]) {
    if (ticket != null && ticket.idempotencyKey != _pendingKey) return;
    _pendingKey = null;
    _pendingInputs = null;
    _pendingUser = null;
  }

  /// Nur für Tests.
  @visibleForTesting
  String? get pendingKey => _pendingKey;
}
