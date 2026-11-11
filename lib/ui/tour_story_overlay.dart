import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../animation/tour_story.dart';

final NumberFormat _int = NumberFormat.decimalPattern('de');

/// „45 MIN“ bzw. „11:00 h“ – genau die geplante Dauer.
String storyDurationLabel(Duration d) {
  final minutes = d.inMinutes;
  if (minutes < 60) return '$minutes MIN';
  final h = minutes ~/ 60;
  final m = minutes % 60;
  return '$h:${m.toString().padLeft(2, '0')} h';
}

/// „06:15“; liegt die Weiterfahrt nicht am Folgetag (z. B. nach der
/// Wochenruhe), mit Wochentag: „Mo 06:15“.
String storyResumeLabel(DateTime resume, DateTime? restStart) {
  final nextDay = restStart == null ||
      DateTime(resume.year, resume.month, resume.day)
              .difference(DateTime(restStart.year, restStart.month, restStart.day))
              .inDays <=
          1;
  return DateFormat(nextDay ? 'HH:mm' : 'EEE HH:mm', 'de').format(resume);
}

/// Ab hier zeigt die Tagesruhe den neuen Tag.
const double storyNextDayFrom = 0.55;

/// „1.247 km“
String storyKmLabel(double km) => '${_int.format(km.round())} km';

/// Ein- und Ausblenden über die Einblendungsdauer: schnell rein, ruhig raus.
double storyFade(double progress) {
  if (progress < 0.12) return progress / 0.12;
  if (progress > 0.82) return ((1 - progress) / 0.18).clamp(0.0, 1.0);
  return 1;
}

/// Abdunklung während der Tagesruhe: Abend → Nacht → Morgen.
double storyNightLevel(double progress) {
  final p = progress.clamp(0.0, 1.0);
  if (p < 0.15) return p / 0.15;
  if (p < storyNextDayFrom - 0.1) return 1;
  if (p < storyNextDayFrom + 0.15) return 1 - (p - (storyNextDayFrom - 0.1)) / 0.25;
  return 0;
}

/// Wie stark die automatische Kamera bei einem Ereignis herauszoomt:
/// an der Grenze etwas, damit das neue Land sichtbar wird; bei der Tagesruhe
/// etwas mehr, als ruhiger Überblick. Auf und ab wie ein Atemzug.
double storyZoomOffset(TourFrame? frame, {TourStoryMode mode = TourStoryMode.cinematic}) {
  final e = frame?.event;
  if (e == null) return 0;
  final bump = math.sin(math.pi * frame!.eventProgress.clamp(0.0, 1.0));
  // Cinematic: die Kamera folgt nur dem LKW – keine Story-Bewegung.
  if (mode == TourStoryMode.cinematic) return 0;
  return switch (e.kind) {
    TourStoryKind.borderCrossing => -0.6 * bump,
    TourStoryKind.dailyRest => -0.8 * bump,
    _ => 0,
  };
}

// ------------------------------------------------- Statusleiste (Cinematic)

/// Länder in Fahrtreihenfolge: Startland, dann jedes neue Land.
List<String> storyCountrySequence(List<TourStoryEvent> events, String? startIso) {
  final borders = events.where((e) => e.kind == TourStoryKind.borderCrossing).toList();
  final first = startIso ?? (borders.isEmpty ? null : borders.first.fromIso);
  return [if (first != null) first, for (final b in borders) b.toIso!];
}

/// Wie viele Grenzen bis [meters] überfahren sind = Index des aktuellen Landes.
int storyCountryIndexAt(List<TourStoryEvent> events, double meters) => events
    .where((e) => e.kind == TourStoryKind.borderCrossing && e.meters <= meters)
    .length;

double _smooth(double x) {
  final t = x.clamp(0.0, 1.0);
  return t * t * (3 - 2 * t);
}

