import 'dart:convert';

/// Eingaben einer berechneten Tour – genug, um sie nach einem unerwarteten
/// Neuladen (z. B. Safari beendet die Seite während der 2.5D-Tour) wieder
/// herzustellen. Bewusst nur der Tourzustand: keine Kartenkacheln, keine
/// Fahrzeugbilder, keine berechneten Ergebnisse.
///
/// Bleibt nur auf diesem Gerät (lokaler Speicher des Browsers).
class TourDraft {
  const TourDraft({
    required this.start,
    required this.dest,
    this.startLat,
    this.startLng,
    this.destLat,
    this.destLng,
    this.stops = const [],
    this.stopCoords = const [],
    required this.settings,
    required this.savedAt,
  });

  static const int version = 1;

  final String start;
  final String dest;
  final double? startLat, startLng, destLat, destLng;

  /// Zwischenstopps in Reihenfolge (Text wie im Formular) und – soweit
  /// aufgelöst – ihre Koordinaten ([lat, lng] oder null).
  final List<String> stops;
  final List<List<double>?> stopCoords;

  /// Übrige Formularwerte (Zeitbudget, Lenk-/Ruhezeiten, Abfahrt, Fähre,
  /// Geschwindigkeit) als einfache Werte.
  final Map<String, Object?> settings;

  final DateTime savedAt;

  Map<String, Object?> toJson() => {
        'v': version,
        'start': start,
        'dest': dest,
        'startLat': startLat,
        'startLng': startLng,
        'destLat': destLat,
        'destLng': destLng,
        'stops': stops,
        'stopCoords': stopCoords,
        'settings': settings,
        'savedAt': savedAt.toIso8601String(),
      };

  String encode() => jsonEncode(toJson());

  /// null bei fehlenden, kaputten oder fremden Daten (andere Version).
  static TourDraft? decode(String? raw) {
    if (raw == null || raw.isEmpty) return null;
    try {
      final j = jsonDecode(raw) as Map<String, dynamic>;
      if (j['v'] != version) return null;
      double? d(Object? v) => v is num ? v.toDouble() : null;
      return TourDraft(
        start: j['start'] as String? ?? '',
        dest: j['dest'] as String? ?? '',
        startLat: d(j['startLat']),
        startLng: d(j['startLng']),
        destLat: d(j['destLat']),
        destLng: d(j['destLng']),
        stops: [for (final s in (j['stops'] as List? ?? const [])) s as String],
        stopCoords: [
          for (final c in (j['stopCoords'] as List? ?? const []))
            c is List && c.length == 2 ? [d(c[0])!, d(c[1])!] : null,
        ],
        settings: Map<String, Object?>.from(j['settings'] as Map? ?? const {}),
        savedAt: DateTime.tryParse(j['savedAt'] as String? ?? '') ?? DateTime.fromMillisecondsSinceEpoch(0),
      );
    } catch (_) {
      return null;
    }
  }

  /// Hat die Tour genug, um sie wiederherzustellen?
  bool get usable => start.trim().isNotEmpty && dest.trim().isNotEmpty;
}
