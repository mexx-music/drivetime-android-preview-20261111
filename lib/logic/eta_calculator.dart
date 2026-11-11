import 'dart:math' as math;

import 'package:intl/intl.dart';

import 'ferry_schedule.dart';

/// Verfügbare Ausnahmen und optionale Stopps für die Planung.
///
/// Die Schalter beschreiben noch verfügbare Kontingente innerhalb der
/// aktuellen Woche. Eine tägliche Ruhezeit setzt diese Kontingente nicht
/// zurück.
class DriveRulesConfig {
  final bool tenHourDay1;
  final bool tenHourDay2;
  final bool nineHourRest1;
  final bool nineHourRest2;
  final bool nineHourRest3;
  final bool tankPause;
  final bool splitBreak;
  final bool weeklyRestDue;

  const DriveRulesConfig({
    required this.tenHourDay1,
    required this.tenHourDay2,
    required this.nineHourRest1,
    required this.nineHourRest2,
    required this.nineHourRest3,
    required this.tankPause,
    this.splitBreak = false,
    this.weeklyRestDue = false,
  });
}

enum EtaEventType {
  start,
  drive,
  breakTime,
  dailyRest,
  weeklyRest,
  tank,
  wait,
  ferry,
  stop,
  destination,
  notice,
}

/// Ein strukturiertes Ereignis im Tourablauf.
///
/// [text] bleibt aus Kompatibilitätsgründen erhalten und wird ausschließlich
/// in der optionalen Debugansicht angezeigt. Die Fahreransicht verwendet die
/// übrigen Felder direkt.
class EtaStep {
  final String text;
  final EtaEventType type;
  final String? title;
  final String? detail;
  final DateTime? start;
  final DateTime? end;
  final double? distanceKm;
  final bool? restSatisfied;
  final bool technical;

  const EtaStep(
    this.text, {
    this.type = EtaEventType.notice,
    this.title,
    this.detail,
    this.start,
    this.end,
    this.distanceKm,
    this.restSatisfied,
    this.technical = false,
  });

  Duration get duration =>
      start != null && end != null ? end!.difference(start!) : Duration.zero;
}

class EtaSummary {
  final double distanceKm;
  final double averageKmh;
  final int drivingMinutes;
  final int breakMinutes;
  final int restMinutes;
  final int waitingMinutes;
  final int ferryMinutes;

  /// Anteil der Fährzeit, der als Ruhezeit gewertet wurde. Steckt bereits in
  /// [ferryMinutes] – separat ausgewiesen, damit "Ruhe" nicht fälschlich als
  /// 0 erscheint, wenn die Ruhe an Bord stattfand.
  final int ferryRestMinutes;
  final int tankMinutes;
  final int tenHourDaysUsed;
  final int reducedDailyRestsUsed;

  const EtaSummary({
    required this.distanceKm,
    required this.averageKmh,
    required this.drivingMinutes,
    required this.breakMinutes,
    required this.restMinutes,
    required this.waitingMinutes,
    required this.ferryMinutes,
    this.ferryRestMinutes = 0,
    required this.tankMinutes,
    required this.tenHourDaysUsed,
    required this.reducedDailyRestsUsed,
  });

  int get nonDrivingMinutes =>
      breakMinutes + restMinutes + waitingMinutes + ferryMinutes + tankMinutes;
}

class EtaResult {
  final List<EtaStep> steps;
  final DateTime? arrival;
  final EtaSummary? summary;

  const EtaResult(this.steps, this.arrival, {this.summary});
}

/// Zulässige Unterbrechung der Ruhezeit je Auf- bzw. Abfahrvorgang.
const int ferryInterruptionMin = 30;

/// Fehlt zur Tagesruhe höchstens so viel, wird sie nach der Ankunft im Hafen
/// stehend vollendet, statt sie ganz zu verwerfen.
const int ferryRestCompletionWindowMin = 180;

