import 'package:driverroute_eta/logic/truck_speed.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, dynamic> step(double km, double kmh) => {
      'distance': {'value': (km * 1000).round()},
      'duration': {'value': (km / kmh * 3600).round()},
    };

void main() {
  const profile = TruckSpeedProfile();

  group('Tempo-Deckel je Straßentyp', () {
    test('Autobahn wird auf 80 km/h gedeckelt', () {
      expect(profile.truckKmh(130), 80);
      expect(profile.truckKmh(110), 80);
      expect(profile.truckKmh(95), 80);
    });

    test('Schnellstraße etwas darunter', () {
      expect(profile.truckKmh(90), 72);
      expect(profile.truckKmh(75), 72);
    });

    test('Bundesstraße noch etwas darunter', () {
      expect(profile.truckKmh(70), 62);
      expect(profile.truckKmh(60), 60, reason: 'nie schneller als Google');
    });

    test('langsame Straßen behalten Googles Tempo (minus 5 %)', () {
      expect(profile.truckKmh(50), closeTo(47.5, 0.01));
      expect(profile.truckKmh(30), closeTo(28.5, 0.01));
    });
  });

  test('Autobahnetappe: LKW braucht länger als Google', () {
    final r = truckDriveTimeFromSteps(steps: [step(400, 110)], totalKm: 400);
    expect(r.googleMinutes, closeTo(218, 1)); // 400 km bei 110 km/h
    expect(r.minutes, closeTo(300, 1)); // 400 km bei 80 km/h
    expect(r.avgKmh, closeTo(80, 0.5));
    expect(r.isComplete, isTrue);
  });

  test('schmale Straßen bleiben langsam – kein künstliches Hochrechnen', () {
    final r = truckDriveTimeFromSteps(steps: [step(100, 55)], totalKm: 100);
    expect(r.avgKmh, closeTo(52.25, 0.5));
    expect(r.minutes, greaterThan(r.googleMinutes));
  });

  test('gemischte Route Lambach → Norden: Autobahn gedeckelt, Landstraße nicht', () {
    final r = truckDriveTimeFromSteps(
      steps: [step(900, 115), step(150, 70), step(120, 50)],
      totalKm: 1170,
    );
    // 900/80 + 150/62 + 120/47.5 Stunden
    final expected = (900 / 80 + 150 / 62 + 120 / 47.5) * 60;
    expect(r.minutes, closeTo(expected, 2));
    expect(r.avgKmh, lessThan(80));
    expect(r.avgKmh, greaterThan(60));
  });

  test('ohne Step-Daten greift das Fallback-Tempo', () {
    final r = truckDriveTimeFromSteps(steps: const [], totalKm: 200, fallbackKmh: 80);
    expect(r.minutes, closeTo(150, 1));
    expect(r.isComplete, isFalse);
  });

  test('Teilstrecke ohne Step-Daten wird ergänzt', () {
    final r = truckDriveTimeFromSteps(steps: [step(100, 110)], totalKm: 180, fallbackKmh: 80);
    final expected = (100 / 80 + 80 / 80) * 60;
    expect(r.minutes, closeTo(expected, 1));
    expect(r.coveredKm, closeTo(100, 0.1));
    expect(r.isComplete, isFalse);
  });
}
