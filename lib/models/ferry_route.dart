import 'dart:convert';

class FerryRoute {
  final String id;
  final String name;
  final String from;
  final String to;
  final List<String> operators;
  final double durationHours;
  final List<String> departuresLocal;
  final Map<int, List<String>> departuresByWeekday;
  final String tz;
  final String region;
  final bool active;
  final String notes;

  FerryRoute({
    required this.id,
    required this.name,
    required this.from,
    required this.to,
    required this.operators,
    required this.durationHours,
    required this.departuresLocal,
    this.departuresByWeekday = const {},
    required this.tz,
    required this.region,
    required this.active,
    required this.notes,
  });

  factory FerryRoute.fromJson(Map<String, dynamic> j) {
    final weekdayRaw = j['departures_by_weekday'];
    final departuresByWeekday = <int, List<String>>{};
    if (weekdayRaw is Map) {
      for (final entry in weekdayRaw.entries) {
        final weekday = int.tryParse(entry.key.toString());
        if (weekday == null || weekday < 1 || weekday > 7) continue;
        final values = entry.value;
        if (values is List) {
          departuresByWeekday[weekday] =
              values.map((value) => value.toString()).toList();
        }
      }
    }
    return FerryRoute(
      id: j['id'],
      name: j['name'],
      from: j['from'],
      to: j['to'],
      operators: (j['operators'] as List).map((e) => e.toString()).toList(),
      durationHours: (j['duration_hours'] as num).toDouble(),
      departuresLocal:
          (j['departures_local'] as List).map((e) => e.toString()).toList(),
      departuresByWeekday: departuresByWeekday,
      tz: j['tz'],
      region: j['region'],
      active: j['active'] == true,
      notes: j['notes'] ?? '',
    );
  }

  static List<FerryRoute> listFromJson(String raw) {
    final root = jsonDecode(raw) as Map<String, dynamic>;
    final routes =
        (root['routes'] as List).map((e) => FerryRoute.fromJson(e)).toList();
    return routes;
  }
}
