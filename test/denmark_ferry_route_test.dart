import 'package:driverroute_eta/logic/denmark_ferry_route.dart';
import 'package:driverroute_eta/logic/eta_calculator.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';

void main() {
  setUpAll(() async => initializeDateFormatting('de'));
  test('Malmö nach Kiel enthält beide kurzen Fähren in richtiger Reihenfolge',
      () async {
    final distances = <String, double>{
      'Malmö, Schweden|Helsingborg, Sweden': 70,
      'Helsingør, Denmark|Rødby, Denmark': 170,
      'Puttgarden, Germany|Kiel, Deutschland': 85,
    };
    final plan = await DenmarkFerryRoute.plan(
      origin: 'Malmö, Schweden',
      destination: 'Kiel, Deutschland',
      roadDistance: (a, b) async => distances['$a|$b'],
    );
    expect(plan?.roadKm, 325);
    expect(plan?.firstFerry, contains('Helsingborg–Helsingør'));
    expect(plan?.firstFerryMinutes, 20);
    expect(plan?.secondFerry, contains('Rødby–Puttgarden'));
    expect(plan?.secondFerryMinutes, 45);
  });

  test('Umgekehrte Richtung tauscht die Fährenreihenfolge', () async {
    final plan = await DenmarkFerryRoute.plan(
      origin: 'Kiel',
      destination: 'Malmö',
      roadDistance: (a, b) async => 100,
    );
    expect(plan?.firstFerry, contains('Puttgarden–Rødby'));
    expect(plan?.secondFerry, contains('Helsingør–Helsingborg'));
  });

  test('Zwei Fähren erscheinen getrennt im Tourablauf', () {
    final result = EtaCalculator.computeTwoShortFerries(
      start: DateTime(2026, 9, 17, 8),
      alreadyDrivenMin: 0,
      alreadyDrivenSinceBreakMin: 0,
      dutyTimeOffsetMin: 0,
      avgKmh: 80,
      rules: const DriveRulesConfig(
        tenHourDay1: true,
        tenHourDay2: true,
        nineHourRest1: true,
        nineHourRest2: true,
        nineHourRest3: true,
        tankPause: false,
      ),
      kmBefore: 70,
      kmBetween: 170,
      kmAfter: 85,
      firstDeparturePort: 'Helsingborg',
      firstFerry: 'Helsingborg–Helsingør',
      firstFerryMinutes: 20,
      secondDeparturePort: 'Rødby',
      secondFerry: 'Rødby–Puttgarden',
      secondFerryMinutes: 45,
    );
    expect(result.steps.where((step) => step.type == EtaEventType.ferry).length,
        2);
    expect(result.summary?.ferryMinutes, 65);
    expect(result.summary?.distanceKm, 325);
  });
}
