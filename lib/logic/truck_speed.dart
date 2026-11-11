/// Rechnet Google-Fahrzeiten (PKW) auf LKW-Fahrzeiten um.
///
/// Google liefert je Streckenabschnitt (Step) Distanz und Dauer. Daraus ergibt
/// sich das tatsächlich angesetzte Tempo – und damit indirekt der Straßentyp:
/// Autobahnabschnitte laufen bei Google mit 100–130 km/h, Landstraßen mit
/// 60–80, enge Straßen (z. B. in Norwegen) deutlich darunter.
///
/// Für den LKW wird dieses Tempo gedeckelt. Auf schmalen Straßen greift der
/// Deckel gar nicht – dort ist Google ohnehin langsam, und genau diese Zeit
/// ist realistisch.
class TruckSpeedProfile {
  const TruckSpeedProfile({
    this.motorwayKmh = 80,
    this.expresswayKmh = 72,
    this.mainRoadKmh = 62,
    this.slowRoadFactor = 0.95,
  });

  /// Deckel für Autobahnabschnitte (Google ≥ [motorwayThreshold]).
  final double motorwayKmh;

  /// Deckel für Schnellstraßen.
  final double expresswayKmh;

  /// Deckel für Bundes-/Landstraßen.
  final double mainRoadKmh;

  /// Auf langsamen Straßen wird Googles Tempo nur leicht reduziert.
  final double slowRoadFactor;

  static const double motorwayThreshold = 95;
  static const double expresswayThreshold = 75;
  static const double mainRoadThreshold = 60;

  /// LKW-Tempo für einen Abschnitt, dessen Google-Tempo [googleKmh] ist.
  double truckKmh(double googleKmh) {
    if (googleKmh <= 0) return 0;
    if (googleKmh >= motorwayThreshold) return motorwayKmh;
    if (googleKmh >= expresswayThreshold) {
      return googleKmh < expresswayKmh ? googleKmh : expresswayKmh;
    }
    if (googleKmh >= mainRoadThreshold) {
      return googleKmh < mainRoadKmh ? googleKmh : mainRoadKmh;
    }
    return googleKmh * slowRoadFactor;
  }
}

/// Ergebnis der Umrechnung.
class TruckDriveTime {
  const TruckDriveTime({
    required this.minutes,
    required this.km,
    required this.googleMinutes,
    required this.coveredKm,
  });

  /// Fahrzeit für den LKW in Minuten.
  final int minutes;

  /// Gesamtstrecke in km.
  final double km;

  /// Googles eigene Fahrzeit in Minuten (zum Vergleich / für Logs).
  final int googleMinutes;

  /// Strecke, für die Step-Daten vorlagen (Rest wurde geschätzt).
  final double coveredKm;

  /// Durchschnittstempo, das sich aus der LKW-Fahrzeit ergibt.
  double get avgKmh => minutes <= 0 ? 0 : km / (minutes / 60.0);

  bool get isComplete => km <= 0 || coveredKm >= km * 0.99;
}

/// Rechnet die Steps einer Google-Route auf LKW-Fahrzeit um.
///
/// [steps] sind die Rohdaten aus der Directions-Antwort (je Step
/// `distance.value` in Metern und `duration.value` in Sekunden).
/// [fallbackKmh] wird nur für Strecken benutzt, zu denen keine Step-Daten
/// vorliegen; [totalKm] ist die verlässliche Gesamtdistanz der Route.
TruckDriveTime truckDriveTimeFromSteps({
  required List<Map<String, dynamic>> steps,
  required double totalKm,
  double fallbackKmh = 80,
  TruckSpeedProfile profile = const TruckSpeedProfile(),
}) {
  double coveredMeters = 0;
  double googleSeconds = 0;
  double truckSeconds = 0;

  for (final st in steps) {
    final meters = ((st['distance']?['value'] ?? 0) as num).toDouble();
    final seconds = ((st['duration']?['value'] ?? 0) as num).toDouble();
    if (meters <= 0 || seconds <= 0) continue;

    coveredMeters += meters;
    googleSeconds += seconds;

    final googleKmh = (meters / 1000.0) / (seconds / 3600.0);
    final kmh = profile.truckKmh(googleKmh);
    truckSeconds += kmh <= 0 ? seconds : (meters / 1000.0) / kmh * 3600.0;
  }

  // Strecke ohne Step-Daten mit dem Fallback-Tempo ergänzen.
  final coveredKm = coveredMeters / 1000.0;
  final restKm = totalKm - coveredKm;
  if (restKm > 0.5 && fallbackKmh > 0) {
    truckSeconds += restKm / fallbackKmh * 3600.0;
    googleSeconds += restKm / fallbackKmh * 3600.0;
  }

  return TruckDriveTime(
    minutes: (truckSeconds / 60).round(),
    km: totalKm,
    googleMinutes: (googleSeconds / 60).round(),
    coveredKm: coveredKm,
  );
}
