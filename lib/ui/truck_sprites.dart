import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../animation/truck_projection.dart';
import 'sprite_canvas.dart';
import 'sprite_canvas_browser.dart';

/// Wie das Fahrzeug in der geneigten (2.5D) Karte gezeigt wird.
enum TruckView {
  /// Von oben, flach auf der Karte: dreht und neigt sich mit der Karte und
  /// liegt dadurch perspektivisch richtig auf der Straße.
  top,

  /// Schräg von hinten (Heck), aufrecht zum Betrachter – „Verfolgerkamera“.
  rear,

  /// Seitlich, wie in 2D (bisheriges Symbol).
  side,

  /// 3/4 von oben, immer die linke Aufliegerseite sichtbar.
  threeQuarterLeft,

  /// 3/4 von oben, immer die rechte Aufliegerseite sichtbar.
  threeQuarterRight,

  /// 3/4 von oben, Seite automatisch nach Kurvenrichtung (mit Hysterese).
  threeQuarterAuto,

  /// Gekoppelt: Zugmaschine exakt auf der Route, Auflieger knickt nach.
  articulated,
}

/// Farben – neutral, ohne Marke. Später austauschbar (Fahrzeugtyp, Firma).
const _trailer = Color(0xFFF5F7FA);
const _trailerEdge = Color(0xFF90A4AE);
const _shadow = Color(0x55000000);

Future<Uint8List> _png(Size size, void Function(SpriteCanvas c) paint) => renderSpriteBytes(size, paint);

/// Statische Symbole (einmal je Tour): immer über den Flutter-Canvas.
Future<Uint8List> _pngFlutter(Size size, void Function(Canvas c) paint) =>
    _renderFlutter(size, (c) => paint((c as FlutterSpriteCanvas).c), Zone.current[_rawSpriteKey] as _RawSprite?);

/// Zeichnet ein Sprite und liefert es als PNG – oder, innerhalb von
/// [asSpriteBitmap], als rohe RGBA-Pixel (gleiche Pixel, ohne PNG-Umweg).
/// Mit `browser: true` zeichnet im Web der Browser-Canvas statt Flutter
/// (kein `Picture.toImage()`, das je Bild eine WebGL-Textur zurücklässt).
Future<Uint8List> renderSpriteBytes(Size size, void Function(SpriteCanvas c) paint) async {
  final raw = Zone.current[_rawSpriteKey] as _RawSprite?;
  if (raw != null && raw.browser) {
    final b = renderSpriteBrowser(size, paint);
    if (b != null) {
      raw.width = b.width;
      raw.height = b.height;
      return b.rgba;
    }
  }
  return _renderFlutter(size, paint, raw);
}

Future<Uint8List> _renderFlutter(Size size, void Function(SpriteCanvas c) paint, _RawSprite? raw) async {
  final recorder = ui.PictureRecorder();
  paint(FlutterSpriteCanvas(Canvas(recorder)));
  final image =
      await recorder.endRecording().toImage(size.width.toInt(), size.height.toInt());
  final bytes = await image.toByteData(
      format: raw == null ? ui.ImageByteFormat.png : ui.ImageByteFormat.rawStraightRgba);
  if (raw != null) {
    raw.width = image.width;
    raw.height = image.height;
  }
  image.dispose();
  return bytes!.buffer.asUint8List();
}

/// Rohes Sprite für die Karte: RGBA, nicht vormultipliziert.
class SpriteBitmap {
  const SpriteBitmap(this.width, this.height, this.rgba);
  final int width;
  final int height;
  final Uint8List rgba;
}

class _RawSprite {
  _RawSprite({this.browser = false});
  final bool browser;
  int width = 0;
  int height = 0;
}

const _rawSpriteKey = #drivetimeRawSprite;

/// Führt eine der Sprite-Funktionen (z. B. [truckArticulatedPng]) aus und
/// liefert dieselben Pixel roh statt als PNG. Spart das PNG-Kodieren hier
/// und das Dekodieren im Kartenplugin – gemessen über die Hälfte der
/// Rechenzeit während der Tour.
///
/// [browser]: im Web über den Browser-Canvas zeichnen (Live-Vorschau).
Future<SpriteBitmap> asSpriteBitmap(Future<Uint8List> Function() draw, {bool browser = false}) async {
  final raw = _RawSprite(browser: browser);
  final bytes = await runZoned(draw, zoneValues: {_rawSpriteKey: raw});
  return SpriteBitmap(raw.width, raw.height, bytes);
}

