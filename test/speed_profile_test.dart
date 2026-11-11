import 'package:driverroute_eta/logic/speed_profile.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Automatik verwendet den aus der Route ermittelten Schnitt', () {
    final plan = SpeedProfileResolver.resolve(
      profile: SpeedProfile.automatic,
      customKmh: 80,
      routedKmh: 69.74,
      routeLabels: const ['Wien', 'Hamburg'],
    );

    expect(plan.kmh, 69.7);
  });

  test('Automatik begrenzt schnelle Routen auf 80 km/h', () {
    final plan = SpeedProfileResolver.resolve(
      profile: SpeedProfile.automatic,
      customKmh: 80,
      routedKmh: 96,
    );

    expect(plan.kmh, 80);
  });

  test('Norwegen nutzt vorhandene Routendaten statt einer Pauschale', () {
    final plan = SpeedProfileResolver.resolve(
      profile: SpeedProfile.automatic,
      customKmh: 80,
      routedKmh: 74,
      routeLabels: const ['Kiel, Deutschland', 'Oslo, Norge'],
    );

    expect(plan.kmh, 74);
  });

  test('Norwegen verwendet 60 km/h nur als Fallback ohne Routendaten', () {
    final plan = SpeedProfileResolver.resolve(
      profile: SpeedProfile.automatic,
      customKmh: 80,
      routeLabels: const ['Kiel, Deutschland', 'Oslo, Norge'],
    );

    expect(plan.kmh, 60);
    expect(plan.reason, contains('Norwegen-Fallback'));
  });

  test('manuelle Profile liefern exakt 80, 70 und 60 km/h', () {
    expect(
      SpeedProfileResolver.resolve(
        profile: SpeedProfile.standard80,
        customKmh: 55,
      ).kmh,
      80,
    );
    expect(
      SpeedProfileResolver.resolve(
        profile: SpeedProfile.mixedRoads70,
        customKmh: 55,
      ).kmh,
      70,
    );
    expect(
      SpeedProfileResolver.resolve(
        profile: SpeedProfile.norway60,
        customKmh: 55,
      ).kmh,
      60,
    );
  });

  test('Straßenmix wird distanzgewichtet und ohne Fähre analysiert', () {
    final analysis = RoadMixAnalysis.fromDirectionsSteps([
      {
        'distance': {'value': 100000},
        'duration': {'value': 3600},
      },
      {
        'distance': {'value': 50000},
        'duration': {'value': 3600},
      },
      {
        'distance': {'value': 10000},
        'duration': {'value': 1800},
      },
      {
        'distance': {'value': 200000},
        'duration': {'value': 36000},
        'maneuver': 'ferry',
      },
    ]);

    expect(analysis, isNotNull);
    expect(analysis!.roadKm, 160);
    expect(analysis.averageKmh, 64);
    expect(analysis.fastPercent, 63);
    expect(analysis.mainRoadPercent, 31);
    expect(analysis.slowPercent, 6);
  });

  // --- Zuschlag für schwere Ladung ---------------------------------------

  test('schwere Ladung rechnet mehr Fahrzeit', () {
    const km = 800.0;
    final normal = SpeedProfileResolver.resolve(
      profile: SpeedProfile.standard80,
      customKmh: 80,
    );
    final beladen = SpeedProfileResolver.resolve(
      profile: SpeedProfile.standard80,
      customKmh: 80,
      heavyLoad: true,
    );
    expect(beladen.kmh, lessThan(normal.kmh));
    final minutenNormal = km / normal.kmh * 60;
    final minutenBeladen = km / beladen.kmh * 60;
    expect(minutenBeladen / minutenNormal, closeTo(heavyLoadTimeFactor, 0.01));
    expect(beladen.reason, contains('schwere Ladung'));
  });

  test('Zuschlag wirkt auch auf die automatische Berechnung', () {
    final normal = SpeedProfileResolver.resolve(
      profile: SpeedProfile.automatic,
      customKmh: 80,
      routedKmh: 66,
    );
    final beladen = SpeedProfileResolver.resolve(
      profile: SpeedProfile.automatic,
      customKmh: 80,
      routedKmh: 66,
      heavyLoad: true,
    );
    expect(normal.kmh, closeTo(66, 0.1));
    expect(beladen.kmh, closeTo(66 / heavyLoadTimeFactor, 0.1));
  });

  test('langsame LKW-Strecken werden nicht mehr auf 40 hochgeklammert', () {
    final plan = SpeedProfileResolver.resolve(
      profile: SpeedProfile.automatic,
      customKmh: 80,
      routedKmh: 34,
    );
    expect(plan.kmh, closeTo(34, 0.1));
  });
}