class _DriveState {
  DateTime current;
  int continuousDriveMin;
  int dailyDriveMin;
  int dutyElapsedMin;
  int tenHourDaysRemaining;
  int reducedRestsRemaining;
  int tenHourDaysUsed = 0;
  int reducedRestsUsed = 0;
  bool tankUsed = false;
  bool splitFirstPartTaken = false;

  _DriveState({
    required this.current,
    required this.continuousDriveMin,
    required this.dailyDriveMin,
    required this.dutyElapsedMin,
    required this.tenHourDaysRemaining,
    required this.reducedRestsRemaining,
  });
}

class _Planner {
  final DriveRulesConfig rules;
  final double avgKmh;
  final List<EtaStep> steps = [];
  final _DriveState state;

  _Planner({
    required DateTime start,
    required int alreadyDrivenMin,
    required int continuousDrivenMin,
    required int dutyTimeOffsetMin,
    required this.avgKmh,
    required this.rules,
  }) : state = _DriveState(
          current: start,
          continuousDriveMin: math.max(0, continuousDrivenMin),
          dailyDriveMin: math.max(0, alreadyDrivenMin),
          dutyElapsedMin: math.max(
            math.max(0, dutyTimeOffsetMin),
            math.max(0, alreadyDrivenMin),
          ),
          tenHourDaysRemaining:
              (rules.tenHourDay1 ? 1 : 0) + (rules.tenHourDay2 ? 1 : 0),
          reducedRestsRemaining: (rules.nineHourRest1 ? 1 : 0) +
              (rules.nineHourRest2 ? 1 : 0) +
              (rules.nineHourRest3 ? 1 : 0),
        ) {
    if (state.dailyDriveMin > 540 && state.tenHourDaysRemaining > 0) {
      state.tenHourDaysRemaining -= 1;
      state.tenHourDaysUsed += 1;
    }
  }

  int get _dailyDriveLimit => state.tenHourDaysRemaining > 0 ? 600 : 540;

  int get _dailyDutyLimit => state.reducedRestsRemaining > 0 ? 900 : 780;

  void addStart(String location) {
    final details = <String>[];
    if (state.dailyDriveMin > 0) {
      details.add('${_fmtHm(state.dailyDriveMin)} heute bereits gefahren');
    }
    if (state.continuousDriveMin > 0 &&
        state.continuousDriveMin != state.dailyDriveMin) {
      details.add(
          '${_fmtHm(state.continuousDriveMin)} seit der letzten Lenkpause');
    }
    if (state.dutyElapsedMin > 0) {
      details.add('${_fmtHm(state.dutyElapsedMin)} bisherige Einsatzzeit');
    }
    steps.add(EtaStep(
      '🚛 Start ${_fmt(state.current)}${location.isEmpty ? '' : ' – $location'}',
      type: EtaEventType.start,
      title: 'Start',
      detail: details.isEmpty ? location : '$location\n${details.join(' · ')}',
      start: state.current,
      end: state.current,
    ));

    if (rules.weeklyRestDue) {
      _addWeeklyRest();
    } else if (state.dailyDriveMin >= _dailyDriveLimit ||
        state.dutyElapsedMin >= _dailyDutyLimit) {
      _addDailyRest();
    } else if (state.continuousDriveMin >= 270) {
      _addBreak(45, title: 'Lenkpause vor Weiterfahrt');
    }
  }

