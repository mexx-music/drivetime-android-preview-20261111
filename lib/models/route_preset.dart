import 'dart:convert';

/// Eine gespeicherte Wegpunkt-Folge für eine wiederkehrende Strecke.
///
/// Hintergrund: Google Directions kennt kein LKW-Profil. Für Korridore, die
/// ein Fahrer besser kennt als jeder Routenplaner (z. B. Griechenland →
/// Österreich östlich an Ex-Jugoslawien vorbei, oder Bulgarien über Botevgrad
/// statt über den Petrohan-Pass), sind selbst gesetzte Punkte zuverlässiger
/// als jede Automatik.
class RoutePreset {
  final String id;
  final String name;

  /// Zwischenstopps in Fahrtreihenfolge.
  final List<String> stops;

  const RoutePreset({
    required this.id,
    required this.name,
    required this.stops,
  });

  /// Dieselbe Strecke in Gegenrichtung.
  RoutePreset get reversed => RoutePreset(
        id: id,
        name: name,
        stops: stops.reversed.toList(growable: false),
      );

  /// Kurzvorschau für die Liste: "Kulata → Botevgrad → Calafat → Nadlac".
  String get preview => stops.map(_shortLabel).join(' → ');

  static String _shortLabel(String stop) {
    final first = stop.split(',').first.trim();
    return first.isEmpty ? stop.trim() : first;
  }

  Map<String, dynamic> toJson() => {'id': id, 'name': name, 'stops': stops};

  static RoutePreset? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final id = (raw['id'] ?? '').toString();
    final name = (raw['name'] ?? '').toString();
    final stops = (raw['stops'] as List?)
            ?.map((e) => e.toString())
            .where((e) => e.trim().isNotEmpty)
            .toList() ??
        const <String>[];
    if (id.isEmpty || name.isEmpty || stops.isEmpty) return null;
    return RoutePreset(id: id, name: name, stops: stops);
  }

  static String encodeList(List<RoutePreset> list) =>
      jsonEncode(list.map((e) => e.toJson()).toList());

  static List<RoutePreset> decodeList(String? raw) {
    if (raw == null || raw.trim().isEmpty) return const [];
    try {
      final data = jsonDecode(raw);
      if (data is! List) return const [];
      return data
          .map(RoutePreset.fromJson)
          .whereType<RoutePreset>()
          .toList(growable: false);
    } catch (_) {
      return const [];
    }
  }
}
