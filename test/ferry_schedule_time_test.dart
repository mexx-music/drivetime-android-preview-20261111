import 'package:flutter_test/flutter_test.dart';
import 'package:timezone/data/latest.dart' as tz_data;

import 'package:driverroute_eta/logic/ferry_schedule.dart';

void main() {
  setUpAll(() => tz_data.initializeTimeZones());

  const patras = ['08:00', '17:30', '22:00'];

  test('nimmt die nächste Abfahrt nach der Hafenankunft', () {
    // 14:00 Ortszeit Athen → nächste Abfahrt 17:30 Ortszeit Athen.
    final arrival = DateTime.utc(2026, 7, 1, 11); // 14:00 in Athen (UTC+3)
    final dep = FerrySchedule.nextDeparture(arrival, patras, 'Europe/Athens');
    expect(dep, isNotNull);
    expect(dep!.toUtc(), DateTime.utc(2026, 7, 1, 14, 30)); // 17:30 Athen
  });

  test('springt auf den Folgetag, wenn heute nichts mehr geht', () {
    final arrival = DateTime.utc(2026, 7, 1, 20); // 23:00 in Athen
    final dep = FerrySchedule.nextDeparture(arrival, patras, 'Europe/Athens');
    expect(dep!.toUtc(), DateTime.utc(2026, 7, 2, 5)); // 08:00 Athen
  });

  test('genau zur Abfahrtszeit zählt noch', () {
    final arrival = DateTime.utc(2026, 7, 1, 5); // 08:00 in Athen
    final dep = FerrySchedule.nextDeparture(arrival, patras, 'Europe/Athens');
    expect(dep!.toUtc(), DateTime.utc(2026, 7, 1, 5));
  });

  test('Hafen-Ortszeit ist nicht Gerätezeit', () {
    // Dieselbe Abfahrt aus Sicht eines Geräts in Wien (UTC+2 im Sommer):
    // 17:30 in Patras sind dort 16:30.
    final arrival = DateTime.utc(2026, 7, 1, 11);
    final dep = FerrySchedule.nextDeparture(arrival, patras, 'Europe/Athens')!;
    final wien = dep.toUtc().add(const Duration(hours: 2));
    expect(wien.hour, 16);
    expect(wien.minute, 30);
  });

  test('unbekannte Zeitzone fällt auf Gerätezeit zurück', () {
    final arrival = DateTime(2026, 7, 1, 14);
    final dep = FerrySchedule.nextDeparture(arrival, patras, 'Nicht/Existent');
    expect(dep, DateTime(2026, 7, 1, 17, 30));
  });

  test('leerer oder kaputter Fahrplan liefert null', () {
    final now = DateTime(2026, 7, 1, 14);
    expect(FerrySchedule.nextDeparture(now, const [], 'Europe/Athens'), isNull);
    expect(FerrySchedule.nextDeparture(now, const ['25:99', 'abc'], 'Europe/Athens'),
        isNull);
  });

  test('Wochenfahrplan berücksichtigt den tatsächlichen Wochentag', () {
    final arrival = DateTime.utc(2026, 9, 21, 17); // Montag, 19:00 in Kiel
    final departure = FerrySchedule.nextDeparture(
      arrival,
      const [],
      'Europe/Berlin',
      departuresByWeekday: const {
        DateTime.monday: ['18:45'],
        DateTime.tuesday: ['18:45'],
      },
    );

    expect(departure!.toUtc(), DateTime.utc(2026, 9, 22, 16, 45));
  });

  test('Wochenfahrplan überspringt einen Tag ohne Abfahrt', () {
    final arrival = DateTime.utc(2026, 9, 25, 10); // Freitag, 12:00 in Polen
    final departure = FerrySchedule.nextDeparture(
      arrival,
      const [],
      'Europe/Warsaw',
      departuresByWeekday: const {
        DateTime.friday: ['04:00', '10:00'],
        DateTime.saturday: [],
        DateTime.sunday: ['05:00'],
      },
    );

    expect(departure!.toUtc(), DateTime.utc(2026, 9, 27, 3));
  });

  // --- Auswahl einer planmäßigen Abfahrt für ein Datum -------------------

  test('Wochentagsplan liefert die Zeiten des richtigen Tages', () {
    const proWochentag = {
      1: ['18:45'],
      6: ['17:45'],
    };
    // 6. Juli 2026 ist ein Montag, 11. Juli ein Samstag.
    expect(
      FerrySchedule.timesForDate(DateTime(2026, 7, 6), const [], 'Europe/Berlin',
          departuresByWeekday: proWochentag),
      ['18:45'],
    );
    expect(
      FerrySchedule.timesForDate(DateTime(2026, 7, 11), const [], 'Europe/Berlin',
          departuresByWeekday: proWochentag),
      ['17:45'],
    );
    // Sonntag ist im Plan nicht enthalten
    expect(
      FerrySchedule.timesForDate(DateTime(2026, 7, 12), const [], 'Europe/Berlin',
          departuresByWeekday: proWochentag),
      isEmpty,
    );
  });

  test('ohne Wochentagsplan gilt die flache Liste', () {
    expect(
      FerrySchedule.timesForDate(
          DateTime(2026, 7, 6), const ['08:00', '17:30'], 'Europe/Athens'),
      ['08:00', '17:30'],
    );
  });

  test('gewählte Hafenzeit wird in Gerätezeit umgerechnet', () {
    // 18:00 in Patras entspricht 15:00 UTC.
    final when =
        FerrySchedule.atPortTime(DateTime(2026, 7, 6), '18:00', 'Europe/Athens');
    expect(when!.toUtc(), DateTime.utc(2026, 7, 6, 15));
  });

  test('unbekannte Zeitzone nimmt die Zeit wie eingegeben', () {
    final when =
        FerrySchedule.atPortTime(DateTime(2026, 7, 6), '18:00', 'Quatsch/Zone');
    expect(when, DateTime(2026, 7, 6, 18));
  });
}