  void planLeg({required int driveMinutes, required double km}) {
    if (driveMinutes <= 0 || km <= 0) return;

    var remaining = driveMinutes;
    final kmPerMinute = km / driveMinutes;
    final tankTrigger = math.min(120, math.max(30, driveMinutes ~/ 2));
    var legDriven = 0;

    while (remaining > 0) {
      if (state.dailyDriveMin >= _dailyDriveLimit ||
          state.dutyElapsedMin >= _dailyDutyLimit) {
        _addDailyRest();
        continue;
      }

      if (state.continuousDriveMin >= 270) {
        _addBreak(state.splitFirstPartTaken ? 30 : 45);
        continue;
      }

      var chunk = math.min(remaining, 270 - state.continuousDriveMin);
      chunk = math.min(chunk, _dailyDriveLimit - state.dailyDriveMin);
      chunk = math.min(chunk, _dailyDutyLimit - state.dutyElapsedMin);

      if (rules.splitBreak &&
          !state.splitFirstPartTaken &&
          state.continuousDriveMin < 150 &&
          remaining > 270 - state.continuousDriveMin) {
        chunk = math.min(chunk, 150 - state.continuousDriveMin);
      }

      if (rules.tankPause && !state.tankUsed && legDriven < tankTrigger) {
        chunk = math.min(chunk, tankTrigger - legDriven);
      }

      if (chunk <= 0) {
        if (rules.tankPause && !state.tankUsed && legDriven >= tankTrigger) {
          _addTankPause();
        } else {
          _addDailyRest();
        }
        continue;
      }

      final eventStart = state.current;
      state.current = state.current.add(Duration(minutes: chunk));
      state.continuousDriveMin += chunk;
      state.dailyDriveMin += chunk;
      state.dutyElapsedMin += chunk;
      legDriven += chunk;
      remaining -= chunk;

      if (state.dailyDriveMin > 540 && state.tenHourDaysRemaining > 0) {
        state.tenHourDaysRemaining -= 1;
        state.tenHourDaysUsed += 1;
      }

      final eventKm = chunk * kmPerMinute;
      steps.add(EtaStep(
        '🛣 Fahrt ${_fmtHm(chunk)} · ${eventKm.toStringAsFixed(0)} km '
        '(${DateFormat('HH:mm').format(eventStart)}–${DateFormat('HH:mm').format(state.current)})',
        type: EtaEventType.drive,
        title: 'Fahrt · ${_fmtHm(chunk)}',
        detail: 'ca. ${eventKm.toStringAsFixed(0)} km',
        start: eventStart,
        end: state.current,
        distanceKm: eventKm,
      ));

      if (remaining <= 0) break;

      if (rules.tankPause && !state.tankUsed && legDriven >= tankTrigger) {
        _addTankPause();
      }

      final dailyLimitReached = state.dailyDriveMin >= _dailyDriveLimit ||
          state.dutyElapsedMin >= _dailyDutyLimit;
      if (dailyLimitReached) {
        _addDailyRest();
      } else if (rules.splitBreak &&
          !state.splitFirstPartTaken &&
          state.continuousDriveMin == 150) {
        _addBreak(15, title: 'Geteilte Lenkpause · Teil 1');
        state.splitFirstPartTaken = true;
      } else if (state.continuousDriveMin >= 270) {
        _addBreak(
          state.splitFirstPartTaken ? 30 : 45,
          title: state.splitFirstPartTaken
              ? 'Geteilte Lenkpause · Teil 2'
              : 'Lenkpause',
        );
      }
    }
  }

  void addPortArrival(String port) {
    steps.add(EtaStep(
      '⚓ Ankunft Hafen $port: ${_fmt(state.current)}',
      type: EtaEventType.stop,
      title: 'Ankunft Hafen',
      detail: port,
      start: state.current,
      end: state.current,
    ));
  }

