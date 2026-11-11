import 'package:driverroute_eta/logic/ferry_route_search.dart';
import 'package:driverroute_eta/models/ferry_route.dart';
import 'package:flutter_test/flutter_test.dart';

FerryRoute route(String from, String to, String operator,
        {bool active = true}) =>
    FerryRoute(
      id: '$from-$to-$operator',
      name: '$from–$to ($operator)',
      from: from,
      to: to,
      operators: [operator],
      durationHours: 9,
      departuresLocal: const [],
      tz: 'Europe/Berlin',
      region: 'Nordeuropa',
      active: active,
      notes: '',
    );

void main() {
  final routes = [
    route('Igoumenitsa', 'Bari', 'Grimaldi'),
    route('Bari', 'Igoumenitsa', 'Grimaldi'),
    route('Travemünde', 'Malmö', 'Finnlines'),
    route('Kiel', 'Göteborg', 'Stena Line'),
    route('Świnoujście', 'Trelleborg', 'TT-Line'),
    route('Kiel', 'Trelleborg', 'Alt', active: false),
  ];

  test('Ein Hafen zeigt Verbindungen ab diesem Hafen zuerst', () {
    final matches = FerryRouteSearch.find(routes, 'Igoumenitsa');
    expect(matches.map((r) => r.name), [
      'Igoumenitsa–Bari (Grimaldi)',
      'Bari–Igoumenitsa (Grimaldi)',
    ]);
  });

  test('Zwei Häfen und Reederei lassen sich kombinieren', () {
    expect(FerryRouteSearch.find(routes, 'Bari Igoumenitsa').length, 2);
    expect(FerryRouteSearch.find(routes, 'Finnlines Malmoe').single.name,
        'Travemünde–Malmö (Finnlines)');
  });

  test('Umlaute, Schreibvarianten und deaktivierte Routen', () {
    expect(
        FerryRouteSearch.find(routes, 'Travemuende').single.from, 'Travemünde');
    expect(FerryRouteSearch.find(routes, 'Goteborg').single.to, 'Göteborg');
    expect(FerryRouteSearch.find(routes, 'Swinoujscie').single.from,
        'Świnoujście');
    expect(FerryRouteSearch.find(routes, 'Kiel Trelleborg'), isEmpty);
    expect(FerryRouteSearch.find(routes, ''), isEmpty);
  });
}
