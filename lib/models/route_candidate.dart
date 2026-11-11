import 'package:latlong2/latlong.dart';

import '../utils/polyline.dart';

/// Eine von Google gelieferte Routenvariante inklusive Geometrie.
///
/// Die Geometrie wird pro Leg vorgehalten, damit die automatische Ländersperre
/// weiß, zwischen welchen Wegpunkten ein gesperrtes Land durchfahren wird.
class RouteCandidate {
  final double km;
  final double sec;
  final List<Map<String, dynamic>> steps;
  final List<String> warnings;

  /// Geometrie je Leg (Leg i = zwischen Wegpunkt i und i+1).
  final List<List<LatLng>> legPoints;

  final Map<String, dynamic> raw;

  RouteCandidate({
    required this.km,
    required this.sec,
    required this.steps,
    required this.warnings,
    required this.legPoints,
    required this.raw,
  });

  /// Gesamte Routengeometrie am Stück.
  List<LatLng> get points => [for (final l in legPoints) ...l];

  static RouteCandidate fromRouteJson(Map<String, dynamic> route) {
    final legs = ((route['legs'] as List?) ?? const []).cast<Map<String, dynamic>>();
    double meters = 0, seconds = 0;
    final steps = <Map<String, dynamic>>[];
    final legPoints = <List<LatLng>>[];

    for (final l in legs) {
      meters += ((l['distance']?['value'] ?? 0) as num).toDouble();
      seconds += ((l['duration']?['value'] ?? 0) as num).toDouble();
      final ls = ((l['steps'] as List?) ?? const []).cast<Map<String, dynamic>>();
      steps.addAll(ls);

      final pts = <LatLng>[];
      for (final st in ls) {
        final enc = (st['polyline'] is Map) ? st['polyline']['points'] : null;
        if (enc is String && enc.isNotEmpty) pts.addAll(decodePolyline(enc));
      }
      if (pts.isEmpty) {
        // Fallback: Overview-Polyline, falls keine Step-Geometrie geliefert wurde.
        final ov = (route['overview_polyline'] is Map)
            ? route['overview_polyline']['points']
            : null;
        if (ov is String && ov.isNotEmpty && legs.length == 1) {
          pts.addAll(decodePolyline(ov));
        }
      }
      legPoints.add(pts);
    }

    final w = route['warnings'];
    return RouteCandidate(
      km: meters / 1000.0,
      sec: seconds,
      steps: steps,
      warnings: w is List ? w.map((e) => e.toString()).toList() : const [],
      legPoints: legPoints,
      raw: route,
    );
  }

  static List<RouteCandidate> allFromResponse(Map<String, dynamic> data) {
    final routes = (data['routes'] as List?) ?? const [];
    return routes
        .whereType<Map<String, dynamic>>()
        .map(RouteCandidate.fromRouteJson)
        .toList();
  }
}