/// Kompakte feste Fahrleiste (Cinematic): Zeile 1 Titel und Länderfolge,
/// Zeile 2 Kilometer und Fortschritt. Keine Story-Texte; ein Grenzübertritt
/// zeigt sich nur am Wechsel der hervorgehobenen Flagge. Lage und Höhe
/// ändern sich nie.
class TourStoryHud extends StatelessWidget {
  const TourStoryHud({
    super.key,
    required this.title,
    required this.km,
    required this.progress,
    required this.frame,
    required this.events,
    this.startIso,
  });

  final String title;
  final String km;
  final double progress;
  final TourFrame frame;
  final List<TourStoryEvent> events;
  final String? startIso;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final countries = storyCountrySequence(events, startIso);
    final current = storyCountryIndexAt(events, frame.meters);
    final e = frame.event;
    // Beim Grenzübertritt wandert die Hervorhebung sanft zum neuen Land.
    final shift = e?.kind == TourStoryKind.borderCrossing ? _smooth(frame.eventProgress / 0.25) : 1.0;
    double emphasis(int i) {
      if (i == current) return shift;
      if (i == current - 1) return 1 - shift;
      return 0;
    }

    return Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560),
        child: Card(
          key: const Key('tour-hud'),
          elevation: 3,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 8, 14, 9),
            child: LayoutBuilder(builder: (context, c) {
              return Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  SizedBox(
                    height: 22,
                    child: Row(children: [
                      ConstrainedBox(
                        constraints: BoxConstraints(maxWidth: c.maxWidth * 0.5),
                        child: Text(title,
                            style: theme.textTheme.titleSmall,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis),
                      ),
                      const SizedBox(width: 12),
                      // Länderfolge: eine Zeile, bei vielen Ländern verkleinert.
                      Expanded(
                        child: FittedBox(
                          fit: BoxFit.scaleDown,
                          alignment: Alignment.centerRight,
                          child: Row(children: [
                            for (var i = 0; i < countries.length; i++) ...[
                              if (i > 0) const SizedBox(width: 6),
                              _stripFlag(context, i, countries[i], current, emphasis(i)),
                            ],
                          ]),
                        ),
                      ),
                    ]),
                  ),
                  const SizedBox(height: 4),
                  SizedBox(
                    height: 20,
                    child: Row(children: [
                      Text('🚛 $km', key: const Key('tour-km'), style: theme.textTheme.bodyMedium),
                      const SizedBox(width: 12),
                      Expanded(
                        child: LinearProgressIndicator(
                          key: const Key('tour-progress'),
                          value: progress,
                          minHeight: 4,
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                    ]),
                  ),
                ],
              );
            }),
          ),
        ),
      ),
    );
  }

  /// Eine Flagge der Leiste. Deckkraft direkt im Zeichnen (Bild- und
  /// Rahmenfarbe mit Alpha), runde Ecken im selben Zeichenschritt – bewusst
  /// KEIN Opacity- oder ClipRRect-Widget je Flagge: Jedes davon wird über
  /// der Karte zur eigenen Compositing-Ebene mit Offscreen-Fläche (gemessen
  /// in Chrome ≈ 30–35 MB GPU-Speicher je Flagge, bei 9 Ländern ≈ 370 MB
  /// über die ganze Tour; zusammen mit der Dauerlast beendete das die Seite
  /// auf dem iPhone). Gleiche Optik: Rahmen 1,5 + Abstand 1,5, Flagge 13 hoch.
  Widget _stripFlag(BuildContext context, int i, String iso, int current, double emphasis) {
    final passed = i < current;
    final base = passed ? 0.5 : 0.28; // durchfahren dezent, kommend zurückhaltend
    final opacity = base + (1 - base) * emphasis;
    const height = 13.0;
    return Container(
      key: Key('strip-$i-$iso'),
      padding: const EdgeInsets.all(1.5),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(3),
        border: Border.all(
          width: 1.5,
          color: Theme.of(context).colorScheme.primary.withValues(alpha: emphasis * opacity),
        ),
      ),
      child: Container(
        width: height * 1.5,
        height: height,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(3),
          image: DecorationImage(
            image: AssetImage('assets/flags/${iso.toLowerCase()}.png'),
            fit: BoxFit.cover,
            opacity: opacity,
          ),
        ),
      ),
    );
  }
}

