import 'tour_service.dart';

/// Tour der gerade laufenden Berechnung, für die Proxy-Aufrufe.
///
/// Wie [CatLabTrace] bewusst global: die kostenpflichtigen Aufrufe einer
/// Berechnung verteilen sich über DistanceService, FerryAutoDetect,
/// FerryLegPlan und GeocodingService. Es läuft immer nur eine Berechnung
/// (`_compute` steigt aus, solange eine läuft).
///
/// Im Tour-Modus gilt ohne Ausnahme:
///  * jeder Directions-/Geocoding-Aufruf trägt tour_id und Token,
///  * nach der ersten Ablehnung der Kostenkontrolle geht kein weiterer Aufruf
///    mehr hinaus – auch keiner ohne Tour,
///  * fehlt das Token (abgemeldet, Nutzerwechsel), geht nichts hinaus.
/// Die aufrufende Stelle darf solche Fehler schlucken wie bisher; die
/// Berechnung prüft vor dem Ergebnis [throwIfFailed].
class TourScope {
  TourScope._();

  static int _generation = 0;
  static String? _tourId;
  static String? Function()? _token;
  static TourFailure? _failure;

  static bool get active => _tourId != null;
  static TourFailure? get failure => _failure;

  /// Beginnt die Tour einer Berechnung.
  static void enter(String tourId, String? Function() token) {
    _generation++;
    _tourId = tourId;
    _token = token;
    _failure = null;
  }

  /// Beendet sie. Späte Antworten der alten Berechnung wirken danach nicht mehr.
  static void exit() {
    _generation++;
    _tourId = null;
    _token = null;
    _failure = null;
  }

  /// Für einen kostenpflichtigen Aufruf. null = kein Tour-Modus.
  /// Wirft [TourFailure], wenn im Tour-Modus nichts mehr hinausgehen darf.
  static TourCall? forCall() {
    final id = _tourId;
    if (id == null) return null;
    final failed = _failure;
    if (failed != null) throw failed;
    final token = _token?.call();
    if (token == null) {
      _failure = const TourFailure(TourFailureKind.sessionInvalid);
      throw _failure!;
    }
    return TourCall._(_generation, id, token);
  }

  /// Antwort eines Aufrufs dieser Tour, der nicht 200 war.
  static void recordRejection(TourCall call, int status, Object? body) {
    if (call._generation != _generation) return; // alte Berechnung
    _failure ??= TourFailure.fromMapsRejection(status, body);
  }

  static void throwIfFailed() {
    final failed = _failure;
    if (failed != null) throw failed;
  }
}

/// Zusätze für genau einen Aufruf.
class TourCall {
  TourCall._(this._generation, this.tourId, this._token);

  final int _generation;
  final String tourId;
  final String _token;

  Map<String, String> get fields => {'tour_id': tourId};
  Map<String, String> get headers => {'Authorization': 'Bearer $_token'};
}
