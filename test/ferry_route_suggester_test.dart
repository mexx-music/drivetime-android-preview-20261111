import 'package:driverroute_eta/logic/ferry_route_suggester.dart';
import 'package:driverroute_eta/models/ferry_route.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:timezone/data/latest.dart' as tz_data;

FerryRoute route(String from, String to, double hours) => FerryRoute(
      id: '$from-$to',
      name: '$from–$to',
      from: from,
      to: to,
      operators: const ['Example'],
      durationHours: hours,
      departuresLocal: const ['12:00'],
      tz: 'Europe/Athens',
      region: 'Griechenland/Italien',
      active: true,
      notes: '',
    );

void main() {
  setUpAll(() => tz_data.initializeTimeZones());
  final routes = [
    route('Igoumenitsa', 'Bari', 10),
    route('Igoumenitsa', 'Ancona', 20),
    route('Patras', 'Venedig', 28),
    route('Bari', 'Igoumenitsa', 10),
  ];

  test('Thessaloniki nach Rom erkennt Griechenland–Italien ohne Hafen', () {
    expect(FerryRouteSuggester.supportsTrip('Thessaloniki', 'Rom, Italien'),
        isTrue);
    expect(FerryRouteSuggester.supportsTrip('Tessaloniki', 'Rom'), isTrue);
    expect(FerryRouteSuggester.supportsTrip('Rome, Italy', 'Athens, Greece'),
        isTrue);
    expect(FerryRouteSuggester.supportsTrip('Athen', 'Wien'), isFalse);
  });

  test('Vergleicht alle erreichbaren Häfen nach Straße plus Fährdauer',
      () async {
    final calls = <String>[];
    final distances = <String, double>{
      'Thessaloniki|Igoumenitsa': 320,
      'Thessaloniki|Patras': 510,
      'Bari|Rom, Italien': 430,
      'Ancona|Rom, Italien': 300,
      'Venedig|Rom, Italien': 530,
    };
    final suggestion = await FerryRouteSuggester.suggest(
      origin: 'Thessaloniki',
      destination: 'Rom, Italien',
      routes: routes,
      roadDistance: (a, b) async {
        calls.add('$a|$b');
        return distances['$a|$b'];
      },
    );
    expect(suggestion?.route.name, 'Igoumenitsa–Bari');
    expect(suggestion?.roadKm, 750);
    expect(calls.length, 5); // jedes Hafenbein wird nur einmal abgefragt
    expect(calls, contains('Venedig|Rom, Italien'));
  });

  test('Unprüfbare Straßenbeine liefern keinen Fährvorschlag', () async {
    final suggestion = await FerryRouteSuggester.suggest(
      origin: 'Thessaloniki',
      destination: 'Rom, Italien',
      routes: routes,
      roadDistance: (a, b) async => null,
    );
    expect(suggestion, isNull);
  });

  test('Nordrouten erkennen Malmö, Göteborg und Oslo ohne Hafenstopp', () {
    expect(
        FerryRouteSuggester.supportsTrip(
            'Hamburg, Deutschland', 'Malmö, Schweden'),
        isTrue);
    expect(FerryRouteSuggester.supportsTrip('Kiel', 'Göteborg'), isTrue);
    expect(FerryRouteSuggester.supportsTrip('Oslo', 'Rostock'), isTrue);
    expect(FerryRouteSuggester.supportsTrip(
        'Wien, Österreich', 'Göteborg, Schweden'), isTrue);
    expect(FerryRouteSuggester.supportsTrip('Göteborg', 'Oslo'), isFalse);
  });

  test('Kiel nach Göteborg bevorzugt die direkte Stena-Fähre', () async {
    final northRoutes = [
      route('Kiel', 'Göteborg', 14),
      route('Rostock', 'Trelleborg', 6.5),
      route('Travemünde', 'Malmö', 9),
      route('Kiel', 'Oslo', 20),
    ];
    final distances = <String, double>{
      'Kiel|Rostock': 200,
      'Kiel|Travemünde': 100,
      'Trelleborg|Göteborg': 300,
      'Malmö|Göteborg': 280,
      'Oslo|Göteborg': 300,
    };
    final suggestion = await FerryRouteSuggester.suggest(
      origin: 'Kiel',
      destination: 'Göteborg',
      routes: northRoutes,
      roadDistance: (a, b) async => distances['$a|$b'],
    );
    expect(suggestion?.route.name, 'Kiel–Göteborg');
    expect(suggestion?.roadKm, 0);
  });

  test('Hamburg nach Malmö kann Finnlines und TT-Line vergleichen', () async {
    final northRoutes = [
      route('Travemünde', 'Malmö', 9),
      route('Rostock', 'Trelleborg', 6.5),
    ];
    final distances = <String, double>{
      'Hamburg, Deutschland|Travemünde': 70,
      'Hamburg, Deutschland|Rostock': 190,
      'Trelleborg|Malmö, Schweden': 35,
    };
    final suggestion = await FerryRouteSuggester.suggest(
      origin: 'Hamburg, Deutschland',
      destination: 'Malmö, Schweden',
      routes: northRoutes,
      roadDistance: (a, b) async => distances['$a|$b'],
    );
    expect(suggestion?.route.name, 'Rostock–Trelleborg');
  });

  // --- Auswahl zwischen mehreren Betreibern derselben Strecke -------------

  FerryRoute rostock(String name, List<String> deps) => FerryRoute(
        id: name,
        name: name,
        from: 'Rostock',
        to: 'Trelleborg',
        operators: const ['x'],
        durationHours: 6.5,
        departuresLocal: deps,
        tz: 'Europe/Berlin',
        region: 'Nordeuropa',
        active: true,
        notes: '',
      );

  test('ohne Startzeit entscheidet weiterhin allein die Überfahrtsdauer', () async {
    final result = await FerryRouteSuggester.suggest(
      origin: 'Hamburg, Deutschland',
      destination: 'Göteborg, Schweden',
      routes: [rostock('spaet', const ['23:00']), rostock('frueh', const ['15:00'])],
      roadDistance: (a, b) async => 200,
    );
    expect(result!.route.name, 'spaet', reason: 'erste passende Verbindung');
  });

  test('mit Startzeit gewinnt die tatsächlich frühere Abfahrt', () async {
    // Hafenankunft ca. 08:30 → 15:00 schlägt 23:00 deutlich.
    final result = await FerryRouteSuggester.suggest(
      origin: 'Hamburg, Deutschland',
      destination: 'Göteborg, Schweden',
      routes: [rostock('spaet', const ['23:00']), rostock('frueh', const ['15:00'])],
      roadDistance: (a, b) async => 200,
      startTime: DateTime(2026, 7, 6, 6),
    );
    expect(result!.route.name, 'frueh');
  });
}