  /// Fährblock nach Art. 9 VO (EG) 561/2006.
  ///
  /// Wartezeit am Hafen, Überfahrt und – falls nötig – Standzeit nach der
  /// Ankunft bilden ZUSAMMEN die tägliche Ruhezeit. Auffahren und Abfahren
  /// dürfen sie höchstens zweimal unterbrechen, zusammen höchstens eine
  /// Stunde; diese Unterbrechungen zählen selbst nicht als Ruhe.
  ///
  /// Vorher wurde nur die reine Überfahrt geprüft – damit fiel die Ruhezeit
  /// durch, obwohl Warten plus Überfahrt längst gereicht hätten.
  void addFerryPassage({
    required String label,
    required DateTime departure,
    required int crossingMinutes,
  }) {
    final portArrival = state.current;
    final waitMinutes = departure.isAfter(portArrival)
        ? departure.difference(portArrival).inMinutes
        : 0;

    final boardingMinutes = math.min(ferryInterruptionMin, waitMinutes);
    final restBeforeMinutes = waitMinutes - boardingMinutes;

    final requiredRest = state.reducedRestsRemaining > 0 ? 540 : 660;
    final restUntilArrival = restBeforeMinutes + crossingMinutes;

    var restAfterMinutes = 0;
    var dailyRestSatisfied = false;
    if (restUntilArrival >= requiredRest) {
      dailyRestSatisfied = true;
    } else if (restUntilArrival >=
        requiredRest - ferryRestCompletionWindowMin) {
      restAfterMinutes = requiredRest - restUntilArrival;
      dailyRestSatisfied = true;
    }
    final totalRest = restUntilArrival + restAfterMinutes;
    final restLabel = requiredRest == 540 ? 'verkürzte' : 'reguläre';

    if (waitMinutes > 0) {
      state.current = departure;
      steps.add(EtaStep(
        '${dailyRestSatisfied ? '🌙' : '⏱'} Wartezeit am Hafen '
        '${_fmtHm(waitMinutes)} · Abfahrt ${_fmt(departure)}',
        type: dailyRestSatisfied ? EtaEventType.dailyRest : EtaEventType.wait,
        title: dailyRestSatisfied
            ? 'Ruhezeit am Hafen · ${_fmtHm(restBeforeMinutes)}'
            : 'Wartezeit am Hafen',
        detail: dailyRestSatisfied
            ? 'Zählt zur Ruhezeit; ${_fmtHm(boardingMinutes)} fürs Auffahren '
                'sind zulässige Unterbrechung.'
            : 'Abfahrt der Fähre: '
                '${DateFormat('EEE HH:mm', 'de').format(departure)}',
        start: portArrival,
        end: departure,
        restSatisfied: dailyRestSatisfied,
      ));
      if (!dailyRestSatisfied) state.dutyElapsedMin += waitMinutes;
    }

    final crossingStart = state.current;
    state.current = state.current.add(Duration(minutes: crossingMinutes));
    steps.add(EtaStep(
      '⛴ Fähre $label · ${_fmtHm(crossingMinutes)} · '
      'Ankunft ${_fmt(state.current)}',
      type: EtaEventType.ferry,
      title: 'Fähre $label',
      detail: dailyRestSatisfied
          ? '${_fmtHm(totalRest)} Ruhezeit insgesamt: Warten '
              '${_fmtHm(restBeforeMinutes)} + Überfahrt '
              '${_fmtHm(crossingMinutes)}'
              '${restAfterMinutes > 0 ? ' + Standzeit danach ${_fmtHm(restAfterMinutes)}' : ''}'
              ' → $restLabel Tagesruhe erfüllt'
          : 'Warten + Überfahrt ergeben ${_fmtHm(restUntilArrival)} – '
              'für die $restLabel Tagesruhe fehlen '
              '${_fmtHm(requiredRest - restUntilArrival)}.',
      start: crossingStart,
      end: state.current,
      restSatisfied: dailyRestSatisfied,
    ));

    if (restAfterMinutes > 0) {
      final afterStart = state.current;
      state.current = state.current.add(Duration(minutes: restAfterMinutes));
      steps.add(EtaStep(
        '🌙 Standzeit nach der Fähre ${_fmtHm(restAfterMinutes)} · '
        'weiter ${_fmt(state.current)}',
        type: EtaEventType.dailyRest,
        title: 'Standzeit nach der Fähre · ${_fmtHm(restAfterMinutes)}',
        detail: 'Vollendet die $restLabel Tagesruhe von '
            '${_fmtHm(requiredRest)}. ${_fmtHm(ferryInterruptionMin)} fürs '
            'Abfahren sind zulässige Unterbrechung.',
        start: afterStart,
        end: state.current,
        restSatisfied: true,
      ));
    }

    if (dailyRestSatisfied) {
      if (requiredRest == 540) {
        state.reducedRestsRemaining -= 1;
        state.reducedRestsUsed += 1;
      }
      _resetDailyState();
    } else {
      // Keine Tagesruhe, aber Stehen an Bord ist mindestens eine Lenkpause.
      if (restUntilArrival >= 45) state.continuousDriveMin = 0;
      state.dutyElapsedMin += crossingMinutes;
    }
  }

