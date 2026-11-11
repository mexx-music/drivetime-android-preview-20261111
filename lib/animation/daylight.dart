import 'dart:math' as math;

import '../logic/eta_calculator.dart';
import 'tour_path.dart';
import 'tour_story.dart';

/// Woher die Uhrzeit für Tag/Nacht kommt.
enum DayNightMode {
  /// Kein Tag/Nacht (bisher).
  off,

  /// Aus der DriveTime-Planung (ETA-Zeiten entlang der Strecke).
  plan,

  /// Demo: ein voller Tag (Tag → Dämmerung → Nacht → Morgen) über die Fahrt.
  simulated,
}

/// Sonnenstand und Tageslicht – lokal berechnet, ohne Dienst.
///
/// Sonnenhöhe nach dem vereinfachten NOAA-Verfahren (Genauigkeit etwa ±1°,
/// für Tag/Dämmerung/Nacht weit ausreichend). Braucht nur Position und
/// absolute Zeit (UTC) – Zeitzonen spielen dafür keine Rolle.
double sunElevation(double lat, double lon, DateTime utc) {
  final t = utc.toUtc();
  final dayOfYear = t.difference(DateTime.utc(t.year)).inMinutes / 1440.0; // 0-basiert, mit Uhrzeit
  final gamma = 2 * math.pi / 365 * (dayOfYear - 0.5);
  final eqTime = 229.18 *
      (0.000075 +
          0.001868 * math.cos(gamma) -
          0.032077 * math.sin(gamma) -
          0.014615 * math.cos(2 * gamma) -
          0.040849 * math.sin(2 * gamma));
  final decl = 0.006918 -
      0.399912 * math.cos(gamma) +
      0.070257 * math.sin(gamma) -
      0.006758 * math.cos(2 * gamma) +
      0.000907 * math.sin(2 * gamma) -
      0.002697 * math.cos(3 * gamma) +
      0.00148 * math.sin(3 * gamma);
  final minutes = t.hour * 60 + t.minute + t.second / 60;
  final trueSolar = minutes + eqTime + 4 * lon; // Minuten
  final hourAngle = (trueSolar / 4 - 180) * math.pi / 180;
  final phi = lat * math.pi / 180;
  final cosZenith =
      math.sin(phi) * math.sin(decl) + math.cos(phi) * math.cos(decl) * math.cos(hourAngle);
  return 90 - math.acos(cosZenith.clamp(-1.0, 1.0)) * 180 / math.pi;
}

/// Dunkelheit 0 (Tag) … 1 (Nacht) aus der Sonnenhöhe: hell ab +6°,
/// Dämmerung bis −8°, darunter Nacht. Weich (Smoothstep).
double nightLevel(double elevationDeg) {
  final x = ((6 - elevationDeg) / 14).clamp(0.0, 1.0);
  return x * x * (3 - 2 * x);
}

/// Uhrzeit entlang der Tour aus der DriveTime-Planung (ETA).
///
/// Jeder Fahrabschnitt der ETA hat Beginn, Ende und Kilometer; damit ist
/// jeder Streckenpunkt eindeutig einer Zeit zugeordnet. An Pausen und
/// Ruhezeiten springt die Zeit (das Fahrzeug steht real, die Animation fährt
/// weiter) – die Darstellung blendet das weich über ([DaylightEaser]).
class TourClock {
  TourClock._(this._segments);

  /// null, wenn die Planung keine Zeiten hat.
  ///
  /// Fähren: Der Fährschritt der Planung (Beginn/Ende der Überfahrt) liegt
  /// auf dem Fährabschnitt der Linie – die n-te Überfahrt der Planung auf
  /// dem n-ten Fährabschnitt. Die Fahrt danach beginnt erst am Zielhafen.
  /// Ohne Fähre ändert sich nichts.
  static TourClock? fromEta(EtaResult eta, TourPath path) {
    final totalKm = etaDriveKm(eta);
    if (totalKm <= 0) return null;
    final ferries = [
      for (final s in path.legSpans)
        if (s.kind == TourLegKind.ferry && s.to > s.from) s,
    ];
    var ferryIndex = 0;
    final segs = <(double, DateTime, double, DateTime)>[];
    var km = 0.0;
    var reached = 0.0; // weiter vorn als hier kann keine Zeit mehr beginnen
    for (final s in eta.steps) {
      if (s.type == EtaEventType.ferry) {
        if (ferryIndex < ferries.length && s.start != null && s.end != null) {
          final f = ferries[ferryIndex];
          segs.add((f.from, s.start!, f.to, s.end!));
          reached = f.to;
        }
        ferryIndex++;
        continue;
      }
      if (s.type != EtaEventType.drive) continue;
      final d = s.distanceKm ?? 0;
      if (s.start != null && s.end != null) {
        final m0 = math.max(metersForPlanKm(path, km, totalKm), reached);
        final m1 = math.max(metersForPlanKm(path, km + d, totalKm), m0);
        segs.add((m0, s.start!, m1, s.end!));
        reached = m1;
      }
      km += d;
    }
    return segs.isEmpty ? null : TourClock._(segs);
  }

  final List<(double, DateTime, double, DateTime)> _segments;

  /// Planzeit an Streckenmeter [meters]. Liegen an derselben Stelle mehrere
  /// Abschnitte (Pause/Ruhe dazwischen), gilt der erste: die Ankunft.
  DateTime at(double meters) {
    for (final (m0, t0, m1, t1) in _segments) {
      if (meters > m1) continue;
      if (meters <= m0) return t0;
      final f = (meters - m0) / (m1 - m0);
      return t0.add(Duration(microseconds: (t1.difference(t0).inMicroseconds * f).round()));
    }
    return _segments.last.$4;
  }

  DateTime get start => _segments.first.$2;
  DateTime get end => _segments.last.$4;
}

/// Weicher Verlauf der Dunkelheit: läuft mit Zeitkonstante [tau] (Sekunden
/// Animationszeit) auf den Zielwert zu – auch über Zeitsprünge an Ruhezeiten
/// kein Umschalten. Deterministisch bei festem Bildtakt.
class DaylightEaser {
  DaylightEaser({this.tau = 1.2});

  final double tau;
  double? _level;

  double update(double target, Duration dt) {
    final s = dt.inMicroseconds / 1e6;
    final l = _level;
    if (l == null || s <= 0) return _level = l ?? target;
    return _level = l + (target - l) * (1 - math.exp(-s / tau));
  }

  void reset() => _level = null;
  double get level => _level ?? 0;
}
