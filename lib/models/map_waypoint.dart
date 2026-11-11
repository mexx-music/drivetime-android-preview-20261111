import 'package:latlong2/latlong.dart';

/// Ein auf der Karte gewählter Zwischenpunkt.
///
/// Zwischenstopps sind in der App Texte (Liste, Sortieren, Löschen,
/// Routen-Vorlagen). Ein Kartenpunkt trägt seine Koordinate deshalb im Text:
///
///   „📍 Kartenpunkt · Griechenland @40.640120,22.944410“
///
/// Maßgeblich ist die Koordinate – sie geht unverändert als `lat,lng` an
/// Directions, ein Ortsname ist nicht nötig und wird nicht abgefragt. Angezeigt
/// wird nur der Teil vor dem `@`.
///
/// Später lässt sich hier unterscheiden, ob der Punkt nur Via-Punkt (Route
/// führt hier entlang, `via:lat,lng`) oder echter Tour-Stopp mit Standzeit ist.
class MapWaypoint {
  MapWaypoint._();

  static const prefix = '📍 Kartenpunkt';
  static final _coords = RegExp(r' @(-?\d{1,3}(?:\.\d+)?),(-?\d{1,3}(?:\.\d+)?)$');

  /// Text für die Stoppliste; [country] aus den lokalen Grenzdaten.
  static String label(LatLng p, {String? country}) =>
      '$prefix${country == null || country.isEmpty ? '' : ' · $country'}'
      ' @${p.latitude.toStringAsFixed(6)},${p.longitude.toStringAsFixed(6)}';

  /// Koordinate eines Kartenpunkts; null bei einem normalen Text-Stopp.
  static LatLng? parse(String label) {
    if (!label.startsWith(prefix)) return null;
    final m = _coords.firstMatch(label);
    if (m == null) return null;
    final lat = double.tryParse(m.group(1)!);
    final lng = double.tryParse(m.group(2)!);
    if (lat == null || lng == null || lat.abs() > 90 || lng.abs() > 180) return null;
    return LatLng(lat, lng);
  }

  static bool isMapPoint(String label) => parse(label) != null;

  /// Anzeige ohne Koordinate: „📍 Kartenpunkt · Griechenland“.
  static String display(String label) =>
      isMapPoint(label) ? label.replaceFirst(_coords, '') : label;

  /// Kurze Koordinate für eine Detailzeile: „40.6401, 22.9444“.
  static String? shortCoordinates(String label) {
    final p = parse(label);
    if (p == null) return null;
    return '${p.latitude.toStringAsFixed(4)}, ${p.longitude.toStringAsFixed(4)}';
  }

  /// Was an Directions geht: Kartenpunkt als `lat,lng`, sonst der Text.
  static String routing(String label) {
    final p = parse(label);
    if (p == null) return label;
    return '${p.latitude.toStringAsFixed(6)},${p.longitude.toStringAsFixed(6)}';
  }
}