  void addDestination(String location) {
    steps.add(EtaStep(
      '🏁 Ziel ${_fmt(state.current)}${location.isEmpty ? '' : ' – $location'}',
      type: EtaEventType.destination,
      title: 'Ziel',
      detail: location,
      start: state.current,
      end: state.current,
    ));
  }

  void addNotice(String text) {
    steps.add(EtaStep(text, technical: true));
  }

  /// Hinweis, der in der Timeline sichtbar bleibt. [addNotice] setzt
  /// `technical`, und genau solche Schritte blendet die Touransicht aus –
  /// für Fahrerhinweise ist das die falsche Ablage.
  void addInfo(String title, String detail) {
    steps.add(EtaStep(
      'ℹ️ $title',
      type: EtaEventType.notice,
      title: title,
      detail: detail,
      start: state.current,
      end: state.current,
    ));
  }

  void _addBreak(int minutes, {String title = 'Lenkpause'}) {
    final eventStart = state.current;
    state.current = state.current.add(Duration(minutes: minutes));
    state.dutyElapsedMin += minutes;
    steps.add(EtaStep(
      '☕ $title ${_fmtHm(minutes)} '
      '(${DateFormat('HH:mm').format(eventStart)}–${DateFormat('HH:mm').format(state.current)})',
      type: EtaEventType.breakTime,
      title: '$title · ${_fmtHm(minutes)}',
      start: eventStart,
      end: state.current,
    ));
    if ((minutes >= 30 && state.splitFirstPartTaken) || minutes >= 45) {
      state.continuousDriveMin = 0;
      state.splitFirstPartTaken = false;
    }
  }

  void _addTankPause() {
    final eventStart = state.current;
    state.current = state.current.add(const Duration(minutes: 30));
    state.dutyElapsedMin += 30;
    state.tankUsed = true;
    steps.add(EtaStep(
      '⛽ Tankstopp 30 min '
      '(${DateFormat('HH:mm').format(eventStart)}–${DateFormat('HH:mm').format(state.current)})',
      type: EtaEventType.tank,
      title: 'Tankstopp · 30 min',
      detail: 'Zählt als sonstige Arbeit, nicht als Lenkpause',
      start: eventStart,
      end: state.current,
    ));
  }

  void _addDailyRest() {
    final reduced = state.reducedRestsRemaining > 0;
    final minutes = reduced ? 540 : 660;
    final eventStart = state.current;
    state.current = state.current.add(Duration(minutes: minutes));
    if (reduced) {
      state.reducedRestsRemaining -= 1;
      state.reducedRestsUsed += 1;
    }
    steps.add(EtaStep(
      '🌙 ${reduced ? 'Verkürzte' : 'Reguläre'} Tagesruhe ${_fmtHm(minutes)} '
      '(${DateFormat('EEE HH:mm', 'de').format(eventStart)}–${DateFormat('EEE HH:mm', 'de').format(state.current)})',
      type: EtaEventType.dailyRest,
      title:
          '${reduced ? 'Verkürzte' : 'Reguläre'} Tagesruhe · ${_fmtHm(minutes)}',
      detail: 'Neue tägliche Lenkzeit beginnt danach',
      start: eventStart,
      end: state.current,
      restSatisfied: true,
    ));
    _resetDailyState();
  }

  void _addWeeklyRest() {
    const minutes = 45 * 60;
    final eventStart = state.current;
    state.current = state.current.add(const Duration(minutes: minutes));
    steps.add(EtaStep(
      '🛏 Wochenruhe 45h (${_fmt(eventStart)}–${_fmt(state.current)})',
      type: EtaEventType.weeklyRest,
      title: 'Reguläre Wochenruhe · 45 h',
      detail: 'Vor der Weiterfahrt eingeplant',
      start: eventStart,
      end: state.current,
      restSatisfied: true,
    ));
    _resetDailyState();
  }

