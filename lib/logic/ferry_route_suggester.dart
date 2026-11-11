import '../models/ferry_route.dart';
import 'ferry_schedule.dart';

typedef RoadDistanceLookup = Future<double?> Function(
  String origin,
  String destination,
);

class FerryRouteException implements Exception {
  final String message;
  const FerryRouteException(this.message);

  @override
  String toString() => message;
}

class FerryRouteSuggestion {
  final FerryRoute route;
  final double kmBefore;
  final double kmAfter;

  const FerryRouteSuggestion(this.route, this.kmBefore, this.kmAfter);

  double get roadKm => kmBefore + kmAfter;
}

/// Finds a plausible ferry without requiring port waypoints.
/// Only routes with measurable road legs are eligible; sailing times come
/// from the bundled indicative timetable, not a live booking service.
class FerryRouteSuggester {
  static const _greekPorts = {'igoumenitsa', 'patras'};
  static const _italianPorts = {'bari', 'brindisi', 'ancona', 'venedig'};
  static const _germanPorts = {'kiel', 'travemünde', 'rostock'};
  static const _nordicPorts = {'trelleborg', 'malmö', 'göteborg', 'oslo'};

  static bool supportsTrip(String origin, String destination) =>
      isGreekItalianTrip(origin, destination) ||
      isNorthernTrip(origin, destination);

  static bool isGreekItalianTrip(String origin, String destination) {
    final a = origin.toLowerCase();
    final b = destination.toLowerCase();
    return (_isGreek(a) && _isItalian(b)) || (_isItalian(a) && _isGreek(b));
  }

  static bool isNorthernTrip(String origin, String destination) {
    final a = origin.toLowerCase();
    final b = destination.toLowerCase();
    return (_isGermanOrAustrian(a) && _isNordic(b)) ||
        (_isNordic(a) && _isGermanOrAustrian(b));
  }

  static bool _isGermanOrAustrian(String text) => _hasAny(text, [
        'germany',
        'deutschland',
        'austria',
        'österreich',
        'vienna',
        'wien',
        'hamburg',
        'kiel',
        'travemünde',
        'travemuende',
        'rostock',
        'lübeck',
        'luebeck',
      ]);

  static bool _isNordic(String text) => _hasAny(text, [
        'sweden',
        'schweden',
        'sverige',
        'norway',
        'norwegen',
        'norge',
        'trelleborg',
        'malmö',
        'malmo',
        'göteborg',
        'goteborg',
        'gothenburg',
        'oslo',
      ]);

  static bool _hasAny(String text, List<String> words) =>
      words.any(text.contains);

  static bool _isGreek(String text) => _hasAny(text, [
        'greece',
        'griechenland',
        'ελλάδα',
        'thessaloniki',
        'tessaloniki',
        'θεσσαλονίκη',
        'θεσσαλονικη',
        'saloniki',
        'athens',
        'athen',
        'igoumenitsa',
        'patras',
      ]);

  static bool _isItalian(String text) =>
      text.trim() == 'rom' ||
      _hasAny(text, [
        'italy',
        'italien',
        'italia',
        'rome',
        'roma',
        'rom,',
        'bari',
        'brindisi',
        'ancona',
        'venedig',
        'venice',
        'venezia',
      ]);

  static Future<FerryRouteSuggestion?> suggest({
    required String origin,
    required String destination,
    required List<FerryRoute> routes,
    required RoadDistanceLookup roadDistance,
    double assumedKmh = 80,

    /// Abfahrtszeitpunkt der Tour. Ist er bekannt, entscheidet die tatsächlich
    /// nächste Abfahrt – sonst nur die Überfahrtsdauer. Auf Strecken mit
    /// mehreren Betreibern (z. B. Rostock–Trelleborg) hing die Wahl sonst
    /// allein an der Reihenfolge im Fahrplan, obwohl die andere Reederei
    /// Stunden früher ablegt.
    DateTime? startTime,
  }) async {
    if (!supportsTrip(origin, destination)) return null;
    final southern = isGreekItalianTrip(origin, destination);
    final outbound = southern
        ? _isItalian(destination.toLowerCase())
        : _isNordic(destination.toLowerCase());
    final fromPorts = southern
        ? (outbound ? _greekPorts : _italianPorts)
        : (outbound ? _germanPorts : _nordicPorts);
    final toPorts = southern
        ? (outbound ? _italianPorts : _greekPorts)
        : (outbound ? _nordicPorts : _germanPorts);
    final candidates = routes
        .where((route) =>
            route.active &&
            fromPorts.contains(route.from.toLowerCase()) &&
            toPorts.contains(route.to.toLowerCase()))
        .toList();
    if (candidates.isEmpty) return null;

    final departures = candidates.map((r) => r.from).toSet().toList();
    final arrivals = candidates.map((r) => r.to).toSet().toList();
    final beforeValues = await Future.wait(
      departures.map((port) => _legDistance(origin, port, roadDistance)),
    );
    final afterValues = await Future.wait(
      arrivals.map((port) => _legDistance(port, destination, roadDistance)),
    );
    final before = {
      for (var i = 0; i < departures.length; i++) departures[i]: beforeValues[i]
    };
    final after = {
      for (var i = 0; i < arrivals.length; i++) arrivals[i]: afterValues[i]
    };

    FerryRouteSuggestion? best;
    var bestHours = double.infinity;
    FerryRouteSuggestion? directPortMatch;
    var directPortHours = double.infinity;
    for (final route in candidates) {
      final kmBefore = before[route.from];
      final kmAfter = after[route.to];
      if (kmBefore == null || kmAfter == null) continue;
      var hours = route.durationHours + (kmBefore + kmAfter) / assumedKmh;

      // Mit bekanntem Startzeitpunkt zählt die Wartezeit bis zur nächsten
      // planmäßigen Abfahrt mit – damit gewinnt die Verbindung, die den
      // Fahrer wirklich am frühesten ans Ziel bringt.
      if (startTime != null) {
        final portArrival = startTime
            .add(Duration(minutes: (kmBefore / assumedKmh * 60).round()));
        final departure = FerrySchedule.nextDeparture(
          portArrival,
          route.departuresLocal,
          route.tz,
          departuresByWeekday: route.departuresByWeekday,
        );
        if (departure != null) {
          final waitHours = departure.difference(portArrival).inMinutes / 60.0;
          if (waitHours >= 0) hours += waitHours;
        }
      }
      if (hours < bestHours) {
        bestHours = hours;
        best = FerryRouteSuggestion(route, kmBefore, kmAfter);
      }
      if (origin.toLowerCase().contains(route.from.toLowerCase()) &&
          destination.toLowerCase().contains(route.to.toLowerCase()) &&
          hours < directPortHours) {
        directPortHours = hours;
        directPortMatch = FerryRouteSuggestion(route, kmBefore, kmAfter);
      }
    }
    return directPortMatch ?? best;
  }

  static Future<double?> _legDistance(
    String origin,
    String destination,
    RoadDistanceLookup roadDistance,
  ) {
    final a = origin.toLowerCase().trim();
    final b = destination.toLowerCase().trim();
    if (a == b || a.startsWith('$b,') || b.startsWith('$a,')) {
      return Future.value(0);
    }
    return roadDistance(origin, destination);
  }
}
