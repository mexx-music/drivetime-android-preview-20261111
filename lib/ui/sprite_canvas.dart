import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';

/// Zeichenfläche für Fahrzeugbilder (Lkw, Fähre) – genau die Operationen,
/// die der Zeichencode braucht. Zwei Umsetzungen:
///
/// - [FlutterSpriteCanvas]: der Flutter-Canvas wie bisher (Tests, Export,
///   statische Symbole).
/// - Browser-2D (nur Web, `sprite_canvas_web.dart`): ein wiederverwendeter
///   Browser-Canvas. Grund: Flutter-Web legt bei jedem `Picture.toImage()`
///   eine WebGL-Textur samt Framebuffer an und gibt sie nie frei (gemessen
///   CanvasKit und skwasm: je Lkw-Bild +1, lange Tour +200 MB). Auf dem
///   iPhone beendet die Homescreen-Web-App die Seite daran.
abstract class SpriteCanvas {
  void drawRect(Rect rect, Paint paint);
  void drawRRect(RRect rrect, Paint paint);
  void drawPath(SpritePath path, Paint paint);
  void drawLine(Offset p1, Offset p2, Paint paint);
  void drawCircle(Offset center, double radius, Paint paint);
  void drawOval(Rect rect, Paint paint);
  void save();
  void restore();
  void translate(double dx, double dy);
  void scale(double sx, [double? sy]);
  void transform(Float64List matrix4);
  void clipRect(Rect rect);

  /// Text, von Flutter gesetzt und vermessen ([tp] ist bereits gelayoutet),
  /// oben links bei [offset].
  void drawText(TextPainter tp, Offset offset);
}

/// Pfad, der seine Befehle aufzeichnet – Flutters `Path` lässt sich nicht
/// auslesen, der Browser-Canvas braucht die Befehle.
class SpritePath {
  final List<(int, double, double)> _ops = [];

  void moveTo(double x, double y) => _ops.add((0, x, y));
  void lineTo(double x, double y) => _ops.add((1, x, y));
  void close() => _ops.add((2, 0, 0));

  void addPolygon(List<Offset> points, bool close) {
    if (points.isEmpty) return;
    moveTo(points.first.dx, points.first.dy);
    for (final p in points.skip(1)) {
      lineTo(p.dx, p.dy);
    }
    if (close) this.close();
  }

  SpritePath shift(Offset o) {
    final p = SpritePath();
    for (final (k, x, y) in _ops) {
      p._ops.add(k == 2 ? (k, x, y) : (k, x + o.dx, y + o.dy));
    }
    return p;
  }

  /// Befehle: (0 = moveTo, 1 = lineTo, 2 = close, x, y).
  List<(int, double, double)> get ops => _ops;

  ui.Path toUiPath() {
    final p = ui.Path();
    for (final (k, x, y) in _ops) {
      switch (k) {
        case 0:
          p.moveTo(x, y);
        case 1:
          p.lineTo(x, y);
        default:
          p.close();
      }
    }
    return p;
  }
}

/// Weichzeichnung mit gemerkter Stärke (für den Browser-Canvas).
final Expando<double> _blurSigma = Expando('spriteBlur');
MaskFilter spriteBlur(double sigma) {
  final f = MaskFilter.blur(BlurStyle.normal, sigma);
  _blurSigma[f] = sigma;
  return f;
}

double? spriteBlurSigma(MaskFilter? f) => f == null ? null : _blurSigma[f];

/// Linearer Verlauf mit gemerkten Parametern (für den Browser-Canvas).
typedef SpriteLinearGradient = ({Offset from, Offset to, List<Color> colors, List<double> stops});
final Expando<SpriteLinearGradient> _gradients = Expando('spriteGradient');
ui.Gradient spriteLinearGradient(Offset from, Offset to, List<Color> colors, [List<double>? stops]) {
  final g = ui.Gradient.linear(from, to, colors, stops);
  // Ohne Stopps wie in Flutter gleichmäßig verteilt.
  final st = stops ?? [for (var i = 0; i < colors.length; i++) colors.length == 1 ? 0.0 : i / (colors.length - 1)];
  _gradients[g] = (from: from, to: to, colors: colors, stops: st);
  return g;
}

SpriteLinearGradient? spriteGradientOf(Shader? s) => s == null ? null : _gradients[s];

/// Flutter-Canvas wie bisher.
class FlutterSpriteCanvas implements SpriteCanvas {
  FlutterSpriteCanvas(this.c);
  final Canvas c;

  @override
  void drawRect(Rect rect, Paint paint) => c.drawRect(rect, paint);
  @override
  void drawRRect(RRect rrect, Paint paint) => c.drawRRect(rrect, paint);
  @override
  void drawPath(SpritePath path, Paint paint) => c.drawPath(path.toUiPath(), paint);
  @override
  void drawLine(Offset p1, Offset p2, Paint paint) => c.drawLine(p1, p2, paint);
  @override
  void drawCircle(Offset center, double radius, Paint paint) => c.drawCircle(center, radius, paint);
  @override
  void drawOval(Rect rect, Paint paint) => c.drawOval(rect, paint);
  @override
  void save() => c.save();
  @override
  void restore() => c.restore();
  @override
  void translate(double dx, double dy) => c.translate(dx, dy);
  @override
  void scale(double sx, [double? sy]) => c.scale(sx, sy);
  @override
  void transform(Float64List matrix4) => c.transform(matrix4);
  @override
  void clipRect(Rect rect) => c.clipRect(rect);
  @override
  void drawText(TextPainter tp, Offset offset) => tp.paint(c, offset);
}
