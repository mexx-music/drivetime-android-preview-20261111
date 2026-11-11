import 'package:driverroute_eta/logic/eta_calculator.dart';
import 'package:driverroute_eta/logic/speed_profile.dart';
import 'package:driverroute_eta/logic/tour_export.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';

void main() {
  setUpAll(() async => initializeDateFormatting('de'));

  test('Text-Export enthält ETA, Geschwindigkeit, Straßenmix und Ablauf', () {
    final result = EtaCalculator.compute(
      start: DateTime(2026, 9, 15, 6),
      alreadyDrivenMin: 0,
      dutyTimeOffsetMin: 0,
      km: 350,
      avgKmh: 70,
      rules: const DriveRulesConfig(
        tenHourDay1: true,
        tenHourDay2: true,
        nineHourRest1: true,
        nineHourRest2: true,
        nineHourRest3: true,
        tankPause: false,
      ),
      startLabel: 'Wien, Österreich',
      destinationLabel: 'München, Deutschland',
    );

    final text = TourExport.asText(
      result: result,
      origin: 'Wien, Österreich',
      destination: 'München, Deutschland',
      roadMix: const RoadMixAnalysis(
        roadKm: 350,
        averageKmh: 70,
        fastShare: 0.6,
        mainRoadShare: 0.3,
        slowShare: 0.1,
      ),
    );

    expect(text, contains('Wien → München'));
    expect(text, contains('Planungsschnitt: 70 km/h'));
    expect(text, contains('60 % schnell'));
    expect(text, contains('Tourablauf:'));
    expect(text, contains('Ankunft:'));
  });
}
