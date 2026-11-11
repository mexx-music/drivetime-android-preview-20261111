import 'dart:math' as math;

import '../logic/eta_calculator.dart';
import 'country_borders.dart';
import 'tour_motion.dart';
import 'tour_path.dart';

/// Was auf der Tour passiert. Erweiterbar (später z. B. Fähre, Stopps).
enum TourStoryKind { borderCrossing, break45, dailyRest, arrival }

/// Ein Ereignis der Tour-Story: „bei Streckenmeter X passiert Z“.
///
/// Reine Daten – wie das Ereignis aussieht, entscheidet die Darstellung.
/// Alle Werte stammen aus der DriveTime-Planung (ETA) bzw. aus der
/// Routengeometrie; nichts wird hier neu geplant.
class TourStoryEvent {
  const TourStoryEvent({
    required this.kind,
    required this.meters,
    required this.km,
    this.duration,
    this.resumeAt,
    this.day,
    this.dayKm,
    this.weekly = false,
    this.fromIso,
    this.toIso,
    this.fromName,
    this.toName,
  });

  final TourStoryKind kind;

  /// Stelle entlang der animierten Linie.
  final double meters;

  /// Gefahrene Kilometer laut DriveTime-Planung bis hierher.
  final double km;

  /// Dauer laut Planung (Pause, Ruhezeit).
  final Duration? duration;

  /// Ende der Ruhezeit = Weiterfahrt laut Planung.
  final DateTime? resumeAt;

  /// Fahrtag, der mit dieser Ruhezeit endet (1, 2, …).
  final int? day;

  /// Kilometer dieses Fahrtags.
  final double? dayKm;

  /// Wochenruhe statt Tagesruhe.
  final bool weekly;

  final String? fromIso;
  final String? toIso;
  final String? fromName;
  final String? toName;

  @override
  String toString() => 'TourStoryEvent($kind @ ${km.toStringAsFixed(1)} km)';
}

/// Gesamtkilometer der Planung: Summe der Fahrabschnitte.
double etaDriveKm(EtaResult eta) => eta.steps
    .where((s) => s.type == EtaEventType.drive)
    .fold(0.0, (sum, s) => sum + (s.distanceKm ?? 0));

/// Planungs-Kilometer → Stelle auf der Linie. Die Planung rechnet mit den
/// Kilometern der Route, die Linie mit ihrer Geometrie; beides deckt sich bis
/// auf wenige Promille und wird anteilig über die Straßenstrecke zugeordnet.
/// Seestrecken zählen dabei nicht.
double metersForPlanKm(TourPath path, double km, double totalKm) {
  if (totalKm <= 0) return 0;
  final fraction = (km / totalKm).clamp(0.0, 1.0);
  return path.metersAtRoad(fraction * path.roadMeters);
}

/// Planungs-Kilometer an einer Stelle der Linie (Umkehrung, für Anzeigen).
double planKmAt(TourPath path, double meters, double totalKm) {
  if (path.roadMeters <= 0) return 0;
  return path.at(meters).roadMeters / path.roadMeters * totalKm;
}

/// Lenkpausen, Ruhezeiten und Ziel genau so, wie die ETA sie geplant hat.
List<TourStoryEvent> storyFromEta(EtaResult eta, TourPath path) {
  final totalKm = etaDriveKm(eta);
  final out = <TourStoryEvent>[];
  var km = 0.0;
  var dayStartKm = 0.0;
  var day = 1;
  for (final s in eta.steps) {
    switch (s.type) {
      case EtaEventType.drive:
        km += s.distanceKm ?? 0;
      case EtaEventType.breakTime:
        out.add(TourStoryEvent(
          kind: TourStoryKind.break45,
          meters: metersForPlanKm(path, km, totalKm),
          km: km,
          duration: s.duration,
        ));
      case EtaEventType.dailyRest:
      case EtaEventType.weeklyRest:
        out.add(TourStoryEvent(
          kind: TourStoryKind.dailyRest,
          meters: metersForPlanKm(path, km, totalKm),
          km: km,
          duration: s.duration,
          resumeAt: s.end,
          day: day,
          dayKm: km - dayStartKm,
          weekly: s.type == EtaEventType.weeklyRest,
        ));
        day++;
        dayStartKm = km;
      case EtaEventType.destination:
        out.add(TourStoryEvent(
          kind: TourStoryKind.arrival,
          meters: path.totalMeters,
          km: totalKm,
          day: day,
        ));
      default:
        break;
    }
  }
  return out;
}

/// Grenzübertritte als Story-Ereignisse.
List<TourStoryEvent> storyFromBorders(
  List<BorderCrossing> crossings,
  CountryIndex countries,
  TourPath path,
  double totalKm,
) =>
    [
      for (final c in crossings)
        TourStoryEvent(
          kind: TourStoryKind.borderCrossing,
          meters: c.meters,
          km: planKmAt(path, c.meters, totalKm),
          fromIso: c.fromIso,
          toIso: c.toIso,
          fromName: countries.byIso(c.fromIso)?.name ?? c.fromIso,
          toName: countries.byIso(c.toIso)?.name ?? c.toIso,
        ),
    ];