/// Sattelzug von oben, Fahrtrichtung nach oben (Norden des Bildes).
/// 72 × 200 Pixel; in der Karte etwa 20 × 56 Punkte groß.
Future<Uint8List> truckTopPng({TruckBranding branding = TruckBranding.neutral}) =>
    _pngFlutter(const Size(72, 200), (c) {
      // weicher Schatten
      c.drawRRect(
        RRect.fromRectAndRadius(const Rect.fromLTWH(10, 14, 54, 180), const Radius.circular(10)),
        Paint()
          ..color = _shadow
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 5),
      );
      // Auflieger
      final trailer = RRect.fromRectAndRadius(
          const Rect.fromLTWH(8, 56, 56, 136), const Radius.circular(6));
      c.drawRRect(trailer, Paint()..color = _trailer);
      c.drawRRect(
          trailer,
          Paint()
            ..color = _trailerEdge
            ..style = PaintingStyle.stroke
            ..strokeWidth = 3);
      // Längsstreifen auf dem Dach des Aufliegers
      c.drawRect(const Rect.fromLTWH(30, 64, 12, 120), Paint()..color = branding.cabRoof.withAlpha(0x22));
      // Zugmaschine
      final cab = RRect.fromRectAndCorners(const Rect.fromLTWH(12, 6, 48, 44),
          topLeft: const Radius.circular(14),
          topRight: const Radius.circular(14),
          bottomLeft: const Radius.circular(4),
          bottomRight: const Radius.circular(4));
      c.drawRRect(cab, Paint()..color = branding.cab);
      // Dach / Windschutz-Andeutung
      c.drawRRect(
          RRect.fromRectAndRadius(const Rect.fromLTWH(18, 18, 36, 24), const Radius.circular(5)),
          Paint()..color = branding.cabRoof);
      c.drawRect(const Rect.fromLTWH(16, 9, 40, 6), Paint()..color = const Color(0xFF90CAF9));
      // Spiegel
      final mirror = Paint()..color = branding.cab;
      c.drawRect(const Rect.fromLTWH(4, 14, 8, 4), mirror);
      c.drawRect(const Rect.fromLTWH(60, 14, 8, 4), mirror);
    });

/// Sattelzug schräg von hinten: Heck des Aufliegers mit Rückleuchten,
/// darüber die Kabine. 120 × 112 Pixel.
Future<Uint8List> truckRearPng({TruckBranding branding = TruckBranding.neutral}) =>
    _pngFlutter(const Size(120, 112), (c) {
      c.drawOval(
        const Rect.fromLTWH(10, 92, 100, 16),
        Paint()
          ..color = _shadow
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 4),
      );
      // Kabine (leicht versetzt dahinter)
      c.drawRRect(
          RRect.fromRectAndRadius(const Rect.fromLTWH(30, 6, 60, 34), const Radius.circular(8)),
          Paint()..color = branding.cab);
      // Auflieger-Seite (Tiefe)
      final side = Path()
        ..moveTo(92, 22)
        ..lineTo(104, 30)
        ..lineTo(104, 92)
        ..lineTo(92, 96)
        ..close();
      c.drawPath(side, Paint()..color = const Color(0xFFCFD8DC));
      // Heck
      final back = RRect.fromRectAndRadius(
          const Rect.fromLTWH(16, 22, 78, 74), const Radius.circular(4));
      c.drawRRect(back, Paint()..color = _trailer);
      c.drawRRect(
          back,
          Paint()
            ..color = _trailerEdge
            ..style = PaintingStyle.stroke
            ..strokeWidth = 3);
      // Türfuge und Verriegelung
      final line = Paint()
        ..color = _trailerEdge
        ..strokeWidth = 2;
      c.drawLine(const Offset(55, 26), const Offset(55, 92), line);
      c.drawLine(const Offset(40, 30), const Offset(40, 88), line);
      c.drawLine(const Offset(70, 30), const Offset(70, 88), line);
      // Rückleuchten und Stoßfänger
      c.drawRect(const Rect.fromLTWH(18, 84, 12, 6), Paint()..color = const Color(0xFFE53935));
      c.drawRect(const Rect.fromLTWH(80, 84, 12, 6), Paint()..color = const Color(0xFFE53935));
      c.drawRect(const Rect.fromLTWH(20, 96, 70, 4), Paint()..color = const Color(0xFF37474F));
      // Räder
      final wheel = Paint()..color = const Color(0xFF263238);
      c.drawRRect(RRect.fromRectAndRadius(const Rect.fromLTWH(20, 98, 18, 8), const Radius.circular(3)), wheel);
      c.drawRRect(RRect.fromRectAndRadius(const Rect.fromLTWH(72, 98, 18, 8), const Radius.circular(3)), wheel);
    });