  void _resetDailyState() {
    state.continuousDriveMin = 0;
    state.dailyDriveMin = 0;
    state.dutyElapsedMin = 0;
    state.splitFirstPartTaken = false;
  }

  EtaResult finish(double totalKm) {
    int driving = 0;
    int breaks = 0;
    int rests = 0;
    int waiting = 0;
    int ferry = 0;
    int ferryRest = 0;
    int tank = 0;
    for (final step in steps) {
      final minutes = step.duration.inMinutes;
      switch (step.type) {
        case EtaEventType.drive:
          driving += minutes;
        case EtaEventType.breakTime:
          breaks += minutes;
        case EtaEventType.dailyRest:
        case EtaEventType.weeklyRest:
          rests += minutes;
        case EtaEventType.wait:
          waiting += minutes;
        case EtaEventType.ferry:
          ferry += minutes;
          if (step.restSatisfied == true) ferryRest += minutes;
        case EtaEventType.tank:
          tank += minutes;
        case EtaEventType.start:
        case EtaEventType.stop:
        case EtaEventType.destination:
        case EtaEventType.notice:
          break;
      }
    }
    return EtaResult(
      List.unmodifiable(steps),
      state.current,
      summary: EtaSummary(
        distanceKm: totalKm,
        averageKmh: avgKmh,
        drivingMinutes: driving,
        breakMinutes: breaks,
        restMinutes: rests,
        waitingMinutes: waiting,
        ferryMinutes: ferry,
        ferryRestMinutes: ferryRest,
        tankMinutes: tank,
        tenHourDaysUsed: state.tenHourDaysUsed,
        reducedDailyRestsUsed: state.reducedRestsUsed,
      ),
    );
  }
}

class EtaCalculator {
  static EtaResult computeTwoShortFerries({
    required DateTime start,
    required int alreadyDrivenMin,
    int? alreadyDrivenSinceBreakMin,
    required int dutyTimeOffsetMin,
    required double avgKmh,
    required DriveRulesConfig rules,
    required double kmBefore,
    required double kmBetween,
    required double kmAfter,
    required String firstDeparturePort,
    required String firstFerry,
    required int firstFerryMinutes,
    required String secondDeparturePort,
    required String secondFerry,
    required int secondFerryMinutes,
    String startLabel = '',
    String destinationLabel = '',
  }) {
    final planner = _Planner(
      start: start,
      alreadyDrivenMin: alreadyDrivenMin,
      continuousDrivenMin: alreadyDrivenSinceBreakMin ?? alreadyDrivenMin,
      dutyTimeOffsetMin: dutyTimeOffsetMin,
      avgKmh: avgKmh,
      rules: rules,
    );
    planner.addStart(startLabel);
    planner.planLeg(driveMinutes: _minsFromKm(kmBefore, avgKmh), km: kmBefore);
    planner.addPortArrival(firstDeparturePort);
    planner.addFerryPassage(
      label: firstFerry,
      departure: planner.state.current,
      crossingMinutes: firstFerryMinutes,
    );
    planner.planLeg(
        driveMinutes: _minsFromKm(kmBetween, avgKmh), km: kmBetween);
    planner.addPortArrival(secondDeparturePort);
    planner.addFerryPassage(
      label: secondFerry,
      departure: planner.state.current,
      crossingMinutes: secondFerryMinutes,
    );
    planner.planLeg(driveMinutes: _minsFromKm(kmAfter, avgKmh), km: kmAfter);
    planner.addDestination(destinationLabel);
    return planner.finish(kmBefore + kmBetween + kmAfter);
  }

