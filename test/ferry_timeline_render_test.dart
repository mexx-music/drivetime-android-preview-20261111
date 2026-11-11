import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:timezone/data/latest.dart' as tz_data;

import 'package:driverroute_eta/logic/eta_calculator.dart';
import 'package:driverroute_eta/logic/ferry_auto.dart';
import 'package:driverroute_eta/services/ferry_schedule_loader.dart';
import 'package:driverroute_eta/widgets/tour_result_view.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await initializeDateFormatting('de');
    tz_data.initializeTimeZones();
  });

  testWidgets('Fähr-Timeline rendert ohne Absturz', (tester) async {
    final (_, routes) = await FerryScheduleLoader.load();
    final route = routes.firstWhere((x) => x.id == 'kielgoteborg_stena');
    final res = await FerryAutoDetect('').computeEtaWithOptionalFerry(
      startTime: DateTime(2026, 7, 6, 6),
      alreadyDrivenMin: 0,
      dutyOffsetMin: 0,
      avgKmh: 75,
      rules: const DriveRulesConfig(
        tenHourDay1: true, tenHourDay2: true,
        nineHourRest1: true, nineHourRest2: true, nineHourRest3: true,
        tankPause: false),
      startAddress: 'Kiel',
      endAddress: 'Göteborg',
      autoOrManualFerry: route,
      ferryRoadKmBefore: 200,
      ferryRoadKmAfter: 300,
    );

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: TourResultView(
            result: res,
            origin: 'Kiel',
            destination: 'Göteborg',
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
}