/// Seitlich wie in 2D: Lieferwagen-Symbol auf weißem Kreis.
Future<Uint8List> truckSidePng({required bool mirrored, TruckBranding branding = TruckBranding.neutral}) =>
    _pngFlutter(const Size(96, 96), (canvas) {
      const size = 96.0;
      const c = Offset(size / 2, size / 2);
      canvas.drawCircle(
          c + const Offset(0, 2),
          size / 2 - 6,
          Paint()
            ..color = Colors.black26
            ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 4));
      canvas.drawCircle(c, size / 2 - 6, Paint()..color = Colors.white);
      if (mirrored) {
        canvas.translate(size, 0);
        canvas.scale(-1, 1);
      }
      const icon = Icons.local_shipping;
      final tp = TextPainter(
        text: TextSpan(
          text: String.fromCharCode(icon.codePoint),
          style: TextStyle(
            fontSize: 56,
            fontFamily: icon.fontFamily,
            package: icon.fontPackage,
            color: branding.cab,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, c - Offset(tp.width / 2, tp.height / 2));
    });

// ------------------------------------------------------- 3/4-Ansicht (2.5D)

/// Aufliegertyp – getrennt vom Branding wählbar. (Tank folgt später.)
enum TrailerKind { box, curtain, reefer }

/// Farben und Beschriftung eines Fahrzeugs – getrennt vom Typ.
class TruckBranding {
  const TruckBranding({
    required this.id,
    this.sideText,
    this.cab = const Color(0xFF0D47A1),
    this.cabRoof = const Color(0xFF1565C0),
    this.trailer = const Color(0xFFF5F7FA),
    this.text = const Color(0xFF1B2733),
    this.roof,
    this.accent,
    this.skirt,
    this.subText,
    this.secondaryText,
    this.secondaryColor = const Color(0xFFC62828),
    this.rearText,
  });

  final String id;

  /// Schriftzug auf beiden Aufliegerseiten; null = neutral.
  final String? sideText;
  final Color cab;

  /// Hellerer Kabinenton (Dach in der Draufsicht, Lichtband).
  final Color cabRoof;
  final Color trailer;
  final Color text;

  /// Lackierung der Zugmaschine: Dach/oberer Kabinenrand und Zierstreifen
  /// (null = einfarbig wie bisher).
  final Color? roof;
  final Color? accent;

  /// Seitenschürze unter dem Auflieger (null = dunkles Fahrwerk).
  final Color? skirt;

  /// Zeile unter dem Schriftzug, z. B. ein Claim.
  final String? subText;

  /// Zweiter, kleinerer Schriftzug in der vorderen Aufliegerhälfte.
  final String? secondaryText;
  final Color secondaryColor;

  /// Kleiner Schriftzug oben an der Hecktür.
  final String? rearText;

  /// Mit Lackierung (Livery): Schriftzug in der hinteren Aufliegerhälfte statt
  /// über die ganze Seite.
  bool get livery => roof != null || subText != null;

  /// Standard: blaue Zugmaschine, weißer Auflieger ohne Schrift.
  static const neutral = TruckBranding(id: 'neutral');

  /// Wie [neutral], nur mit grüner Zugmaschine. Auflieger weiß und ohne
  /// Schrift – die Werbefläche bleibt frei.
  static const neutralGreen = TruckBranding(
    id: 'neutral-green',
    cab: Color(0xFF1E7D45),
    cabRoof: Color(0xFF2E9B5A),
  );

  /// GARTNER-Testlackierung nach den Referenzfotos (grün-gelbe Zugmaschine,
  /// weißer Kühlauflieger, Schriftzug hinten, rote Schürze) – Arbeitsstand
  /// zur Wirkung, KEIN freigegebenes Firmen-Branding.
  static const gartnerTest = TruckBranding(
    id: 'gartner-test',
    sideText: 'GARTNER',
    cab: Color(0xFF0E8A5A),
    trailer: Color(0xFFF7F8F8),
    text: Color(0xFF1A1A1A),
    roof: Color(0xFFF2C21B),
    accent: Color(0xFFF2C21B),
    skirt: Color(0xFFC62828),
    subText: 'THE WORLD OF TRANSPORT',
    secondaryText: 'THERMO-EXPRESS',
    rearText: 'GARTNER',
  );
}

/// Fahrzeug = Typ + Branding.
class TruckModel {
  const TruckModel({this.trailer = TrailerKind.box, this.branding = TruckBranding.neutral});

  final TrailerKind trailer;
  final TruckBranding branding;

  String get id => '${trailer.name}-${branding.id}';

  List<TruckBox> get boxes => [
        ...standardTruck,
        if (trailer == TrailerKind.reefer)
          const TruckBox(name: 'reefer-unit', fromF: 5.4, toF: 5.8, halfWidth: 0.85, fromZ: 2.4, toZ: 3.6),
      ];
}

/// Sattelzug in 3/4-Ansicht für Gierwinkel [yawDeg] relativ zur Blickrichtung
/// und Kartenneigung [pitchDeg]. Bodenmitte des Zugs = Bildmitte, damit das
/// Symbol mit Anker „Mitte“ genau auf der Straße steht.
Future<Uint8List> truckThreeQuarterPng(
  TruckModel model, {
  required double yawDeg,
  double pitchDeg = 42,
  double pxPerMeter = 10,
}) {
  final proj = TruckProjection(pitchDeg: pitchDeg, yawDeg: yawDeg);
  final boxes = model.boxes;
  final faces = proj.visibleFaces(boxes);

  // Bildgröße: symmetrisch um die Bodenmitte.
  var ext = 0.0;
  for (final f in faces) {
    for (final c in f.corners) {
      ext = math.max(ext, math.max(c.x.abs(), c.y.abs()));
    }
  }
  final half = (ext * pxPerMeter).ceilToDouble() + 8;
  final size = Size(half * 2, half * 2);

  Offset px(ScreenPoint p) => Offset(half + p.x * pxPerMeter, half + p.y * pxPerMeter);

  return _png(size, (c) {
    // Schatten auf der Straße: Grundriss bei z = 0, weich.
    final shadow = SpritePath();
    for (final b in boxes.where((b) => b.name != 'reefer-unit')) {
      final pts = [
        proj.world(b.toF, -b.halfWidth, 0),
        proj.world(b.toF, b.halfWidth, 0),
        proj.world(b.fromF, b.halfWidth, 0),
        proj.world(b.fromF, -b.halfWidth, 0),
      ].map((w) => px(proj.project(w))).toList();
      shadow.addPolygon(pts, true);
    }
    c.drawPath(
        shadow.shift(const Offset(1.5, 2)),
        Paint()
          ..color = const Color(0x55000000)
          ..maskFilter = spriteBlur(3));

    for (final f in faces) {
      final base = switch (f.box.name) {
        'cab' => model.branding.cab,
        'trailer' => model.branding.trailer,
        'reefer-unit' => const Color(0xFFB0BEC5),
        _ => const Color(0xFF263238), // Fahrwerk
      };
      final color = Color.lerp(Colors.black, base, f.shade)!;
      final poly = SpritePath()..addPolygon([for (final p in f.corners) px(p)], true);
      c.drawPath(poly, Paint()..color = color);
      c.drawPath(
          poly,
          Paint()
            ..color = const Color(0x33000000)
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1);
      if (f.box.name == 'trailer' && (f.side == FaceSide.left || f.side == FaceSide.right)) {
        _decorateSide(c, f, px, model);
      }
      if (f.box.name == 'cab' && f.side == FaceSide.front) {
        _windshield(c, f, px);
      }
    }
  });
}

/// Zeichnet auf eine Seitenfläche im Flächen-Koordinatensystem (u nach
/// rechts, v nach unten, je 0..1) – dadurch perspektivisch richtig und nie
/// gespiegelt (Ecken kommen in Leserichtung von außen).
void _inFace(SpriteCanvas c, ProjectedFace f, Offset Function(ScreenPoint) px, void Function(SpriteCanvas c) draw) {
  final o = px(f.corners[0]);
  final u = px(f.corners[1]) - o;
  final v = px(f.corners[3]) - o;
  c.save();
  c.transform(Float64List.fromList([
    u.dx, u.dy, 0, 0, //
    v.dx, v.dy, 0, 0, //
    0, 0, 1, 0, //
    o.dx, o.dy, 0, 1,
  ]));
  draw(c);
  c.restore();
}

void _decorateSide(SpriteCanvas c, ProjectedFace f, Offset Function(ScreenPoint) px, TruckModel model) {
  _inFace(c, f, px, (c) {
    if (model.trailer == TrailerKind.curtain) {
      final strap = Paint()
        ..color = const Color(0x22000000)
        ..strokeWidth = 0.004;
      for (var i = 1; i < 12; i++) {
        c.drawLine(Offset(i / 12, 0.02), Offset(i / 12, 0.98), strap);
      }
    }
    final text = model.branding.sideText;
    if (text == null) return;
    // Schrift in einem 1000 × 1000 Feld setzen und auf die Fläche skalieren.
    c.scale(1 / 1000, 1 / 1000);
    if (model.branding.livery) {
      _liverySide(c, f, model.branding);
      return;
    }
    final tp = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(
          fontSize: 520,
          fontWeight: FontWeight.w900,
          letterSpacing: 10,
          color: model.branding.text,
          height: 1,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    // Breite füllt 84 % der Fläche, Höhe höchstens 60 %.
    final sx = 840 / tp.width;
    final sy = math.min(600 / tp.height, sx * 3.2);
    c.translate(80, 500 - tp.height * sy / 2);
    c.scale(sx, sy);
    c.drawText(tp, Offset.zero);
  });
}

/// Aufliegerseite mit Lackierung (1000 × 1000 Feld, u nach rechts in
/// Leserichtung von außen): Schriftzug in der hinteren Hälfte, darunter der
/// Claim, vorn der zweite Schriftzug – wie auf den Referenzfotos. Die linke
/// Seite liest von vorn nach hinten (hinten = rechts), die rechte umgekehrt.
void _liverySide(SpriteCanvas c, ProjectedFace f, TruckBranding b) {
  final rearRight = f.side == FaceSide.left;
  TextPainter text(String s, Color color, FontWeight weight) => TextPainter(
        text: TextSpan(text: s, style: TextStyle(fontSize: 400, fontWeight: weight, color: color, height: 1)),
        textDirection: TextDirection.ltr,
      )..layout();
  void place(TextPainter tp, double left, double width, double top, double maxHeight) {
    // Seite ist ~4,7× so lang wie hoch: Höhe unabhängig von der Breite.
    final sx = width / tp.width;
    final sy = maxHeight / tp.height;
    c.save();
    c.translate(left, top);
    c.scale(sx, sy);
    c.drawText(tp, Offset.zero);
    c.restore();
  }

  // Hauptschriftzug: ~40 % der Länge, oberes Mitteldrittel, hintere Hälfte.
  final mainLeft = rearRight ? 520.0 : 80.0;
  place(text(b.sideText!, b.text, FontWeight.w900), mainLeft, 400, 300, 230);
  if (b.subText != null) {
    place(text(b.subText!, b.text, FontWeight.w600), mainLeft + 10, 380, 560, 80);
  }
  if (b.secondaryText != null) {
    final secLeft = rearRight ? 80.0 : 600.0;
    place(text(b.secondaryText!, b.secondaryColor, FontWeight.w800), secLeft, 320, 420, 110);
  }
}

/// Nachtfaktor in Achtelstufen – so wenige Fahrzeugbilder wie nötig, und
/// jeder Schritt ist klein genug, um nicht als Umschalten aufzufallen.
double nightStep(double night) => (night.clamp(0.0, 1.0) * 8).round() / 8;

/// Frontscheibe: tagsüber hellblau, nachts dunkles Blau-Anthrazit – nie
/// schwarz, mit leichtem Reflex.
Color windshieldColor(double night) =>
    Color.lerp(const Color(0xFF90CAF9), const Color(0xFF1F2B3B), night.clamp(0.0, 1.0))!;

void _windshield(SpriteCanvas c, ProjectedFace f, Offset Function(ScreenPoint) px,
    {double night = 0, double reflex = 0}) {
  _inFace(c, f, px, (c) {
    const glass = Rect.fromLTWH(0.1, 0.12, 0.8, 0.32);
    c.drawRect(glass, Paint()..color = windshieldColor(night));
    // Leichter Reflex oben (Himmel), nachts schwächer.
    c.drawRect(const Rect.fromLTWH(0.1, 0.12, 0.8, 0.08),
        Paint()..color = Colors.white.withValues(alpha: 0.18 - 0.1 * night));
    // Kaum merkliche, warme Innenraumwirkung nur nachts.
    c.drawRect(const Rect.fromLTWH(0.14, 0.3, 0.72, 0.12),
        Paint()..color = const Color(0xFFFFB74D).withValues(alpha: 0.10 * night));
    // Outro: sehr dezenter Reflex quer über die Scheibe.
    if (reflex > 0) {
      c.drawRect(
          glass,
          Paint()
            ..shader = spriteLinearGradient(const Offset(0.15, 0.12), const Offset(0.75, 0.44), [
              Colors.white.withValues(alpha: 0),
              Colors.white.withValues(alpha: 0.22 * reflex),
              Colors.white.withValues(alpha: 0),
            ], [0.35, 0.5, 0.65]));
    }
  });
}

// -------------------------------------------------- gekoppelter Sattelzug

/// Gekoppelter Sattelzug: Zugmaschine mit [tractorYaw], Auflieger mit
/// [tractorYaw] + [knick] (Grad, relativ zur Blickrichtung). Sattelpunkt
/// am Boden = Bildmitte (Anker auf der Karte). [night] 0 (Tag) … 1 (Nacht):
/// Karosserie gedämpft, Scheibe dunkel, Rücklichter und Scheinwerfer an –
/// alles gleitend.
Future<Uint8List> truckArticulatedPng(
  TruckModel model, {
  required double tractorYaw,
  required double knick,
  double pitchDeg = 42,
  double pxPerMeter = 10,
  double night = 0,
  double? tailLights,
  double? headLights,
  double? sweep,
}) {
  final n = night.clamp(0.0, 1.0);
  // Licht unabhängig von der Dunkelheit steuerbar (Outro-Reveal); sonst wie
  // bisher an die Nacht gekoppelt.
  final tail = (tailLights ?? n).clamp(0.0, 1.0);
  final head = (headLights ?? n).clamp(0.0, 1.0);
  final faces = articulatedFaces(
    tractorYaw: tractorYaw,
    knick: knick,
    pitchDeg: pitchDeg,
    extraTrailerBoxes: [
      if (model.trailer == TrailerKind.reefer)
        const TruckBox(name: 'reefer-unit', fromF: 1.2, toF: 1.6, halfWidth: 0.85, fromZ: 2.4, toZ: 3.6),
      // Seitenschürze zwischen Stützen und Achsen (Referenz: rot).
      if (model.branding.skirt != null)
        const TruckBox(name: 'skirt', fromF: -8.5, toF: -1.5, halfWidth: 1.22, fromZ: 0.45, toZ: 1.1),
    ],
  );
  var ext = 0.0;
  for (final f in faces) {
    for (final c in f.corners) {
      ext = math.max(ext, math.max(c.x.abs(), c.y.abs()));
    }
  }
  final half = (ext * pxPerMeter).ceilToDouble() + 10;
  Offset px(ScreenPoint p) => Offset(half + p.x * pxPerMeter, half + p.y * pxPerMeter);

  final tractor = TruckProjection(pitchDeg: pitchDeg, yawDeg: tractorYaw);
  final trailer = TruckProjection(pitchDeg: pitchDeg, yawDeg: tractorYaw + knick);

  return _png(Size(half * 2, half * 2), (c) {
    // Schatten beider Körper auf der Straße.
    final shadow = SpritePath();
    void footprint(TruckProjection pr, List<TruckBox> boxes) {
      for (final b in boxes) {
        shadow.addPolygon([
          for (final w in [
            pr.world(b.toF, -b.halfWidth, 0),
            pr.world(b.toF, b.halfWidth, 0),
            pr.world(b.fromF, b.halfWidth, 0),
            pr.world(b.fromF, -b.halfWidth, 0),
          ])
            px(pr.project(w)),
        ], true);
      }
    }

    footprint(tractor, tractorBoxes);
    footprint(trailer, trailerBoxes);
    c.drawPath(
        shadow.shift(const Offset(1.5, 2)),
        Paint()
          ..color = Color.lerp(const Color(0x55000000), const Color(0x33000000), n)!
          ..maskFilter = spriteBlur(3));

    final b = model.branding;
    for (final f in faces) {
      final base = switch (f.box.name) {
        'cab' when f.side == FaceSide.top && b.roof != null => b.roof!,
        'cab' => b.cab,
        'trailer' => b.trailer,
        'skirt' => b.skirt!,
        'reefer-unit' => const Color(0xFFB0BEC5),
        _ => const Color(0xFF263238),
      };
      final shade = f.shade * (1 - 0.28 * n); // nachts gedämpft
      final poly = SpritePath()..addPolygon([for (final p in f.corners) px(p)], true);
      c.drawPath(poly, Paint()..color = Color.lerp(Colors.black, base, shade)!);
      c.drawPath(
          poly,
          Paint()
            ..color = const Color(0x33000000)
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1);
      if (f.box.name == 'trailer' && (f.side == FaceSide.left || f.side == FaceSide.right)) {
        _decorateSide(c, f, px, model);
      }
      if (f.box.name == 'cab' && f.side != FaceSide.top && f.side != FaceSide.bottom && b.roof != null) {
        _cabLivery(c, f, px, b, n);
      }
      if (f.box.name == 'cab' && f.side == FaceSide.front) {
        _windshield(c, f, px, night: n, reflex: headLights == null ? 0 : head);
        if (head > 0) _headlamps(c, f, px, head);
      }
      if (f.box.name == 'trailer' && f.side == FaceSide.back && b.rearText != null) {
        _rearText(c, f, px, b);
      }
      if (tail > 0 && f.box.name == 'trailer' && f.side == FaceSide.back) {
        _taillights(c, f, px, tail);
      }
      if (tailLights != null && tail > 0 && f.box.name == 'trailer' && (f.side == FaceSide.left || f.side == FaceSide.right)) {
        _markerLights(c, f, px, tail);
      }
      if (sweep != null && (f.box.name == 'cab' || f.box.name == 'trailer') && (f.side == FaceSide.left || f.side == FaceSide.right)) {
        _lightSweep(c, f, px, sweep);
      }
    }
  });
}

/// Seitliche Begrenzungsleuchten (amber) unten am Auflieger.
void _markerLights(SpriteCanvas c, ProjectedFace f, Offset Function(ScreenPoint) px, double v) {
  _inFace(c, f, px, (c) {
    final glow = Paint()
      ..color = const Color(0xFFFFB300).withValues(alpha: 0.45 * v)
      ..maskFilter = spriteBlur(0.012);
    final lamp = Paint()..color = const Color(0xFFFFC107).withValues(alpha: v);
    for (var i = 0; i < 6; i++) {
      final x = 0.06 + i * 0.176;
      c.drawRect(Rect.fromLTWH(x - 0.008, 0.9, 0.022, 0.07), glow);
      c.drawRect(Rect.fromLTWH(x, 0.92, 0.008, 0.035), lamp);
    }
  });
}

/// Weicher Lichtlauf über die Seiten: ein heller, schräger Streifen bei
/// Weltposition [s] (0 = Front der Kabine, 1 = Heck des Aufliegers), so dass
/// er über Kabine und Auflieger durchgehend wandert.
void _lightSweep(SpriteCanvas c, ProjectedFace f, Offset Function(ScreenPoint) px, double s) {
  const front = 4.4, rear = -12.4; // Sattelpunkt-Koordinaten (Kabine bzw. Heck)
  final fBand = front + (rear - front) * s;
  // Kabine und Auflieger haben eigene Koordinaten; der Auflieger beginnt
  // vorn bei +1,2 m – für den Lauf genügt dieselbe Längsachse.
  final from = f.box.fromF, to = f.box.toF;
  final len = to - from;
  // u = 0 an der Front (linke Seite) bzw. am Heck (rechte Seite).
  final u = f.side == FaceSide.left ? (to - fBand) / len : (fBand - from) / len;
  final w = 1.6 / len;
  final a = 0.32 * math.sin(math.pi * s);
  if (a <= 0.01 || u < -w * 2 || u > 1 + w * 2) return;
  _inFace(c, f, px, (c) {
    c.clipRect(const Rect.fromLTWH(0, 0, 1, 1));
    final band = Paint()
      ..shader = spriteLinearGradient(
        Offset(u - w, 0),
        Offset(u + w, 0),
        [Colors.white.withValues(alpha: 0), Colors.white.withValues(alpha: a), Colors.white.withValues(alpha: 0)],
        [0, 0.5, 1],
      );
    c.drawRect(const Rect.fromLTWH(0, 0, 1, 1), band);
  });
}

/// Kabine: gelber oberer Rand (Dachbereich) ringsum, Zierstreifen schräg
/// über die Seiten, gelbe Blende über der Frontscheibe.
void _cabLivery(SpriteCanvas c, ProjectedFace f, Offset Function(ScreenPoint) px, TruckBranding b, double n) {
  final roof = Color.lerp(Colors.black, b.roof!, f.shade * (1 - 0.28 * n))!;
  final accent = Color.lerp(Colors.black, b.accent ?? b.roof!, f.shade * (1 - 0.28 * n))!;
  _inFace(c, f, px, (c) {
    if (f.side == FaceSide.front) {
      // Gelbe Blende über der Scheibe mit Schriftzug (Referenz: Sonnenblende).
      c.drawRect(const Rect.fromLTWH(0, 0, 1, 0.11), Paint()..color = roof);
      if (b.sideText != null) {
        c.save();
        c.scale(1 / 1000, 1 / 1000);
        final tp = TextPainter(
          text: TextSpan(text: b.sideText, style: TextStyle(fontSize: 400, fontWeight: FontWeight.w900, color: b.text, height: 1)),
          textDirection: TextDirection.ltr,
        )..layout();
        c.translate(220, 15);
        c.scale(560 / tp.width, 80 / tp.height);
        c.drawText(tp, Offset.zero);
        c.restore();
      }
      return;
    }
    if (f.side == FaceSide.back) {
      c.drawRect(const Rect.fromLTWH(0, 0, 1, 0.16), Paint()..color = roof);
      return;
    }
    // Seiten: u läuft von außen gesehen; vorn ist links (linke Seite) bzw.
    // rechts (rechte Seite).
    final frontLeft = f.side == FaceSide.left;
    double u(double fromFront) => frontLeft ? fromFront : 1 - fromFront;
    c.drawRect(const Rect.fromLTWH(0, 0, 1, 0.16), Paint()..color = roof);
    final stripe = Paint()
      ..color = accent
      ..strokeWidth = 0.035
      ..style = PaintingStyle.stroke;
    for (final d in [0.0, 0.07]) {
      c.drawLine(Offset(u(0.08 + d), 0.92), Offset(u(0.95), 0.42 + d), stripe);
    }
  });
}

/// Kleiner Schriftzug oben an der Hecktür.
void _rearText(SpriteCanvas c, ProjectedFace f, Offset Function(ScreenPoint) px, TruckBranding b) {
  _inFace(c, f, px, (c) {
    c.scale(1 / 1000, 1 / 1000);
    final tp = TextPainter(
      text: TextSpan(text: b.rearText, style: TextStyle(fontSize: 400, fontWeight: FontWeight.w900, color: b.text, height: 1)),
      textDirection: TextDirection.ltr,
    )..layout();
    final sx = 640 / tp.width;
    final sy = math.min(120 / tp.height, sx * 2);
    c.translate(180, 60);
    c.scale(sx, sy);
    c.drawText(tp, Offset.zero);
  });
}

/// Rücklichter: zwei dezente rote Leuchten unten am Heck.
void _taillights(SpriteCanvas c, ProjectedFace f, Offset Function(ScreenPoint) px, double n) {
  _inFace(c, f, px, (c) {
    final glow = Paint()
      ..color = const Color(0xFFFF1744).withValues(alpha: 0.6 * n)
      ..maskFilter = spriteBlur(0.04);
    final lamp = Paint()..color = const Color(0xFFFF5252).withValues(alpha: n);
    for (final x in [0.04, 0.82]) {
      c.drawRect(Rect.fromLTWH(x - 0.03, 0.78, 0.2, 0.14), glow);
      c.drawRect(Rect.fromLTWH(x, 0.8, 0.14, 0.1), lamp);
    }
  });
}

/// Scheinwerfer an der Front der Zugmaschine.
void _headlamps(SpriteCanvas c, ProjectedFace f, Offset Function(ScreenPoint) px, double n) {
  _inFace(c, f, px, (c) {
    final lamp = Paint()..color = const Color(0xFFFFF8E1).withValues(alpha: n);
    for (final x in [0.06, 0.78]) {
      c.drawRect(Rect.fromLTWH(x, 0.72, 0.16, 0.1), lamp);
    }
  });
}

/// Abblendlicht vor der Zugmaschine, flach auf der Straße. Ansatz unten in
/// der Mitte (= Front der Zugmaschine), Fahrtrichtung nach oben.
///
/// Zwei getrennte Scheinwerfer links und rechts der Front: je ein
/// länglicher, leicht nach außen gerichteter Lichtteppich, am hellsten
/// einige Meter vor dem Fahrzeug (nicht an der Kabine), weiter vorn zu
/// einem Feld zusammenlaufend und ohne Kante ausblendend. Rechts etwas
/// weiter und flacher nach außen (Abblendlicht-Asymmetrie, Rechtsverkehr).
/// Warm- bis neutralweiß. Pro Pixel berechnet, einmal erzeugt.
const Size headlightConeSize = Size(384, 640);

/// Länge des Bildes in Fahrzeugmetern (Maßstab des Lichts in der Szene).
const double headlightConeMeters = 26;

/// Deckkraft des Lichts aus dem Nachtfaktor (0 = Tag, 1 = Nacht): am Tag
/// unsichtbar, in der Dämmerung sehr schwach, nachts klar, aber nicht
/// dominant. Stetig – gleitet mit dem bestehenden Nachtfaktor.
double headlightOpacity(double night) => 0.9 * math.pow(night.clamp(0.0, 1.0), 1.3).toDouble();

/// Ein Scheinwerfer: seitlicher Versatz [x] (m, + = rechts), Abstrahlwinkel
/// nach außen [outward] (°), Reichweite bis Null [reach] (m).
typedef _Beam = ({double x, double outward, double reach});

const List<_Beam> _lowBeams = [
  (x: -0.95, outward: -2.5, reach: 21),
  (x: 0.95, outward: 3.5, reach: 24),
];

/// Hellste Stelle: so viele Meter vor der Front.
const double _beamPeak = 3.5;

double _smooth(double t) {
  final x = t.clamp(0.0, 1.0);
  return x * x * (3 - 2 * x);
}

/// Deckkraft (0..1) eines Scheinwerfers im Abstand [d] (m) vor der Front,
/// [lateral] m seitlich der Fahrzeugmitte.
double _beamAlpha(_Beam b, double d, double lateral) {
  if (d < 0 || d >= b.reach) return 0;
  // Längs: von 55 % am Scheinwerfer weich auf 100 % bei _beamPeak, danach
  // lang und ohne Kante auf 0 bei der Reichweite (Ableitung dort 0).
  final rise = d < _beamPeak ? 0.55 + 0.45 * _smooth(d / _beamPeak) : 1.0;
  final t = d <= _beamPeak ? 0.0 : (d - _beamPeak) / (b.reach - _beamPeak);
  final fall = math.pow(1 - t * t * t, 2).toDouble();
  // Quer: Gauß um die leicht nach außen laufende Strahlachse, nach vorn breiter.
  final centre = b.x + d * math.tan(b.outward * math.pi / 180);
  final sigma = 0.32 + 0.095 * d;
  final q = (lateral - centre) / sigma;
  return rise * fall * math.exp(-0.5 * q * q);
}

/// Deckkraft beider Scheinwerfer zusammen (wie Licht addiert, ≤ 1).
double headlightAlphaAt(double d, double lateral) {
  var dark = 1.0;
  for (final b in _lowBeams) {
    dark *= 1 - 0.85 * _beamAlpha(b, d, lateral);
  }
  return 1 - dark;
}

Future<Uint8List> headlightConePng() async {
  final w = headlightConeSize.width.toInt(), h = headlightConeSize.height.toInt();
  final pxPerMeter = h / headlightConeMeters;
  const near = Color(0xFFFFEFD0), far = Color(0xFFFFF7EC);
  // Zeilen mit Filterbyte 0, nicht vormultipliert (PNG-Standard).
  final raw = Uint8List(h * (w * 4 + 1));
  var i = 0;
  for (var y = 0; y < h; y++) {
    raw[i++] = 0;
    final d = (h - 0.5 - y) / pxPerMeter;
    final c = Color.lerp(near, far, (d / 20).clamp(0.0, 1.0))!;
    final r = (c.r * 255).round(), g = (c.g * 255).round(), b = (c.b * 255).round();
    for (var x = 0; x < w; x++) {
      raw[i++] = r;
      raw[i++] = g;
      raw[i++] = b;
      raw[i++] = (headlightAlphaAt(d, (x + 0.5 - w / 2) / pxPerMeter) * 255).round();
    }
  }
  return _encodePng(w, h, raw);
}

/// Minimaler PNG-Kodierer (RGBA, unkomprimierte Deflate-Blöcke): eindeutig
/// auf allen Plattformen, ohne Vormultiplizieren.
Uint8List _encodePng(int w, int h, Uint8List raw) {
  final out = BytesBuilder(copy: false)..add(const [137, 80, 78, 71, 13, 10, 26, 10]);
  void chunk(String type, List<int> data) {
    final body = Uint8List.fromList([...type.codeUnits, ...data]);
    out
      ..add(_u32(data.length))
      ..add(body)
      ..add(_u32(_crc32(body)));
  }

  chunk('IHDR', [..._u32(w), ..._u32(h), 8, 6, 0, 0, 0]);
  final z = BytesBuilder(copy: false)..add(const [0x78, 0x01]);
  for (var o = 0; o < raw.length; o += 65535) {
    final n = math.min(65535, raw.length - o);
    z
      ..addByte(o + n == raw.length ? 1 : 0)
      ..add([n & 0xFF, n >> 8, ~n & 0xFF, (~n >> 8) & 0xFF])
      ..add(Uint8List.sublistView(raw, o, o + n));
  }
  var s1 = 1, s2 = 0;
  for (final v in raw) {
    s1 = (s1 + v) % 65521;
    s2 = (s2 + s1) % 65521;
  }
  z.add(_u32((s2 << 16) | s1));
  chunk('IDAT', z.takeBytes());
  chunk('IEND', const []);
  return out.takeBytes();
}

List<int> _u32(int v) => [(v >> 24) & 0xFF, (v >> 16) & 0xFF, (v >> 8) & 0xFF, v & 0xFF];

final List<int> _crcTable = [
  for (var n = 0; n < 256; n++)
    () {
      var c = n;
      for (var k = 0; k < 8; k++) {
        c = (c & 1) != 0 ? 0xEDB88320 ^ (c >> 1) : c >> 1;
      }
      return c;
    }(),
];

int _crc32(List<int> bytes) {
  var c = 0xFFFFFFFF;
  for (final b in bytes) {
    c = _crcTable[(c ^ b) & 0xFF] ^ (c >> 8);
  }
  return c ^ 0xFFFFFFFF;
}
