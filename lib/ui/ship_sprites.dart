import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../animation/ship_model.dart';
import '../animation/truck_projection.dart';
import 'sprite_canvas.dart';
import 'truck_sprites.dart' show renderSpriteBytes;

/// EXPERIMENT – Bild der neutralen Fähre v1, deterministisch erzeugt wie der
/// Sattelzug: ein Bild je Gierwinkel zur Blickrichtung, Neigung und
/// Nachtstufe. Bildmitte = Schiffsmitte an der Wasserlinie.

const _hullDark = Color(0xFF243B55);
const _hullWhite = Color(0xFFF2F4F7);
const _deck = Color(0xFFB0BEC5);
const _house = Color(0xFFF7F8FA);
const _funnel = Color(0xFF37474F);
const _funnelBand = Color(0xFF26A69A);
const _glass = Color(0xFF37474F);
const _litWindow = Color(0xFFFFE08A);

/// Nachts: Farben gedämpft und leicht bläulich (nie schwarz).
Color _night(Color c, double n) => Color.lerp(c, Color.lerp(c, const Color(0xFF3A4A66), 0.35)!, n)!;

Future<Uint8List> _png(Size size, void Function(SpriteCanvas c) paint) => renderSpriteBytes(size, paint);

/// Bildpunkte je Schiffsmeter im Sprite.
const double shipSpritePx = 2.4;

/// Halbe Kantenlänge des quadratischen Bildes in Pixeln.
double shipSpriteHalf(TruckProjection proj) => (shipScreenExtent(proj) * shipSpritePx).ceilToDouble() + 12;