/// Flagge als Bild (nicht als Emoji – Windows zeigt dort nur Buchstaben).
class CountryFlag extends StatelessWidget {
  const CountryFlag(this.iso, {super.key, this.height = 20});

  final String iso;
  final double height;

  @override
  Widget build(BuildContext context) {
    final width = height * 1.5;
    return ClipRRect(
      borderRadius: BorderRadius.circular(3),
      child: DecoratedBox(
        decoration: BoxDecoration(border: Border.all(color: Colors.black12)),
        child: Image.asset(
          'assets/flags/${iso.toLowerCase()}.png',
          key: Key('flag-$iso'),
          width: width,
          height: height,
          fit: BoxFit.cover,
          errorBuilder: (context, _, __) => Container(
            width: width,
            height: height,
            color: Colors.grey.shade300,
            alignment: Alignment.center,
            child: Text(iso, style: const TextStyle(fontSize: 10)),
          ),
        ),
      ),
    );
  }
}

/// Die sichtbaren Story-Elemente über der Karte – abhängig nur vom [frame].
class TourStoryOverlay extends StatelessWidget {
  const TourStoryOverlay({
    super.key,
    required this.frame,
    this.mode = TourStoryMode.cinematic,
    this.summary,
    this.fromName,
    this.toName,
    this.countrySequence = const [],
  });

  final TourFrame frame;

  /// Länderfolge der Tour, für die Abschlussdarstellung.
  final List<String> countrySequence;

  /// Cinematic: unterwegs nur kurze Zeichen, Details auf der Abschlusskarte.
  /// Simulation: jedes Ereignis mit vollständiger Karte.
  final TourStoryMode mode;

  /// Für die Abschlusskarte im Cinematic-Modus.
  final TourSummary? summary;
  final String? fromName;
  final String? toName;

  @override
  Widget build(BuildContext context) {
    final e = frame.event;
    if (e == null) return const SizedBox.shrink();
    return mode == TourStoryMode.cinematic
        ? _cinematic(context, e)
        : _simulation(context, e);
  }

  // ---------------------------------------------------------- Cinematic

  /// Während der Fahrt schauen, am Ziel lesen: Unterwegs erscheint auf der
  /// Karte nichts (der Grenzwechsel zeigt sich in der Fahrleiste und kurz an
  /// der Länderfläche). Am Ziel ersetzt die Abschlussdarstellung die Leiste.
  Widget _cinematic(BuildContext context, TourStoryEvent e) {
    if (e.kind != TourStoryKind.arrival) return const SizedBox.shrink();
    final p = frame.eventProgress;
    final fade = p >= 1 ? 1.0 : _smooth(p / 0.2);
    return IgnorePointer(
      child: Align(
        alignment: const Alignment(0, -0.2),
        child: Opacity(
          opacity: fade,
          child: Transform.translate(
            offset: Offset(0, 12 * (1 - fade)),
            child: _summaryCard(context, e),
          ),
        ),
      ),
    );
  }

