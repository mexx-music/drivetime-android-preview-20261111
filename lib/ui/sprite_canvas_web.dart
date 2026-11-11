import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/painting.dart';

import 'sprite_canvas.dart';

/// Fahrzeugbild über EINEN wiederverwendeten Browser-Canvas zeichnen und
/// die Pixel lesen (RGBA, nicht vormultipliziert – wie bisher). Der Canvas
/// wird mit `willReadFrequently` angelegt: der Browser hält ihn im
/// Arbeitsspeicher, es entsteht keine WebGL-Textur je Bild.
/// null, wenn der Browser keinen 2D-Canvas liefert (dann Flutter-Weg).
({int width, int height, Uint8List rgba})? renderSpriteBrowser(Size size, void Function(SpriteCanvas c) paint) {
  final w = size.width.toInt(), h = size.height.toInt();
  if (w <= 0 || h <= 0) return null;
  final ctx = _context(w, h);
  if (ctx == null) return null;
  try {
    paint(_Browser2DCanvas(ctx));
    final data = ctx.callMethod<JSObject>('getImageData'.toJS, 0.toJS, 0.toJS, w.toJS, h.toJS);
    final px = (data['data'] as JSUint8ClampedArray).toDart;
    return (width: w, height: h, rgba: Uint8List.view(px.buffer, px.offsetInBytes, px.lengthInBytes));
  } catch (_) {
    return null;
  }
}

JSObject? _canvas;
JSObject? _ctx;

/// Der eine Canvas: bei anderer Größe nur umdimensioniert (das leert ihn und
/// setzt den Zustand zurück), sonst geleert und zurückgesetzt.
JSObject? _context(int w, int h) {
  try {
    if (_ctx == null) {
      final oc = globalContext['OffscreenCanvas'];
      _canvas = oc != null
          ? (oc as JSFunction).callAsConstructor<JSObject>(w.toJS, h.toJS)
          : (globalContext['document'] as JSObject).callMethod<JSObject>('createElement'.toJS, 'canvas'.toJS);
      final opts = JSObject()..['willReadFrequently'] = true.toJS;
      _ctx = _canvas!.callMethod<JSObject?>('getContext'.toJS, '2d'.toJS, opts);
      if (_ctx == null) return null;
    }
    final c = _canvas!;
    if ((c['width'] as JSNumber).toDartInt != w || (c['height'] as JSNumber).toDartInt != h) {
      c['width'] = w.toJS;
      c['height'] = h.toJS;
    } else {
      _ctx!.callMethodVarArgs<JSAny?>('setTransform'.toJS, [1.toJS, 0.toJS, 0.toJS, 1.toJS, 0.toJS, 0.toJS]);
      _ctx!.callMethod<JSAny?>('clearRect'.toJS, 0.toJS, 0.toJS, w.toJS, h.toJS);
    }
    return _ctx;
  } catch (_) {
    return null;
  }
}

String _css(Color c) =>
    'rgba(${(c.r * 255).round()},${(c.g * 255).round()},${(c.b * 255).round()},${c.a.toStringAsFixed(4)})';

class _Browser2DCanvas implements SpriteCanvas {
  _Browser2DCanvas(this.ctx);
  final JSObject ctx;

  void _call(String m, [List<JSAny?> args = const []]) => ctx.callMethodVarArgs<JSAny?>(m.toJS, args);
  void _set(String k, JSAny v) => ctx[k] = v;

  /// Maßstab der aktuellen Transformation (für Weichzeichnung und Haarlinien,
  /// die in Flutter in Gerätepixeln bzw. mit der Transformation wirken).
  double _scale() {
    final m = ctx.callMethod<JSObject>('getTransform'.toJS);
    double v(String k) => (m[k] as JSNumber).toDartDouble;
    return math.sqrt((v('a') * v('d') - v('b') * v('c')).abs());
  }

  /// Farbe/Verlauf, Weichzeichnung und Linie aus dem Flutter-Paint.
  void _apply(Paint p, {required bool stroke}) {
    final g = spriteGradientOf(p.shader);
    JSAny style;
    if (g != null) {
      final grad = ctx.callMethod<JSObject>(
          'createLinearGradient'.toJS, g.from.dx.toJS, g.from.dy.toJS, g.to.dx.toJS, g.to.dy.toJS);
      for (var i = 0; i < g.colors.length; i++) {
        grad.callMethod<JSAny?>('addColorStop'.toJS, g.stops[i].toJS, _css(g.colors[i]).toJS);
      }
      style = grad;
    } else {
      style = _css(p.color).toJS;
    }
    final sigma = spriteBlurSigma(p.maskFilter);
    final s = (sigma != null || (stroke && p.strokeWidth == 0)) ? _scale() : 1.0;
    _set('filter', (sigma != null && sigma > 0 ? 'blur(${(sigma * s).toStringAsFixed(3)}px)' : 'none').toJS);
    if (stroke) {
      _set('strokeStyle', style);
      _set('lineWidth', (p.strokeWidth == 0 ? 1 / (s == 0 ? 1 : s) : p.strokeWidth).toJS);
      _set('lineCap', p.strokeCap.name.toJS);
      _set('lineJoin', p.strokeJoin.name.toJS);
    } else {
      _set('fillStyle', style);
    }
  }