/// Alle Ereignisse in Fahrtreihenfolge; an derselben Stelle zuerst die
/// Grenze, dann Pause/Ruhe, zuletzt das Ziel.
List<TourStoryEvent> sortStory(Iterable<TourStoryEvent> events) {
  final list = events.toList();
  final indexed = [for (var i = 0; i < list.length; i++) (i, list[i])];
  indexed.sort((a, b) {
    final c = a.$2.meters.compareTo(b.$2.meters);
    if (c != 0) return c;
    final k = a.$2.kind.index.compareTo(b.$2.kind.index);
    return k != 0 ? k : a.$1.compareTo(b.$1);
  });
  return [for (final e in indexed) e.$2];
}

// ------------------------------------------------------- Zusammenfassung

/// Was die Abschlusskarte zeigt – gezählt aus Planung und Story, nichts
/// geschätzt. Fehlt eine Angabe, bleibt sie weg.
class TourSummary {
  const TourSummary({
    required this.km,
    required this.driving,
    required this.days,
    required this.breaks,
    required this.dailyRests,
    required this.weeklyRests,
    this.startIso,
    this.endIso,
  });

  /// [startIso]/[endIso]: Land an Start und Ziel (offline, aus den Grenzen).
  factory TourSummary.from(EtaResult eta, List<TourStoryEvent> story,
      {String? startIso, String? endIso}) {
    final driveSteps = eta.steps.where((s) => s.type == EtaEventType.drive);
    final fromSteps = driveSteps.fold(Duration.zero, (sum, s) => sum + s.duration);
    final minutes = eta.summary?.drivingMinutes;
    final rests = story.where((e) => e.kind == TourStoryKind.dailyRest);
    return TourSummary(
      km: etaDriveKm(eta),
      driving: minutes != null && minutes > 0 ? Duration(minutes: minutes) : fromSteps,
      days: rests.length + 1,
      breaks: story.where((e) => e.kind == TourStoryKind.break45).length,
      dailyRests: rests.where((e) => !e.weekly).length,
      weeklyRests: rests.where((e) => e.weekly).length,
      startIso: startIso,
      endIso: endIso,
    );
  }

  final double km;

  /// Reine Lenkzeit laut Planung; Duration.zero = unbekannt.
  final Duration driving;
  final int days;
  final int breaks;
  final int dailyRests;
  final int weeklyRests;
  final String? startIso;
  final String? endIso;
}

// ------------------------------------------------------------- Zeitleiste

/// Wie die Ereignisse abgespielt werden – die Ereignisse selbst sind gleich.
enum TourStoryMode {
  /// Erzählt die Tour: das Fahrzeug fährt durch, Ereignisse erscheinen als
  /// Einblendung. Nur am Ziel endet die Bewegung. Standard der Animation.
  cinematic,

  /// Bildet die Planung nach: an Pause, Ruhe und Grenze steht das Fahrzeug.
  simulation,
}

/// Wie lange ein Ereignis in der Animation dauert (Story-Zeit bei 1×).
/// [hold]: das Fahrzeug steht; [show]: die Einblendung ist sichtbar.
({Duration hold, Duration show}) storyTiming(TourStoryKind kind,
    {TourStoryMode mode = TourStoryMode.cinematic}) {
  const zero = Duration.zero;
  if (mode == TourStoryMode.cinematic) {
    // Während der Fahrt schauen, am Ziel lesen: unterwegs zeigt sich nur der
    // Länderwechsel (Flagge in der Leiste, kurz die Länderfläche). Pausen und
    // Ruhezeiten bleiben in den Daten und werden erst am Ziel zusammengefasst.
    // Die Abschlussdarstellung darf stehen bleiben.
    return switch (kind) {
      TourStoryKind.borderCrossing => (hold: zero, show: const Duration(milliseconds: 1600)),
      TourStoryKind.break45 => (hold: zero, show: zero),
      TourStoryKind.dailyRest => (hold: zero, show: zero),
      TourStoryKind.arrival =>
        (hold: const Duration(milliseconds: 5000), show: const Duration(milliseconds: 5000)),
    };
  }
  return switch (kind) {
    TourStoryKind.borderCrossing =>
      (hold: const Duration(milliseconds: 1200), show: const Duration(milliseconds: 3200)),
    TourStoryKind.break45 =>
      (hold: const Duration(milliseconds: 2800), show: const Duration(milliseconds: 2800)),
    TourStoryKind.dailyRest =>
      (hold: const Duration(milliseconds: 4500), show: const Duration(milliseconds: 4500)),
    TourStoryKind.arrival =>
      (hold: const Duration(milliseconds: 3000), show: const Duration(milliseconds: 3000)),
  };
}

/// Ein Bild der Story: wo das Fahrzeug ist und welches Ereignis gerade läuft.
class TourFrame {
  const TourFrame({
    required this.meters,
    this.event,
    this.eventProgress = 0,
    this.holding = false,
  });

