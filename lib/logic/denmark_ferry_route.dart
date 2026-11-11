import 'ferry_route_suggester.dart';

class DenmarkFerryRoute {
  final double kmBefore;
  final double kmBetween;
  final double kmAfter;
  final String firstDeparturePort;
  final String firstFerry;
  final int firstFerryMinutes;
  final String secondDeparturePort;
  final String secondFerry;
  final int secondFerryMinutes;

  const DenmarkFerryRoute({
    required this.kmBefore,
    required this.kmBetween,
    required this.kmAfter,
    required this.firstDeparturePort,
    required this.firstFerry,
    required this.firstFerryMinutes,
    required this.secondDeparturePort,
    required this.secondFerry,
    required this.secondFerryMinutes,
  });

  double get roadKm => kmBefore + kmBetween + kmAfter;

  static bool supportsTrip(String origin, String destination) {
    final a = origin.toLowerCase();
    final b = destination.toLowerCase();
    bool germany(String value) => [
          'deutschland',
          'germany',
          'kiel',
          'rostock',
          'travemünde',
          'travemuende',
          'hamburg',
          'lübeck',
        ].any(value.contains);
    bool sweden(String value) => [
          'schweden',
          'sweden',
          'sverige',
          'malmö',
          'malmo',
          'helsingborg',
          'trelleborg',
          'göteborg',
          'goteborg',
          'gothenburg',
        ].any(value.contains);
    return (germany(a) && sweden(b)) || (sweden(a) && germany(b));
  }

  static Future<DenmarkFerryRoute?> plan({
    required String origin,
    required String destination,
    required RoadDistanceLookup roadDistance,
  }) async {
    if (!supportsTrip(origin, destination)) return null;
    final fromSweden = [
      'schweden',
      'sweden',
      'sverige',
      'malmö',
      'malmo',
      'helsingborg',
      'trelleborg',
      'göteborg',
      'goteborg',
      'gothenburg',
    ].any(origin.toLowerCase().contains);

    final firstRoadEnd =
        fromSweden ? 'Helsingborg, Sweden' : 'Puttgarden, Germany';
    final middleRoadStart =
        fromSweden ? 'Helsingør, Denmark' : 'Rødby, Denmark';
    final middleRoadEnd = fromSweden ? 'Rødby, Denmark' : 'Helsingør, Denmark';
    final lastRoadStart =
        fromSweden ? 'Puttgarden, Germany' : 'Helsingborg, Sweden';

    Future<double?> leg(String a, String b) {
      if (a.toLowerCase() == b.toLowerCase() ||
          a.toLowerCase().startsWith('${b.toLowerCase()},') ||
          b.toLowerCase().startsWith('${a.toLowerCase()},')) {
        return Future.value(0);
      }
      return roadDistance(a, b);
    }

    final values = await Future.wait([
      leg(origin, firstRoadEnd),
      leg(middleRoadStart, middleRoadEnd),
      leg(lastRoadStart, destination),
    ]);
    if (values.any((km) => km == null || km < 0)) return null;

    return DenmarkFerryRoute(
      kmBefore: values[0]!,
      kmBetween: values[1]!,
      kmAfter: values[2]!,
      firstDeparturePort: firstRoadEnd,
      firstFerry: fromSweden
          ? 'Helsingborg–Helsingør (ØRESUNDSLINJEN)'
          : 'Puttgarden–Rødby (Scandlines)',
      firstFerryMinutes: fromSweden ? 20 : 45,
      secondDeparturePort: middleRoadEnd,
      secondFerry: fromSweden
          ? 'Rødby–Puttgarden (Scandlines)'
          : 'Helsingør–Helsingborg (ØRESUNDSLINJEN)',
      secondFerryMinutes: fromSweden ? 45 : 20,
    );
  }
}
