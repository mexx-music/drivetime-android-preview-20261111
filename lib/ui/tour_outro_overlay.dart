import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../animation/country_borders.dart';
import '../animation/tour_outro.dart';
import '../animation/tour_path.dart';
import '../animation/tour_story.dart';
import 'tour_story_overlay.dart' show CountryFlag, storyCountrySequence;

/// Daten des Finales aus der fertigen Tour: Länder aus den Grenzübertritten
/// der Story in Fahrtreihenfolge (nicht dedupliziert), Kilometer und
/// Fahrtage aus der Planung, Fähren aus den Fährabschnitten der Linie.
OutroData buildOutroData({
  required TourPath path,
  required List<TourStoryEvent> events,
  CountryIndex? countries,
  TourSummary? summary,
  double? planKm,
  String? fromName,
  String? toName,
}) {
  final startIso = summary?.startIso ?? countries?.countryAt(path.start);
  final sequence = storyCountrySequence(events, startIso);
  return OutroData(
    from: fromName ?? '',
    to: toName ?? '',
    km: planKm ?? path.roadMeters / 1000,
    days: summary?.days,
    countries: [for (final iso in sequence) OutroCountry(iso, countries?.byIso(iso)?.name ?? iso)],
    ferries: ferryCount(path),
  );
}

/// EXPERIMENT – Einblendungen des Cinematic-Outros über der 2.5D-Karte.
///
/// Rein aus [data] und der Outro-Zeit [t] (Sekunden ab Ankunft) – keine
/// eigenen Animationen, keine Uhr. So ergibt dieselbe Zeit immer dasselbe
/// Bild, auch Bild für Bild im späteren Videoexport. Der Truck selbst ist
/// Teil der Karte; hier liegen nur Text, Länder und Signatur.
class TourOutroOverlay extends StatelessWidget {
  const TourOutroOverlay(
      {super.key, required this.data, required this.timeline, required this.t, this.heroPhoto, this.heroCutout});

  /// Test/Export: freigestellter Hero-Lkw in derselben Perspektive wie das
  /// Modell. Blendet deckungsgleich über das Modell und wird dann langsam
  /// größer (die Kamera „rückt näher“). null = nur Modell.
  final String? heroCutout;

  /// Test/Export: echtes Foto des Lkw, blendet nach dem Licht über das
  /// Modell (null = nur Modell).
  final String? heroPhoto;

  final OutroData data;
  final OutroTimeline timeline;
  final double t;