  void _paintPath(Paint p) {
    if (p.style == PaintingStyle.stroke) {
      _apply(p, stroke: true);
      _call('stroke');
    } else {
      _apply(p, stroke: false);
      _call('fill');
    }
  }

  @override
  void drawRect(Rect r, Paint p) {
    _call('beginPath');
    _call('rect', [r.left.toJS, r.top.toJS, r.width.toJS, r.height.toJS]);
    _paintPath(p);
  }

  @override
  void drawRRect(RRect r, Paint p) {
    _call('beginPath');
    _call('roundRect', [
      r.left.toJS, r.top.toJS, r.width.toJS, r.height.toJS,
      [r.tlRadiusX.toJS, r.trRadiusX.toJS, r.brRadiusX.toJS, r.blRadiusX.toJS].toJS,
    ]);
    _paintPath(p);
  }

  @override
  void drawPath(SpritePath path, Paint p) {
    _call('beginPath');
    for (final (k, x, y) in path.ops) {
      switch (k) {
        case 0:
          _call('moveTo', [x.toJS, y.toJS]);
        case 1:
          _call('lineTo', [x.toJS, y.toJS]);
        default:
          _call('closePath');
      }
    }
    _paintPath(p);
  }

  @override
  void drawLine(Offset a, Offset b, Paint p) {
    _call('beginPath');
    _call('moveTo', [a.dx.toJS, a.dy.toJS]);
    _call('lineTo', [b.dx.toJS, b.dy.toJS]);
    _apply(p, stroke: true); // Linien werden immer gezogen (wie in Flutter)
    _call('stroke');
  }

  @override
  void drawCircle(Offset c, double r, Paint p) {
    _call('beginPath');
    _call('arc', [c.dx.toJS, c.dy.toJS, r.toJS, 0.toJS, (2 * math.pi).toJS]);
    _paintPath(p);
  }

  @override
  void drawOval(Rect r, Paint p) {
    _call('beginPath');
    _call('ellipse', [
      r.center.dx.toJS, r.center.dy.toJS, (r.width / 2).toJS, (r.height / 2).toJS, 0.toJS, 0.toJS, (2 * math.pi).toJS,
    ]);
    _paintPath(p);
  }

  @override
  void save() => _call('save');
  @override
  void restore() => _call('restore');
  @override
  void translate(double dx, double dy) => _call('translate', [dx.toJS, dy.toJS]);
  @override
  void scale(double sx, [double? sy]) => _call('scale', [sx.toJS, (sy ?? sx).toJS]);

  @override
  void transform(Float64List m) =>
      _call('transform', [m[0].toJS, m[1].toJS, m[4].toJS, m[5].toJS, m[12].toJS, m[13].toJS]);

  @override
  void clipRect(Rect r) {
    _call('beginPath');
    _call('rect', [r.left.toJS, r.top.toJS, r.width.toJS, r.height.toJS]);
    _call('clip');
  }

  /// Text: Flutter hat gesetzt und vermessen; der Browser zeichnet in
  /// denselben Rahmen (gleiche Breite, gleiche Grundlinie).
  @override
  void drawText(TextPainter tp, Offset offset) {
    final span = tp.text;
    if (span is! TextSpan) return;
    final text = span.toPlainText();
    if (text.isEmpty) return;
    final st = span.style ?? const TextStyle();
    final size = st.fontSize ?? 14;
    final weight = (st.fontWeight ?? FontWeight.normal).value;
    _set('filter', 'none'.toJS);
    _set('font', '$weight ${size}px Roboto, "Helvetica Neue", Helvetica, Arial, sans-serif'.toJS);
    _set('textBaseline', 'alphabetic'.toJS);
    _set('fillStyle', _css(st.color ?? const Color(0xFF000000)).toJS);
    final ls = st.letterSpacing;
    if (ls != null) _set('letterSpacing', '${ls}px'.toJS);
    final m = ctx.callMethod<JSObject>('measureText'.toJS, text.toJS);
    final mw = (m['width'] as JSNumber).toDartDouble;
    final baseline = tp.computeDistanceToActualBaseline(TextBaseline.alphabetic);
    _call('save');
    _call('translate', [offset.dx.toJS, (offset.dy + baseline).toJS]);
    if (mw > 0) _call('scale', [(tp.width / mw).toJS, 1.toJS]);
    _call('fillText', [text.toJS, 0.toJS, 0.toJS]);
    _call('restore');
    if (ls != null) _set('letterSpacing', '0px'.toJS);
  }
}