/// Fähre bei Gierwinkel [yawDeg] relativ zur Blickrichtung (0 = fährt vom
/// Betrachter weg, + = zeigt Steuerbord), Kartenneigung [pitchDeg] und
/// Nacht [night] (0..1, in Achtelstufen übergeben).
Future<Uint8List> ferryShipPng({required double yawDeg, required double pitchDeg, required double night}) {
  final n = night.clamp(0.0, 1.0);
  final proj = TruckProjection(pitchDeg: pitchDeg, yawDeg: yawDeg);
  final half = shipSpriteHalf(proj);
  Offset px(ScreenPoint p) => Offset(half + p.x * shipSpritePx, half + p.y * shipSpritePx);
  Offset at(double f, double r, double z) => px(proj.project(proj.world(f, r, z)));

  return _png(Size(half * 2, half * 2), (c) {
    // Kielwasser: schmaler, weicher heller Streifen hinter dem Heck (keine Wellen).
    final wake = SpritePath()
      ..moveTo(at(FerryShipModel.sternF, -11, 0).dx, at(FerryShipModel.sternF, -11, 0).dy)
      ..lineTo(at(FerryShipModel.sternF - shipWakeLength, -20, 0).dx, at(FerryShipModel.sternF - shipWakeLength, -20, 0).dy)
      ..lineTo(at(FerryShipModel.sternF - shipWakeLength, 20, 0).dx, at(FerryShipModel.sternF - shipWakeLength, 20, 0).dy)
      ..lineTo(at(FerryShipModel.sternF, 11, 0).dx, at(FerryShipModel.sternF, 11, 0).dy)
      ..close();
    c.drawPath(
        wake,
        Paint()
          ..shader = spriteLinearGradient(
            at(FerryShipModel.sternF, 0, 0),
            at(FerryShipModel.sternF - shipWakeLength, 0, 0),
            [Colors.white.withValues(alpha: 0.45 * (1 - 0.5 * n)), Colors.white.withValues(alpha: 0)],
          )
          ..maskFilter = spriteBlur(3));

    // Schatten im Wasser: Grundriss leicht versetzt.
    final outline = FerryShipModel.hullOutline();
    final foot = SpritePath()..addPolygon([for (final (f, r) in outline) at(f, r, 0)], true);
    c.drawPath(
        foot.shift(const Offset(2, 3)),
        Paint()
          ..color = const Color(0x44000000)
          ..maskFilter = spriteBlur(4));

    // Rumpf.
    for (final h in visibleHullFaces(proj)) {
      final base = _night(h.upper ? _hullWhite : _hullDark, n);
      final poly = SpritePath()..addPolygon([for (final p in h.corners) px(p)], true);
      c.drawPath(poly, Paint()..color = Color.lerp(Colors.black, base, h.shade * (1 - 0.1 * n))!);
      if (h.stern && h.upper) {
        // Heckklappe (Fahrzeugdeck): dunkles Rechteck im Heckspiegel.
        _inQuad(c, h.corners, px, (c) {
          c.drawRect(const Rect.fromLTWH(0.3, 0.15, 0.4, 0.85), Paint()..color = _night(const Color(0xFF455A64), n));
        });
      }
    }
    // Deck.
    c.drawPath(
        SpritePath()..addPolygon([for (final (f, r) in outline) at(f, r, FerryShipModel.freeboard)], true),
        Paint()..color = _night(_deck, n));
    c.drawPath(
        SpritePath()..addPolygon([for (final (f, r) in outline) at(f, r, FerryShipModel.freeboard)], true),
        Paint()
          ..color = const Color(0x33000000)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1);

    // Aufbauten.
    for (final f in proj.visibleFaces(FerryShipModel.superstructure)) {
      final base = switch (f.box.name) {
        'funnel' => _funnel,
        'mast' => const Color(0xFF90A4AE),
        _ => _house,
      };
      final poly = SpritePath()..addPolygon([for (final p in f.corners) px(p)], true);
      c.drawPath(poly, Paint()..color = Color.lerp(Colors.black, _night(base, n), f.shade * (1 - 0.1 * n))!);
      c.drawPath(
          poly,
          Paint()
            ..color = const Color(0x22000000)
            ..style = PaintingStyle.stroke
            ..strokeWidth = 0.8);
      final side = f.side;
      final vertical = side != FaceSide.top && side != FaceSide.bottom;
      if (f.box.name == 'funnel' && vertical) {
        _inQuad(c, f.corners, px, (c) {
          c.drawRect(const Rect.fromLTWH(0, 0.12, 1, 0.16), Paint()..color = _night(_funnelBand, n));
        });
      }
      if ((f.box.name == 'deckhouse' || f.box.name == 'upper') && (side == FaceSide.left || side == FaceSide.right)) {
        _windows(c, f, px, n, rows: f.box.name == 'deckhouse' ? 3 : 1, cols: 26, seed: f.box.name.length + side.index);
      }
      if (f.box.name == 'bridge' && (side == FaceSide.front || side == FaceSide.left || side == FaceSide.right)) {
        // Brückenfenster: durchgehendes Band.
        _inQuad(c, f.corners, px, (c) {
          c.drawRect(const Rect.fromLTWH(0.04, 0.22, 0.92, 0.3), Paint()..color = _glass);
          if (n > 0) {
            c.drawRect(const Rect.fromLTWH(0.04, 0.22, 0.92, 0.3),
                Paint()..color = _litWindow.withValues(alpha: 0.35 * n));
          }
        });
      }
    }

    // Positionslichter (nur bei Dämmerung/Nacht), je nach Seite sichtbar.
    if (n > 0) {
      void lamp(({double f, double r, double z}) w, Color color, double radius) {
        final o = at(w.f, w.r, w.z);
        c.drawCircle(o, radius * 2.4, Paint()
          ..color = color.withValues(alpha: 0.35 * n)
          ..maskFilter = spriteBlur(2.5));
        c.drawCircle(o, radius, Paint()..color = color.withValues(alpha: n));
      }

      final seesLeft = proj.facesViewer(FaceSide.left), seesRight = proj.facesViewer(FaceSide.right);
      final seesFront = proj.facesViewer(FaceSide.front), seesBack = proj.facesViewer(FaceSide.back);
      if (seesLeft || seesFront) lamp(FerryShipModel.portLight, const Color(0xFFFF3B30), 1.8);
      if (seesRight || seesFront) lamp(FerryShipModel.starboardLight, const Color(0xFF34C759), 1.8);
      lamp(FerryShipModel.mastheadLight, const Color(0xFFFFFDF0), 1.6);
      if (seesBack) lamp(FerryShipModel.sternLight, const Color(0xFFFFFDF0), 1.5);
    }
  });
}

/// Zeichnet im Flächen-Koordinatensystem (u nach rechts, v nach unten, je
/// 0..1) – perspektivisch richtig, Ecken in Leserichtung von außen.
void _inQuad(SpriteCanvas c, List<ScreenPoint> corners, Offset Function(ScreenPoint) px, void Function(SpriteCanvas c) draw) {
  final o = px(corners[0]);
  final u = px(corners[1]) - o;
  final v = px(corners[3]) - o;
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

/// Ob Fenster Nummer [i] nachts beleuchtet ist – fest, nicht zufällig.
bool shipWindowLit(int i, int seed) => ((i * 7 + seed * 13) % 11) < 4;

void _windows(SpriteCanvas c, ProjectedFace f, Offset Function(ScreenPoint) px, double n,
    {required int rows, required int cols, required int seed}) {
  _inQuad(c, f.corners, px, (c) {
    final dark = Paint()..color = _glass;
    final lit = Paint()..color = _litWindow.withValues(alpha: math.min(1, 0.25 + n));
    var i = 0;
    for (var r = 0; r < rows; r++) {
      final y = (r + 0.35) / rows;
      for (var k = 0; k < cols; k++) {
        final x = (k + 0.2) / cols;
        final rect = Rect.fromLTWH(x, y, 0.55 / cols, 0.32 / rows);
        c.drawRect(rect, dark);
        if (n > 0.2 && shipWindowLit(i, seed)) c.drawRect(rect, lit);
        i++;
      }
    }
  });
}
