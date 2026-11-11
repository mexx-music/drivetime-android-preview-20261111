enum SpeedProfile {
  automatic,
  standard80,
  mixedRoads70,
  norway60,
  custom,
}

extension SpeedProfilePresentation on SpeedProfile {
  String get label => switch (this) {
        SpeedProfile.automatic => 'Automatisch',
        SpeedProfile.standard80 => 'Standard 80',
        SpeedProfile.mixedRoads70 => 'Viel Bundesstraße 70',
        SpeedProfile.norway60 => 'Norwegen 60',
        SpeedProfile.custom => 'Individuell',
      };

  String get description => switch (this) {
        SpeedProfile.automatic =>
          'Wertet Distanz und Fahrtdauer der einzelnen Routenabschnitte aus, '
              'höchstens 80 km/h. 60 km/h für Norwegen ist nur der Fallback '
              'ohne Routendaten.',
        SpeedProfile.standard80 =>
          'Für überwiegend flüssige Autobahnfahrt: 80 km/h.',
        SpeedProfile.mixedRoads70 =>
          'Für einen hohen Anteil Bundes- und Landstraße: 70 km/h.',
        SpeedProfile.norway60 =>
          'Konservatives Profil für Norwegen und langsame Strecken: 60 km/h.',
        SpeedProfile.custom =>
          'Eigener Planungsschnitt zwischen 40 und 90 km/h.',
      };
}

class SpeedPlan {
  final double kmh;
  final String reason;

  const SpeedPlan({required this.kmh, required this.reason});
}

/// Zuschlag für schwere Ladung.
///
/// Voll beladen geht am Berg und beim Beschleunigen Zeit verloren – das
/// steckt in Googles PKW-Zeiten nicht drin. Der Zuschlag wirkt auf jedes
/// Profil, nicht nur auf die automatische Berechnung.
const double heavyLoadTimeFactor = 1.10;

class SpeedProfileResolver {
  static SpeedPlan resolve({
    required SpeedProfile profile,
    required double customKmh,
    double? routedKmh,
    Iterable<String> routeLabels = const [],
    bool heavyLoad = false,
  }) {
    final plan = _resolveBase(
      profile: profile,
      customKmh: customKmh,
      routedKmh: routedKmh,
      routeLabels: routeLabels,
    );
    if (!heavyLoad) return plan;
    return SpeedPlan(
      kmh: ((plan.kmh / heavyLoadTimeFactor) * 10).round() / 10,
      reason: '${plan.reason} · schwere Ladung '
          '+${((heavyLoadTimeFactor - 1) * 100).round()} % Fahrzeit',
    );
  }

  static SpeedPlan _resolveBase({
    required SpeedProfile profile,
    required double customKmh,
    double? routedKmh,
    Iterable<String> routeLabels = const [],
  }) {
    switch (profile) {
      case SpeedProfile.standard80:
        return const SpeedPlan(kmh: 80, reason: 'manuelles Standardprofil');
      case SpeedProfile.mixedRoads70:
        return const SpeedPlan(
          kmh: 70,
          reason: 'manuelles Bundes-/Landstraßenprofil',
        );
      case SpeedProfile.norway60:
        return const SpeedPlan(kmh: 60, reason: 'manuelles Norwegenprofil');
      case SpeedProfile.custom:
        final value = customKmh.clamp(40, 90).toDouble();
        return SpeedPlan(kmh: value, reason: 'individuelle Vorgabe');
      case SpeedProfile.automatic:
        final norway = touchesNorway(routeLabels);
        final hasRouteData =
            routedKmh != null && routedKmh.isFinite && routedKmh > 0;
        final value = hasRouteData
            ? routedKmh.clamp(25, 80).toDouble()
            : (norway ? 60.0 : 80.0);
        final reason = hasRouteData
            ? 'LKW-Tempo je Streckenabschnitt'
            : norway
                ? 'Norwegen-Fallback ohne Routendaten'
                : 'automatischer Standardwert ohne Routendaten';
        return SpeedPlan(
          kmh: (value * 10).round() / 10,
          reason: reason,
        );
    }
  }

  static bool touchesNorway(Iterable<String> routeLabels) {
    const norwayTokens = ['norwegen', 'norway', 'norge', 'noreg'];
    final routeText = routeLabels.join(' ').toLowerCase();
    return norwayTokens.any(routeText.contains);
  }
}

class RoadMixAnalysis {
  final double roadKm;
  final double averageKmh;
  final double fastShare;
  final double mainRoadShare;
  final double slowShare;

  const RoadMixAnalysis({
    required this.roadKm,
    required this.averageKmh,
    required this.fastShare,
    required this.mainRoadShare,
    required this.slowShare,
  });

  int get fastPercent => (fastShare * 100).round();
  int get mainRoadPercent => (mainRoadShare * 100).round();
  int get slowPercent => 100 - fastPercent - mainRoadPercent;
  bool get hasBreakdown => fastShare + mainRoadShare + slowShare > 0.99;

  /// Google liefert keine europaweit einheitliche Straßenklasse. Deshalb
  /// gruppieren wir die geplanten Geschwindigkeiten der einzelnen Abschnitte.
  static RoadMixAnalysis? fromDirectionsSteps(
    Iterable<Map<String, dynamic>> steps,
  ) {
    var totalMeters = 0.0;
    var totalSeconds = 0.0;
    var fastMeters = 0.0;
    var mainMeters = 0.0;
    var slowMeters = 0.0;

    for (final step in steps) {
      if (_isFerryStep(step)) continue;
      final distance = step['distance'];
      final duration = step['duration'];
      if (distance is! Map || duration is! Map) continue;
      final meters = (distance['value'] as num?)?.toDouble() ?? 0;
      final seconds = (duration['value'] as num?)?.toDouble() ?? 0;
      if (meters <= 0 || seconds <= 0) continue;

      final kmh = (meters / 1000) / (seconds / 3600);
      totalMeters += meters;
      totalSeconds += seconds;
      if (kmh >= 72) {
        fastMeters += meters;
      } else if (kmh >= 48) {
        mainMeters += meters;
      } else {
        slowMeters += meters;
      }
    }

    if (totalMeters <= 0 || totalSeconds <= 0) return null;
    return RoadMixAnalysis(
      roadKm: totalMeters / 1000,
      averageKmh: (totalMeters / 1000) / (totalSeconds / 3600),
      fastShare: fastMeters / totalMeters,
      mainRoadShare: mainMeters / totalMeters,
      slowShare: slowMeters / totalMeters,
    );
  }

  static bool _isFerryStep(Map<String, dynamic> step) {
    final text = '${step['maneuver'] ?? ''} '
            '${step['html_instructions'] ?? ''}'
        .toLowerCase();
    const tokens = ['ferry', 'fähre', 'faehre', 'trajekt', 'feribot'];
    return tokens.any(text.contains);
  }
}