  final double meters;
  final TourStoryEvent? event;

  /// 0..1 über die Einblendungsdauer des Ereignisses.
  final double eventProgress;

  /// Fahrzeug steht gerade für das Ereignis.
  final bool holding;
}

/// Fügt die Ereignisse in die Fahrt ein, ohne die Fahrzeugbewegung selbst zu
/// ändern: die Fahrt läuft wie ohne Story ([tourEase] über [drive]).
/// Im [TourStoryMode.cinematic] fährt das Fahrzeug durch die Ereignisse
/// hindurch und hält nur am Ziel; im [TourStoryMode.simulation] steht es an
/// jedem Ereignis kurz ([storyTiming]). Ohne Ereignisse ist die Zeitleiste
/// genau die bisherige Animation.
class TourTimeline {
  TourTimeline({
    required this.path,
    required this.drive,
    Iterable<TourStoryEvent> events = const [],
    this.mode = TourStoryMode.cinematic,
    this.motion,
  }) : events = sortStory(events) {
    var story = Duration.zero;
    var lastDrive = 0.0;
    for (final e in this.events) {
      final td = _driveTimeAt(e.meters);
      story += _fromSeconds(math.max(0, td - lastDrive));
      lastDrive = math.max(lastDrive, td);
      final t = storyTiming(e.kind, mode: mode);
      _beats.add((e, story, lastDrive, t.hold, t.show));
      story += t.hold;
    }
    total = story + _fromSeconds(math.max(0, _seconds(drive) - lastDrive));
  }

  final TourPath path;

  /// Reine Fahrzeit der Animation (ohne Haltezeiten).
  final Duration drive;

  /// Cinematic: ruhiges Filmtempo statt [tourEase] (null = wie bisher).
  final TourMotion? motion;
  final List<TourStoryEvent> events;
  final TourStoryMode mode;

  /// Gesamtdauer inklusive Haltezeiten.
  late final Duration total;

  /// Story-Zeit, zu der das Fahrzeug das Ziel erreicht (Beginn des
  /// Ankunfts-Ereignisses; ohne Ereignis: Ende der Fahrt).
  Duration get arrivalAt {
    for (final (e, start, _, _, _) in _beats) {
      if (e.kind == TourStoryKind.arrival) return start;
    }
    return total;
  }

  /// (Ereignis, Story-Beginn, Fahrzeit-Stand, Halten, Einblendung)
  final List<(TourStoryEvent, Duration, double, Duration, Duration)> _beats = [];

  static double _seconds(Duration d) => d.inMicroseconds / 1e6;
  static Duration _fromSeconds(double s) => Duration(microseconds: (s * 1e6).round());

  /// Fahrzeit (s), zu der das Fahrzeug [meters] erreicht – Umkehrung von
  /// [tourEase] per Halbierung.
  double _driveTimeAt(double meters) {
    final mo = motion;
    if (mo != null) return mo.secondsAt(meters);
    final total = path.totalMeters;
    if (total <= 0) return 0;
    final target = (meters / total).clamp(0.0, 1.0);
    var lo = 0.0, hi = 1.0;
    for (var i = 0; i < 40; i++) {
      final mid = (lo + hi) / 2;
      if (tourEase(mid) < target) {
        lo = mid;
      } else {
        hi = mid;
      }
    }
    return hi * _seconds(drive);
  }

  /// Stand zur Story-Zeit [t].
  TourFrame frameAt(Duration t) {
    final total = path.totalMeters;
    final driveS = _seconds(drive);
    var holdBefore = Duration.zero;
    var passed = 0.0; // nie hinter ein schon erreichtes Ereignis zurück
    TourStoryEvent? active;
    var activeProgress = 0.0;
    var holding = false;
    double? heldAt;

    for (final (e, start, _, hold, show) in _beats) {
      if (t < start) break;
      if (t < start + show || (e.kind == TourStoryKind.arrival && t >= this.total)) {
        active = e;
        activeProgress = show == Duration.zero
            ? 1
            : ((t - start).inMicroseconds / show.inMicroseconds).clamp(0.0, 1.0);
      }
      if (t < start + hold) {
        holding = true;
        heldAt = e.meters;
        break;
      }
      holdBefore += hold;
      passed = math.max(passed, e.meters);
    }
    final driveT = _seconds(t - holdBefore);
    final mo = motion;
    final meters = heldAt ??
        math.max(
            passed,
            mo != null
                ? mo.metersAt(driveT)
                : tourEase(driveS <= 0 ? 1 : (driveT / driveS).clamp(0.0, 1.0)) * total);
    if (t >= this.total) {
      final arrival = events.where((e) => e.kind == TourStoryKind.arrival);
      return TourFrame(
        meters: total,
        event: arrival.isEmpty ? null : arrival.last,
        eventProgress: 1,
      );
    }
    return TourFrame(
      meters: meters,
      event: active,
      eventProgress: activeProgress,
      holding: holding,
    );
  }
}
