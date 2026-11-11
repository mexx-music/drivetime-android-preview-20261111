import 'package:driverroute_eta/logic/eta_calculator.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';

void main() {
  setUpAll(() async {
    await initializeDateFormatting('de');
  });

  DriveRulesConfig rules({
    bool ten1 = true,
    bool ten2 = true,
    bool nine1 = true,
    bool nine2 = true,
    bool nine3 = true,
    bool tank = false,
    bool split = false,
    bool weeklyRest = false,
  }) {
    return DriveRulesConfig(
      tenHourDay1: ten1,
      tenHourDay2: ten2,
      nineHourRest1: nine1,
      nineHourRest2: nine2,
      nineHourRest3: nine3,
      tankPause: tank,
      splitBreak: split,
      weeklyRestDue: weeklyRest,
    );
  }

  final start = DateTime(2026, 3, 16, 6);

  test('reine Tagestour endet ohne unnötige Pause', () {
    final result = EtaCalculator.compute(
      start: start,
      alreadyDrivenMin: 0,
      dutyTimeOffsetMin: 0,
      km: 320,
      avgKmh: 80,
      rules: rules(),
    );

    expect(result.arrival, DateTime(2026, 3, 16, 10));
    expect(result.summary!.drivingMinutes, 240);
    expect(result.summary!.breakMinutes, 0);
    expect(result.summary!.averageKmh, 80);
  });

  test('4,5-Stunden-Grenze erzeugt Pause nur bei anschließender Fahrt', () {
    final result = EtaCalculator.compute(
      start: start,
      alreadyDrivenMin: 0,
      dutyTimeOffsetMin: 0,
      km: 400,
      avgKmh: 80,
      rules: rules(),
    );

    expect(result.summary!.drivingMinutes, 300);
    expect(result.summary!.breakMinutes, 45);
    expect(result.arrival, DateTime(2026, 3, 16, 11, 45));
  });

  test('9-Stunden-Tag enthält eine Lenkpause und keine Pause am Ziel', () {
    final result = EtaCalculator.compute(
      start: start,
      alreadyDrivenMin: 0,
      dutyTimeOffsetMin: 0,
      km: 720,
      avgKmh: 80,
      rules: rules(ten1: false, ten2: false),
    );

    expect(result.summary!.drivingMinutes, 540);
    expect(result.summary!.breakMinutes, 45);
    expect(result.summary!.restMinutes, 0);
    expect(result.arrival, DateTime(2026, 3, 16, 15, 45));
  });

  test('10-Stunden-Tag nutzt genau eine Verlängerung', () {
    final result = EtaCalculator.compute(
      start: start,
      alreadyDrivenMin: 0,
      dutyTimeOffsetMin: 0,
      km: 800,
      avgKmh: 80,
      rules: rules(),
    );

    expect(result.summary!.drivingMinutes, 600);
    expect(result.summary!.breakMinutes, 90);
    expect(result.summary!.tenHourDaysUsed, 1);
    expect(result.arrival, DateTime(2026, 3, 16, 17, 30));
  });

  test('mehrtägige Tour plant verkürzte Tagesruhe', () {
    final result = EtaCalculator.compute(
      start: start,
      alreadyDrivenMin: 0,
      dutyTimeOffsetMin: 0,
      km: 880,
      avgKmh: 80,
      rules: rules(),
    );

    expect(result.summary!.drivingMinutes, 660);
    expect(result.summary!.restMinutes, 540);
    expect(result.summary!.reducedDailyRestsUsed, 1);
    expect(
      result.steps.where((step) => step.type == EtaEventType.dailyRest),
      hasLength(1),
    );
  });

  test('ohne Verkürzung wird eine 11-Stunden-Tagesruhe geplant', () {
    final result = EtaCalculator.compute(
      start: start,
      alreadyDrivenMin: 0,
      dutyTimeOffsetMin: 0,
      km: 800,
      avgKmh: 80,
      rules: rules(
        ten1: false,
        ten2: false,
        nine1: false,
        nine2: false,
        nine3: false,
      ),
    );

    final rest = result.steps.singleWhere(
      (step) => step.type == EtaEventType.dailyRest,
    );
    expect(rest.duration, const Duration(hours: 11));
  });

  test('bereits gefahrene Zeit verkürzt den nächsten Fahrblock', () {
    final result = EtaCalculator.compute(
      start: start,
      alreadyDrivenMin: 240,
      dutyTimeOffsetMin: 240,
      km: 80,
      avgKmh: 80,
      rules: rules(),
    );

    expect(result.summary!.drivingMinutes, 60);
    expect(result.summary!.breakMinutes, 45);
    expect(result.arrival, DateTime(2026, 3, 16, 7, 45));
  });

  test('Tageslenkzeit und Zeit seit der Pause werden getrennt behandelt', () {
    final result = EtaCalculator.compute(
      start: start,
      alreadyDrivenMin: 480,
      alreadyDrivenSinceBreakMin: 120,
      dutyTimeOffsetMin: 600,
      km: 160,
      avgKmh: 80,
      rules: rules(),
    );

    final firstDrive = result.steps.firstWhere(
      (step) => step.type == EtaEventType.drive,
    );
    expect(firstDrive.duration, const Duration(hours: 2));
    expect(result.summary!.tenHourDaysUsed, 1);
  });

  test('bisherige Einsatzzeit verschiebt nicht die Abfahrt rückwärts', () {
    final result = EtaCalculator.compute(
      start: start,
      alreadyDrivenMin: 0,
      dutyTimeOffsetMin: 840,
      km: 160,
      avgKmh: 80,
      rules: rules(),
    );

    expect(result.steps.first.start, start);
    expect(result.summary!.restMinutes, 540);
    expect(result.arrival, DateTime(2026, 3, 16, 17));
  });

  test('geteilte Pause wird als 15 plus 30 Minuten dargestellt', () {
    final result = EtaCalculator.compute(
      start: start,
      alreadyDrivenMin: 0,
      dutyTimeOffsetMin: 0,
      km: 400,
      avgKmh: 80,
      rules: rules(split: true),
    );

    final breaks = result.steps
        .where((step) => step.type == EtaEventType.breakTime)
        .toList();
    expect(breaks.map((step) => step.duration.inMinutes), [15, 30]);
  });

  test('Tankstopp zählt nicht als gesetzliche Lenkpause', () {
    final result = EtaCalculator.compute(
      start: start,
      alreadyDrivenMin: 0,
      dutyTimeOffsetMin: 0,
      km: 400,
      avgKmh: 80,
      rules: rules(tank: true),
    );

    expect(result.summary!.tankMinutes, 30);
    expect(result.summary!.breakMinutes, 45);
  });

  test('fällige Wochenruhe wird vor der Tour eingeplant', () {
    final result = EtaCalculator.compute(
      start: start,
      alreadyDrivenMin: 0,
      dutyTimeOffsetMin: 0,
      km: 80,
      avgKmh: 80,
      rules: rules(weeklyRest: true),
    );

    expect(
      result.steps.any((step) => step.type == EtaEventType.weeklyRest),
      isTrue,
    );
    expect(result.arrival, DateTime(2026, 3, 18, 4));
  });

  // --- Fährblock nach Art. 9 VO (EG) 561/2006 ---------------------------
  // Wartezeit am Hafen + Überfahrt + ggf. Standzeit danach ergeben ZUSAMMEN
  // die Tagesruhe. Auf- und Abfahren dürfen sie zweimal um je 30 min
  // unterbrechen.

  test('Warten und Überfahrt ergeben zusammen die verkürzte Tagesruhe', () {
    final result = EtaCalculator.computeTwoLegsWithFerry(
      start: start,
      alreadyDrivenMin: 0,
      dutyTimeOffsetMin: 0,
      kmBefore: 80,
      kmAfter: 80,
      avgKmh: 80,
      rules: rules(),
      ferryLabel: 'Rostock–Trelleborg',
      ferryDurationMin: 540,
      manualDeparture: DateTime(2026, 3, 16, 8),
      departurePort: 'Rostock',
    );

    final ferry =
        result.steps.singleWhere((step) => step.type == EtaEventType.ferry);
    expect(ferry.restSatisfied, isTrue);
    // 60 min Warten: 30 fürs Auffahren, 30 zählen als Ruhe → 30 + 540 = 570
    // und damit über den 540 der verkürzten Tagesruhe.
    expect(result.summary!.waitingMinutes, 0,
        reason: 'die Wartezeit zählt jetzt als Ruhe, nicht als Warten');
    expect(result.summary!.restMinutes, greaterThanOrEqualTo(60));
    expect(result.arrival, DateTime(2026, 3, 16, 18));
  });

  test('knapp zu kurz wird nach der Ankunft stehend vollendet', () {
    // 8 h Überfahrt + 1 h Warten = 8,5 h anrechenbar → 30 min fehlen auf 9 h.
    final result = EtaCalculator.computeTwoLegsWithFerry(
      start: start,
      alreadyDrivenMin: 0,
      dutyTimeOffsetMin: 0,
      kmBefore: 80,
      kmAfter: 80,
      avgKmh: 80,
      rules: rules(),
      ferryLabel: 'Kurzstrecke',
      ferryDurationMin: 480,
      manualDeparture: DateTime(2026, 3, 16, 8),
    );

    final ferry =
        result.steps.singleWhere((step) => step.type == EtaEventType.ferry);
    expect(ferry.restSatisfied, isTrue);
    expect(
      result.steps.any((s) => s.title?.contains('Standzeit nach der Fähre') ?? false),
      isTrue,
    );
    // 07:00 Hafen + 1 h Warten + 8 h Fähre + 30 min Standzeit + 1 h Fahrt
    expect(result.arrival, DateTime(2026, 3, 16, 17, 30));
  });

  test('ohne verkürzte Ruhen zählt die 11-Stunden-Grenze', () {
    // Nur reguläre Tagesruhe möglich → 660 min nötig.
    final result = EtaCalculator.computeTwoLegsWithFerry(
      start: start,
      alreadyDrivenMin: 0,
      dutyTimeOffsetMin: 0,
      kmBefore: 80,
      kmAfter: 80,
      avgKmh: 80,
      rules: rules(nine1: false, nine2: false, nine3: false),
      ferryLabel: 'Lange Überfahrt',
      ferryDurationMin: 660,
      manualDeparture: DateTime(2026, 3, 16, 8),
    );

    final ferry =
        result.steps.singleWhere((step) => step.type == EtaEventType.ferry);
    expect(ferry.restSatisfied, isTrue);
    expect(ferry.detail, contains('reguläre'));
  });

  test('kurze Fähre ist keine Tagesruhe, aber eine Lenkpause', () {
    final result = EtaCalculator.computeTwoLegsWithFerry(
      start: start,
      alreadyDrivenMin: 0,
      dutyTimeOffsetMin: 0,
      kmBefore: 80,
      kmAfter: 80,
      avgKmh: 80,
      rules: rules(),
      ferryLabel: 'Kurzfähre',
      ferryDurationMin: 90,
      manualDeparture: DateTime(2026, 3, 16, 7),
    );

    final ferry =
        result.steps.singleWhere((step) => step.type == EtaEventType.ferry);
    expect(ferry.restSatisfied, isFalse);
    expect(ferry.detail, contains('fehlen'));
    expect(
      result.steps.any((s) => s.title?.contains('Standzeit nach der Fähre') ?? false),
      isFalse,
    );
  });

  test('UTC-Zeitbasis bleibt bei der gesamten Berechnung erhalten', () {
    final utcStart = DateTime.utc(2026, 3, 16, 6);
    final result = EtaCalculator.compute(
      start: utcStart,
      alreadyDrivenMin: 0,
      dutyTimeOffsetMin: 0,
      km: 80,
      avgKmh: 80,
      rules: rules(),
    );

    expect(result.arrival!.isUtc, isTrue);
    expect(result.arrival, DateTime.utc(2026, 3, 16, 7));
  });
}