  /// Abschlussdarstellung: hier wird gelesen – größer, nur Planungsdaten.
  Widget _summaryCard(BuildContext context, TourStoryEvent e) {
    final theme = Theme.of(context);
    final s = summary;
    final body = theme.textTheme.bodyLarge;
    String plural(int n, String one, String many) => '$n ${n == 1 ? one : many}';
    Widget place(String? name, String? iso) => Row(mainAxisSize: MainAxisSize.min, children: [
          if (name != null && name.isNotEmpty)
            Flexible(
                child: Text(name, style: theme.textTheme.titleMedium, overflow: TextOverflow.ellipsis)),
          if (iso != null) ...[const SizedBox(width: 8), CountryFlag(iso, height: 18)],
        ]);
    final time = [
      if (s != null && s.driving > Duration.zero) '${storyDurationLabel(s.driving)} Fahrzeit',
      if (s != null) plural(s.days, 'Fahrtag', 'Fahrtage'),
    ].join(' · ');
    final rests = [
      if (s != null && s.breaks > 0) plural(s.breaks, 'Lenkpause', 'Lenkpausen'),
      if (s != null && s.dailyRests > 0) plural(s.dailyRests, 'Tagesruhe', 'Tagesruhen'),
      if (s != null && s.weeklyRests > 0) plural(s.weeklyRests, 'Wochenruhe', 'Wochenruhen'),
    ].join(' · ');
    final flags = countrySequence;
    return ConstrainedBox(
      key: const Key('story-arrival'),
      constraints: const BoxConstraints(maxWidth: 480),
      child: Card(
        elevation: 8,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(28, 24, 28, 24),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Text('TOUR ABGESCHLOSSEN',
                style: theme.textTheme.labelLarge?.copyWith(
                    letterSpacing: 2,
                    fontWeight: FontWeight.w700,
                    color: theme.colorScheme.primary)),
            if (fromName != null || toName != null || s?.startIso != null) ...[
              const SizedBox(height: 12),
              Wrap(
                alignment: WrapAlignment.center,
                crossAxisAlignment: WrapCrossAlignment.center,
                spacing: 10,
                children: [
                  place(fromName, s?.startIso),
                  Icon(Icons.arrow_forward, size: 18, color: theme.colorScheme.primary),
                  place(toName, s?.endIso),
                ],
              ),
            ],
            const SizedBox(height: 12),
            Text(storyKmLabel(s?.km ?? e.km),
                style: theme.textTheme.displaySmall?.copyWith(fontWeight: FontWeight.w700)),
            if (time.isNotEmpty) ...[const SizedBox(height: 8), Text(time, style: body)],
            if (rests.isNotEmpty) ...[const SizedBox(height: 2), Text(rests, style: body)],
            if (flags.length > 1) ...[
              const SizedBox(height: 16),
              FittedBox(
                key: const Key('arrival-flags'),
                fit: BoxFit.scaleDown,
                child: Row(children: [
                  for (var i = 0; i < flags.length; i++) ...[
                    if (i > 0) const SizedBox(width: 8),
                    CountryFlag(flags[i], height: 16),
                  ],
                ]),
              ),
            ],
          ]),
        ),
      ),
    );
  }

  // --------------------------------------------------------- Simulation

  Widget _simulation(BuildContext context, TourStoryEvent e) {
    final p = frame.eventProgress;
    final double fade;
    if (e.kind == TourStoryKind.arrival && p >= 1) {
      fade = 1.0;
    } else if (e.kind == TourStoryKind.dailyRest && e.resumeAt != null) {
      // Zwei Karten nacheinander: Nacht aus-, neuer Tag einblenden.
      fade = p < storyNextDayFrom
          ? math.min(storyFade(p), ((storyNextDayFrom - p) / 0.08).clamp(0.0, 1.0))
          : math.min(((p - storyNextDayFrom) / 0.08).clamp(0.0, 1.0), storyFade(p));
    } else {
      fade = storyFade(p);
    }
    return IgnorePointer(
      child: Stack(
        children: [
          if (e.kind == TourStoryKind.dailyRest)
            // Nacht: Karte dezent abdunkeln, zum neuen Tag wieder aufhellen.
            Positioned.fill(
              child: ColoredBox(
                  color: const Color(0xFF0B1A3A)
                      .withValues(alpha: 0.30 * storyNightLevel(frame.eventProgress))),
            ),
          Align(
            alignment: e.kind == TourStoryKind.borderCrossing
                ? const Alignment(0, -0.42)
                : const Alignment(0, 0.45),
            child: Opacity(
              opacity: fade,
              child: Transform.translate(
                offset: Offset(0, 12 * (1 - fade)),
                child: _card(context, e),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _card(BuildContext context, TourStoryEvent e) {
    final theme = Theme.of(context);
    final caps = theme.textTheme.labelLarge?.copyWith(
      letterSpacing: 1.4,
      fontWeight: FontWeight.w700,
      color: theme.colorScheme.primary,
    );
    final big = theme.textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w600);
    final body = theme.textTheme.bodyLarge;

    Widget card(List<Widget> children, {Key? key}) => ConstrainedBox(
          key: key,
          constraints: const BoxConstraints(maxWidth: 420),
          child: Card(
            elevation: 6,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 16),
              child: Column(mainAxisSize: MainAxisSize.min, children: children),
            ),
          ),
        );

    switch (e.kind) {
      case TourStoryKind.borderCrossing:
        return card(key: const Key('story-border'), [
          Wrap(
            alignment: WrapAlignment.center,
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: 10,
            runSpacing: 6,
            children: [
              CountryFlag(e.fromIso!),
              Text(e.fromName ?? e.fromIso!, style: body),
              Icon(Icons.arrow_forward, size: 18, color: theme.colorScheme.primary),
              CountryFlag(e.toIso!, height: 24),
              Text((e.toName ?? e.toIso!).toUpperCase(),
                  style: big?.copyWith(letterSpacing: 1.2)),
            ],
          ),
        ]);
      case TourStoryKind.break45:
        return card(key: const Key('story-break'), [
          Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(Icons.local_cafe, size: 20, color: theme.colorScheme.primary),
            const SizedBox(width: 8),
            Text(
              e.duration == null
                  ? 'LENKPAUSE'
                  : 'LENKPAUSE · ${storyDurationLabel(e.duration!)}',
              style: caps,
            ),
          ]),
          const SizedBox(height: 4),
          Text('${storyKmLabel(e.km)} gefahren', style: body),
        ]);
      case TourStoryKind.dailyRest:
        final resume = e.resumeAt;
        // Erst die Nacht, dann der neue Tag – die Fahrt läuft dabei weiter.
        if (resume != null && frame.eventProgress >= storyNextDayFrom) {
          return card(key: const Key('story-next-day'), [
            Row(mainAxisSize: MainAxisSize.min, children: [
              Icon(Icons.wb_sunny_outlined, size: 22, color: Colors.amber.shade800),
              const SizedBox(width: 8),
              Text('TAG ${(e.day ?? 0) + 1}', style: caps),
            ]),
            const SizedBox(height: 4),
            Text('Weiterfahrt ${storyResumeLabel(resume, e.resumeAt?.subtract(e.duration ?? Duration.zero))}',
                style: body),
          ]);
        }
        final label = e.weekly ? 'WOCHENRUHE' : 'TAGESRUHE';
        return card(key: const Key('story-rest'), [
          Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(Icons.bedtime_outlined, size: 22, color: theme.colorScheme.primary),
            const SizedBox(width: 8),
            Text(
              e.duration == null ? label : '$label · ${storyDurationLabel(e.duration!)}',
              style: caps,
            ),
          ]),
          const SizedBox(height: 4),
          Text('Tag ${e.day} · ${storyKmLabel(e.dayKm ?? e.km)}', style: body),
        ]);
      case TourStoryKind.arrival:
        return card(key: const Key('story-arrival'), [
          Icon(Icons.flag, color: theme.colorScheme.primary),
          const SizedBox(height: 6),
          Text('ZIEL ERREICHT', style: caps),
          const SizedBox(height: 4),
          Text(storyKmLabel(e.km), style: big),
        ]);
    }
  }
}