  static const accent = Color(0xFFDCEB4B);
  static const _ink = Color(0xFFF4F6F1);
  static final _num = NumberFormat('#,##0', 'de');

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, box) {
      final w = box.maxWidth, h = box.maxHeight;
      final portrait = w < h;
      final dim = timeline.dim(t);
      final side = portrait ? 0.07 * w : 0.05 * w;
      final colW = portrait ? 0.52 * w : math.min(0.36 * w, 460.0);
      // Größen an der kürzeren Seite ausrichten – lesbar auf 9:16 wie Desktop.
      final unit = math.min(w, h * 0.62);

      final titleTop = portrait ? 0.075 * h : 0.08 * h;
      final listTop = portrait ? 0.25 * h : 0.30 * h;
      final listBottom = portrait ? 0.64 * h : 0.70 * h;
      final statsTop = portrait ? 0.70 * h : 0.76 * h;

      final photo = heroPhoto == null ? 0.0 : timeline.photo(t);
      final cut = heroCutout == null ? 0.0 : timeline.photo(t);
      // Größe/Ort: zuerst genau über dem Modell, dann größer nach rechts unten.
      final comp = outroComposition(portrait: portrait);
      final grow = heroCutout == null ? 0.0 : (((t - timeline.photoReveal - 0.6) / 2.6).clamp(0.0, 1.0));
      final g = grow * grow * (3 - 2 * grow);
      final cw = (0.30 + 0.12 * g) * (portrait ? w : math.min(w, h * 0.9));
      final right = (comp.x + 0.20 + 0.10 * g) * w;
      final bottom = (comp.y + 0.04 + 0.04 * g) * h;
      return IgnorePointer(
        child: Stack(children: [
          if (heroPhoto != null) // früh laden, damit es bereitsteht
            Positioned.fill(
              child: Opacity(
                opacity: photo,
                child: ClipRect(
                  child: Transform.scale(
                    // Ganz langsamer Zoom – das Foto lebt.
                    scale: 1.0 +
                        0.05 *
                            ((t - timeline.photoReveal) / math.max(1, timeline.end - timeline.photoReveal))
                                .clamp(0.0, 1.0),
                    child: Image.network(heroPhoto!, fit: BoxFit.cover, alignment: Alignment.center),
                  ),
                ),
              ),
            ),
          // Ruhige Abdunklung für die Lesbarkeit: links bzw. oben/unten.
          Positioned.fill(
            child: Opacity(
              opacity: dim,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: portrait
                      ? const LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          colors: [Color(0xE6081510), Color(0x66081510), Color(0x22081510), Color(0xF2050C09)],
                          stops: [0, 0.3, 0.62, 0.86],
                        )
                      : const LinearGradient(
                          begin: Alignment.centerLeft,
                          end: Alignment.centerRight,
                          colors: [Color(0xEB081510), Color(0x99081510), Color(0x00081510)],
                          stops: [0, 0.38, 0.62],
                        ),
                ),
              ),
            ),
          ),
          Positioned(left: side, top: titleTop, width: portrait ? w - 2 * side : colW, child: _title(unit)),
          if (data.countries.isNotEmpty)
            Positioned(
              left: side,
              top: listTop,
              width: colW,
              height: listBottom - listTop,
              child: _countries(listBottom - listTop, colW, unit, h),
            ),
          if (heroCutout != null) // über der Länderliste (deren Zahlen nicht über dem Lkw)
            Positioned(
              left: right - cw,
              top: bottom - cw,
              width: cw,
              height: cw,
              child: Opacity(
                opacity: cut,
                child: Image.network(heroCutout!, fit: BoxFit.contain, alignment: Alignment.bottomRight),
              ),
            ),
          Positioned(
            left: side,
            top: statsTop,
            width: portrait ? w - 2 * side : colW,
            child: _stats(unit),
          ),
          Positioned(right: side, bottom: 0.025 * h, child: _signature(unit)),
        ]),
      );
    });
  }

  Widget _fade(double v, Widget child, {double dx = 0, double dy = 0}) => Opacity(
        opacity: v.clamp(0.0, 1.0),
        child: Transform.translate(offset: Offset(dx * (1 - v), dy * (1 - v)), child: child),
      );

  Widget _title(double unit) {
    final v = timeline.title(t);
    return _fade(
      v,
      dy: 10,
      Column(
        key: const Key('outro-title'),
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('TOUR',
                  style: TextStyle(color: accent, fontSize: unit * 0.085, fontWeight: FontWeight.w900, height: 0.95)),
              Text('ABGESCHLOSSEN',
                  style: TextStyle(
                      color: _ink,
                      fontSize: unit * 0.085,
                      fontWeight: FontWeight.w900,
                      height: 0.95,
                      letterSpacing: -0.5)),
            ]),
          ),
          SizedBox(height: unit * 0.02),
          Text.rich(
            TextSpan(children: [
              const TextSpan(text: 'Angekommen in '),
              TextSpan(text: data.to, style: const TextStyle(fontWeight: FontWeight.w800)),
            ]),
            style: TextStyle(color: _ink.withValues(alpha: 0.85), fontSize: unit * 0.04),
          ),
        ],
      ),
    );
  }

  /// Einspaltig, solange jede Zeile mindestens 18 Punkte hoch sein kann;
  /// sonst zwei Spalten. Schrift wächst mit der Zeilenhöhe, nie unter 11.
  static ({int columns, int rows, double rowHeight, double font}) countryLayout(
      int n, double height, double screenHeight) {
    final cap = math.min(48.0, screenHeight * 0.058);
    var columns = 1;
    var rows = n;
    var row = math.min(cap, height / math.max(1, n));
    if (row < 18 && n > 1) {
      columns = 2;
      rows = (n / 2).ceil();
      row = math.min(cap, height / rows);
    }
    return (columns: columns, rows: rows, rowHeight: row, font: (row * 0.44).clamp(11.0, 20.0));
  }

  Widget _countries(double height, double width, double unit, double screenHeight) {
    final n = data.countries.length;
    final lay = countryLayout(n, height - unit * 0.07, screenHeight);
    final label = timeline.country(0, t);
    final colWidth = width / lay.columns;
    return Stack(children: [
      _fade(
        label,
        FittedBox(
          fit: BoxFit.scaleDown,
          alignment: Alignment.centerLeft,
          child: Text('${data.distinctCountries} ${data.distinctCountries == 1 ? 'LAND' : 'LÄNDER'} · IN REIHENFOLGE',
              style: TextStyle(
                  color: _ink.withValues(alpha: 0.7),
                  fontSize: unit * 0.028,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 2.4)),
        ),
      ),
      for (var i = 0; i < n; i++)
        Positioned(
          left: (i ~/ lay.rows) * colWidth,
          top: unit * 0.07 + (i % lay.rows) * lay.rowHeight,
          width: colWidth - 8,
          height: lay.rowHeight,
          child: _fade(timeline.country(i, t), dx: -14, _countryRow(i, lay.font, lay.rowHeight)),
        ),
    ]);
  }

  Widget _countryRow(int i, double font, double row) {
    final c = data.countries[i];
    return DecoratedBox(
      key: Key('outro-country-$i'),
      decoration: BoxDecoration(border: Border(bottom: BorderSide(color: _ink.withValues(alpha: 0.12)))),
      child: Row(children: [
        CountryFlag(c.iso, height: font * 0.95),
        SizedBox(width: font * 0.7),
        Expanded(
          child: Text(c.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: _ink, fontSize: font, fontWeight: FontWeight.w600)),
        ),
        Text((i + 1).toString().padLeft(2, '0'),
            style: TextStyle(color: _ink.withValues(alpha: 0.35), fontSize: font * 0.7, fontWeight: FontWeight.w600)),
      ]),
    );
  }

  Widget _stats(double unit) {
    final v = timeline.stats(t);
    final big = unit * 0.085;
    Widget metric(String key, String value, String label) => Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(value,
                key: Key('outro-$key'),
                style: TextStyle(color: _ink, fontSize: big, fontWeight: FontWeight.w900, height: 1)),
            SizedBox(height: unit * 0.012),
            Text(label,
                style: TextStyle(
                    color: _ink.withValues(alpha: 0.65),
                    fontSize: unit * 0.026,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 1.8)),
          ],
        );
    final routeStyle = TextStyle(color: _ink, fontSize: unit * 0.045, fontWeight: FontWeight.w900, letterSpacing: 2);
    return _fade(
      v,
      dy: 12,
      Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(key: const Key('outro-route'), children: [
          Flexible(
              child: Text(data.from.toUpperCase(), maxLines: 1, overflow: TextOverflow.ellipsis, style: routeStyle)),
          Expanded(
            child: Padding(
              padding: EdgeInsets.symmetric(horizontal: unit * 0.03),
              child: Align(
                alignment: Alignment.centerLeft,
                child: FractionallySizedBox(
                  widthFactor: v.clamp(0.0, 1.0),
                  child: Container(height: 2, color: accent),
                ),
              ),
            ),
          ),
          Flexible(child: Text(data.to.toUpperCase(), maxLines: 1, overflow: TextOverflow.ellipsis, style: routeStyle)),
        ]),
        SizedBox(height: unit * 0.035),
        FittedBox(
          fit: BoxFit.scaleDown,
          alignment: Alignment.centerLeft,
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            for (final (i, m) in <Widget>[
              metric('km', _num.format(data.km.round()), 'KILOMETER'),
              if (data.days != null) metric('days', '${data.days}', data.days == 1 ? 'FAHRTAG' : 'FAHRTAGE'),
              if (data.countries.isNotEmpty)
                metric('countries', '${data.distinctCountries}', data.distinctCountries == 1 ? 'LAND' : 'LÄNDER'),
              if (data.ferries > 0) metric('ferries', '${data.ferries}', data.ferries == 1 ? 'FÄHRE' : 'FÄHREN'),
            ].indexed)
              Padding(padding: EdgeInsets.only(left: i == 0 ? 0 : unit * 0.08), child: m),
          ]),
        ),
      ]),
    );
  }

  Widget _signature(double unit) {
    final v = timeline.logo(t);
    final s = unit * 0.034;
    return _fade(
      v,
      Row(key: const Key('outro-signature'), mainAxisSize: MainAxisSize.min, children: [
        Text('Created with ', style: TextStyle(color: _ink.withValues(alpha: 0.6), fontSize: s * 0.8)),
        Container(
          width: s * 1.25,
          height: s * 1.25,
          alignment: Alignment.center,
          decoration: BoxDecoration(color: accent, borderRadius: BorderRadius.circular(s * 0.3)),
          child: Text('D',
              style: TextStyle(color: const Color(0xFF0A1A12), fontSize: s * 0.8, fontWeight: FontWeight.w900)),
        ),
        SizedBox(width: s * 0.35),
        Text('DriveTime', style: TextStyle(color: _ink, fontSize: s, fontWeight: FontWeight.w800)),
      ]),
    );
  }
}
