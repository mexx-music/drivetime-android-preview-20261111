import 'dart:ui' as ui;

import 'package:driverroute_eta/ui/sprite_canvas.dart';
import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('SpritePath zeichnet Befehle auf, Polygon und Verschiebung', () {
    final p = SpritePath()..addPolygon(const [Offset(0, 0), Offset(10, 0), Offset(10, 5)], true);
    expect(p.ops, [(0, 0.0, 0.0), (1, 10.0, 0.0), (1, 10.0, 5.0), (2, 0.0, 0.0)]);
    final s = p.shift(const Offset(1.5, 2));
    expect(s.ops.first, (0, 1.5, 2.0));
    expect(s.ops.last.$1, 2); // close bleibt close
    expect(p.ops.first, (0, 0.0, 0.0)); // Original unverändert
    expect(p.toUiPath().getBounds(), const Rect.fromLTRB(0, 0, 10, 5));
  });

  test('Weichzeichnung und Verlauf merken ihre Werte für den Browser-Canvas', () {
    final blur = spriteBlur(0.04);
    expect(spriteBlurSigma(blur), 0.04);
    expect(spriteBlurSigma(const MaskFilter.blur(BlurStyle.normal, 3)), isNull);
    // Ohne Stopps (nur mit 2 Farben erlaubt, wie die Fähren-Kielspur): 0 und 1.
    final g = spriteLinearGradient(Offset.zero, const Offset(1, 0), const [Color(0x00FFFFFF), Color(0xFFFFFFFF)]);
    final rec = spriteGradientOf(g)!;
    expect(rec.stops, [0.0, 1.0]);
    expect(rec.colors.length, 2);
    final g3 = spriteLinearGradient(Offset.zero, const Offset(1, 0),
        const [Color(0x00FFFFFF), Color(0xFFFFFFFF), Color(0x00FFFFFF)], const [0.35, 0.5, 0.65]);
    expect(spriteGradientOf(g3)!.stops, [0.35, 0.5, 0.65]);
    expect(spriteGradientOf(ui.Gradient.linear(Offset.zero, const Offset(1, 0), const [Color(0xFF000000), Color(0xFFFFFFFF)])), isNull);
  });
}
