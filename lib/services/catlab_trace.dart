import 'package:uuid/uuid.dart';

/// Ordnet die Google-Aufrufe einer einzelnen Routenberechnung zusammen.
///
/// Der Proxy sieht nur einzelne HTTP-Anfragen und kann von sich aus nicht
/// wissen, welche davon zur selben Berechnung gehören. Deshalb vergibt die App
/// beim Start einer Berechnung eine Kennung und legt sie jeder Anfrage bei.
///
/// Bewusst ein globaler Zustand und kein durchgereichter Parameter: die
/// Aufrufe verteilen sich über DistanceService, FerryAutoDetect, FerryLegPlan
/// und GeocodingService. Sie alle um einen Parameter zu erweitern, hieße acht
/// Dateien für eine reine Messung anzufassen. Die App rechnet immer nur eine
/// Route auf einmal – `_compute` steigt aus, solange `_calculating` läuft –,
/// deshalb genügt hier ein einzelner Wert.
///
/// Enthält ausschließlich eine Zufallskennung und eine Gattung. Keine
/// Adressen, keine Suchtexte, nichts über die Fahrt selbst.
class CatLabTrace {
  CatLabTrace._();

  static const _uuid = Uuid();

  static String? _workUnitId;
  static String _kind = kindRoute;

  /// Gewöhnliche Straßenroute.
  static const String kindRoute = 'route';

  /// Route mit Fährpassage: zwei getrennte Landwege plus Fährsuche, also
  /// deutlich mehr Google-Aufrufe als bei einer durchgehenden Strecke.
  static const String kindFerry = 'route_ferry';

  static String? get workUnitId => _workUnitId;
  static String get kind => _kind;

  /// Beginnt eine Berechnung. Alles, was danach über den Proxy läuft, zählt
  /// dazu, bis [end] aufgerufen wird.
  static void begin() {
    _workUnitId = _uuid.v4();
    _kind = kindRoute;
  }

  /// Stuft die laufende Berechnung als Fährroute ein. Wird erst klar, wenn
  /// eine Fähre gefunden wurde – also nach dem Start.
  static void markFerry() {
    if (_workUnitId != null) _kind = kindFerry;
  }

  /// Beendet die Berechnung. Danach getätigte Aufrufe – etwa die
  /// Adressvervollständigung beim Tippen – gehören zu keiner Berechnung.
  static void end() {
    _workUnitId = null;
    _kind = kindRoute;
  }

  /// Die Felder, die jeder Proxy-Anfrage beigelegt werden. Leer, solange
  /// keine Berechnung läuft.
  static Map<String, String> get requestFields {
    final id = _workUnitId;
    if (id == null) return const {};
    return {'cc_work_unit': id, 'cc_work_kind': _kind};
  }
}
