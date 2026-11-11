import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';

import 'package:driverroute_eta/logic/eta_calculator.dart';
import 'package:driverroute_eta/logic/ferry_auto.dart';
import 'package:driverroute_eta/models/ferry_route.dart';

/// Die Routenplanung kennt die Kilometer bereits. Werden sie als [verifiedKm]
/// weitergereicht, darf die ETA sie nicht ein zweites Mal bei Google abfragen.
///
/// In diesen Tests ist kein API-Key gesetzt und Netzwerk ist blockiert – eine
/// erneute Abfrage liefert also nichts. Kommt trotzdem die richtige Distanz
/// heraus, kann sie nur aus [verifiedKm] stammen.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() => initializeDateFormatting('de'));

  const rules = DriveRulesConfig(
    tenHourDay1: true,
    tenHourDay2: true,
    nineHourRest1: true,
    nineHourRest2: true,
    nineHourRest3: true,
    tankPause: false,
  );

  Future<EtaResult> run({double? verifiedKm, double? fallbackKm}) =>
      FerryAutoDetect('').computeEtaWithOptionalFerry(
        startTime: DateTime(2026, 5, 4, 6),
        alreadyDrivenMin: 0,
        dutyOffsetMin: 0,
        avgKmh: 80,
        rules: rules,
        startAddress: 'Wien',
        endAddress: 'München',
        verifiedKm: verifiedKm,
        fallbackKm: fallbackKm,
      );

  test('verifiedKm wird ohne erneute Abfrage übernommen', () async {
    final res = await run(verifiedKm: 402.5, fallbackKm: 999);
    expect(res.summary!.distanceKm, 402.5);
  });

  test('ohne verifiedKm bleibt es beim bisherigen Weg über fallbackKm',
      () async {
    // Ohne Key und ohne Netz liefert die erneute Abfrage nichts.
    final res = await run(fallbackKm: 999);
    expect(res.summary!.distanceKm, 999);
  });

  test('Fahrzeit und Ankunft folgen den übernommenen Kilometern', () async {
    final res = await run(verifiedKm: 400, fallbackKm: 999);
    // 400 km bei 80 km/h = 5 h reine Fahrt, ab 06:00 plus 45 min Lenkpause.
    expect(res.summary!.drivingMinutes, 300);
    expect(res.arrival, DateTime(2026, 5, 4, 11, 45));
  });

  test('gleiche Kilometer ergeben dieselbe Timeline wie zuvor', () async {
    final mit = await run(verifiedKm: 402.5, fallbackKm: 402.5);
    final ohne = await run(fallbackKm: 402.5);
    expect(mit.arrival, ohne.arrival);
    expect(mit.summary!.distanceKm, ohne.summary!.distanceKm);
    expect(mit.summary!.drivingMinutes, ohne.summary!.drivingMinutes);
    expect(mit.summary!.breakMinutes, ohne.summary!.breakMinutes);
    expect(mit.summary!.restMinutes, ohne.summary!.restMinutes);
    expect(
      mit.steps.map((e) => e.title).toList(),
      ohne.steps.map((e) => e.title).toList(),
    );
  });

  test('bei Fähren ändert verifiedKm nichts – dort zählen die Landwege',
      () async {
    final ferry = FerryRoute(
      id: 'f',
      name: 'Test–Fähre',
      from: 'Bari',
      to: 'Igoumenitsa',
      operators: const ['Test'],
      durationHours: 10,
      departuresLocal: const ['10:00'],
      tz: 'Europe/Rome',
      region: 'Test',
      active: true,
      notes: '',
    );
    Future<EtaResult> ferryRun({double? verifiedKm}) =>
        FerryAutoDetect('').computeEtaWithOptionalFerry(
          startTime: DateTime(2026, 5, 4, 6),
          alreadyDrivenMin: 0,
          dutyOffsetMin: 0,
          avgKmh: 80,
          rules: rules,
          startAddress: 'Mailand',
          endAddress: 'Athen',
          autoOrManualFerry: ferry,
          ferryRoadKmBefore: 884,
          ferryRoadKmAfter: 430,
          verifiedKm: verifiedKm,
        );

    final a = await ferryRun();
    final b = await ferryRun(verifiedKm: 12345);
    expect(a.summary!.distanceKm, 1314);
    expect(b.summary!.distanceKm, 1314);
    expect(a.arrival, b.arrival);
  });

  test('die erste Dezimalstelle entscheidet über eine ganze Minute', () async {
    // Begründet die Rundung an der Aufrufstelle in main.dart: der frühere
    // DistanceService rundete auf eine Dezimale. Ungerundet weitergereicht
    // ergäbe dieselbe Strecke eine Minute weniger.
    final gerundet = await run(verifiedKm: 912.7, fallbackKm: 0);
    final ungerundet = await run(verifiedKm: 912.65, fallbackKm: 0);
    expect(gerundet.summary!.drivingMinutes, 685);
    expect(ungerundet.summary!.drivingMinutes, 684);
  });
}