  static EtaResult compute({
    required DateTime start,
    required int alreadyDrivenMin,
    int? alreadyDrivenSinceBreakMin,
    required int dutyTimeOffsetMin,
    required double km,
    required double avgKmh,
    required DriveRulesConfig rules,
    String startLabel = '',
    String destinationLabel = '',
  }) {
    final planner = _Planner(
      start: start,
      alreadyDrivenMin: alreadyDrivenMin,
      continuousDrivenMin: alreadyDrivenSinceBreakMin ?? alreadyDrivenMin,
      dutyTimeOffsetMin: dutyTimeOffsetMin,
      avgKmh: avgKmh,
      rules: rules,
    );
    planner.addStart(startLabel);
    planner.planLeg(driveMinutes: _minsFromKm(km, avgKmh), km: km);
    planner.addDestination(destinationLabel);
    return planner.finish(km);
  }

  static EtaResult computeTwoLegsWithFerry({
    required DateTime start,
    required int alreadyDrivenMin,
    int? alreadyDrivenSinceBreakMin,
    required int dutyTimeOffsetMin,
    required double kmBefore,
    required double kmAfter,
    required double avgKmh,
    required DriveRulesConfig rules,
    required String ferryLabel,
    required int ferryDurationMin,
    List<String>? departuresHHmm,
    Map<int, List<String>> departuresByWeekday = const {},
    String departureTz = '',
    DateTime? manualDeparture,
    String startLabel = '',
    String destinationLabel = '',
    String departurePort = '',
  }) {
    final planner = _Planner(
      start: start,
      alreadyDrivenMin: alreadyDrivenMin,
      continuousDrivenMin: alreadyDrivenSinceBreakMin ?? alreadyDrivenMin,
      dutyTimeOffsetMin: dutyTimeOffsetMin,
      avgKmh: avgKmh,
      rules: rules,
    );
    planner.addStart(startLabel);
    planner.planLeg(
      driveMinutes: _minsFromKm(kmBefore, avgKmh),
      km: kmBefore,
    );
    planner.addPortArrival(departurePort);

    DateTime departure;
    if (manualDeparture != null &&
        manualDeparture.isAfter(planner.state.current)) {
      departure = manualDeparture;
    } else if (manualDeparture != null) {
      departure = planner.state.current;
      planner.addNotice(
          '⚠️ Die manuelle Fährabfahrt lag vor der Hafenankunft und wurde auf „sofort“ gesetzt.');
    } else {
      final scheduled = FerrySchedule.nextDeparture(
        planner.state.current,
        departuresHHmm ?? const [],
        departureTz,
        departuresByWeekday: departuresByWeekday,
      );
      if (scheduled == null) {
        // Ohne hinterlegten Fahrplan lieber offen sagen, dass hier keine
        // Wartezeit eingeplant ist, als eine Abfahrt zu erfinden.
        planner.addInfo(
          'Kein Fahrplan hinterlegt',
          'Für diese Verbindung sind keine Abfahrtszeiten gespeichert. '
              'Gerechnet ohne Hafenwartezeit – die tatsächliche Abfahrt bitte '
              'beim Betreiber prüfen.',
        );
      }
      departure = scheduled ?? planner.state.current;
    }
    planner.addFerryPassage(
      label: ferryLabel,
      departure: departure,
      crossingMinutes: ferryDurationMin,
    );
    planner.planLeg(
      driveMinutes: _minsFromKm(kmAfter, avgKmh),
      km: kmAfter,
    );
    planner.addDestination(destinationLabel);
    return planner.finish(kmBefore + kmAfter);
  }

  static int _minsFromKm(double km, double avgKmh) {
    if (km <= 0 || avgKmh <= 0) return 0;
    return (km / avgKmh * 60).round();
  }
}

class TimeOfDayLite {
  final int hour;
  final int minute;

  const TimeOfDayLite(this.hour, this.minute);
}

String _fmt(DateTime value) =>
    DateFormat('EEE, dd.MM. HH:mm', 'de').format(value);

String _fmtHm(int minutes) {
  final hours = minutes ~/ 60;
  final rest = minutes % 60;
  if (hours == 0) return '$rest min';
  if (rest == 0) return '$hours h';
  return '$hours h ${rest.toString().padLeft(2, '0')} min';
}
