import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:driverroute_eta/animation/cinematic_quality.dart';
import 'package:driverroute_eta/ui/ship_sprites.dart';
import 'package:driverroute_eta/ui/truck_sprites.dart';
import 'package:flutter_test/flutter_test.dart';

/// PNG wie MapLibre es sähe: dekodiert, RGBA nicht vormultipliziert.
Future<(int, int, List<int>)> _decode(List<int> png) async {
  final codec = await ui.instantiateImageCodec(png is Uint8List ? png : Uint8List.fromList(png));
  final frame = await codec.getNextFrame();
  final bytes = await frame.image.toByteData(format: ui.ImageByteFormat.rawStraightRgba);
  return (frame.image.width, frame.image.height, bytes!.buffer.asUint8List().toList());
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Qualitätsprofile', () {
    test('Film immer volle Qualität – egal auf welchem Gerät', () {
      expect(CinematicQuality.choose(videoExport: true, touchDevice: true), CinematicQuality.exportFullHD);
      expect(CinematicQuality.choose(videoExport: true, touchDevice: false), CinematicQuality.exportFullHD);
    });

    test('Vorschau: Touch-Gerät → Performance, sonst hoch', () {
      expect(CinematicQuality.choose(videoExport: false, touchDevice: true), CinematicQuality.previewPerformance);
      expect(CinematicQuality.choose(videoExport: false, touchDevice: false), CinematicQuality.previewHigh);
    });

    test('Export nie unter der hohen Vorschau; Performance spart nur Auflösung', () {
      const p = CinematicQuality.previewPerformance;
      const h = CinematicQuality.previewHigh;
      const x = CinematicQuality.exportFullHD;
      expect(x.spritePx, greaterThanOrEqualTo(h.spritePx));
      expect(x.outroSpritePx, greaterThanOrEqualTo(h.outroSpritePx));
      expect(x.maxMapPixelRatio, isNull);
      expect(h.maxMapPixelRatio, isNull);
      expect(p.spritePx, lessThan(h.spritePx));
      expect(p.maxMapPixelRatio, isNotNull);
      // Speicher bleibt in jedem Profil begrenzt.
      for (final q in [p, h, x]) {
        expect(q.maxDriveSprites, lessThanOrEqualTo(q.maxDriveSpritesOutro));
        expect(q.maxDriveSpritesOutro, lessThan(1000));
      }
    });
  });

  test('Outro: nur die Performance-Vorschau gröber, Film und hohe Vorschau wie bisher', () {
    for (final q in [CinematicQuality.exportFullHD, CinematicQuality.previewHigh]) {
      expect((q.outroYawStep, q.outroPitchStep, q.outroSweepSteps, q.releaseDriveSpritesAtOutro), (4, 5, 8, false));
    }
    const p = CinematicQuality.previewPerformance;
    expect((p.outroYawStep, p.outroPitchStep, p.outroSweepSteps, p.releaseDriveSpritesAtOutro), (8, 5, 4, true));
    expect(p.outroYawStep % 4, 0); // Bildnamen in 4°-Einheiten
  });

  test('Zielanflug: nur die Performance-Vorschau verteilt und gibt früher frei', () {
    for (final q in [CinematicQuality.exportFullHD, CinematicQuality.previewHigh]) {
      expect((q.outroPrewarmPerSecond, q.approachDriveSprites), (null, null));
    }
    const p = CinematicQuality.previewPerformance;
    expect(p.outroPrewarmPerSecond, 8);
    expect(p.approachDriveSprites, lessThanOrEqualTo(p.maxDriveSprites));
  });

  group('Rohe Sprites (ohne PNG-Umweg)', () {
    test('Lkw: dieselben Pixel wie das PNG', () async {
      Future<Uint8List> draw() => truckArticulatedPng(const TruckModel(),
          tractorYaw: 150, knick: 12, pitchDeg: 45, pxPerMeter: 12, night: 0.5);
      final raw = await asSpriteBitmap(draw);
      final (w, h, px) = await _decode(await draw());
      expect((raw.width, raw.height), (w, h));
      expect(raw.rgba.length, w * h * 4);
      expect(raw.rgba, px);
    });

    test('Fähre: dieselben Pixel wie das PNG', () async {
      Future<Uint8List> draw() => ferryShipPng(yawDeg: 160, pitchDeg: 45, night: 0.25);
      final raw = await asSpriteBitmap(draw);
      final (w, h, px) = await _decode(await draw());
      expect((raw.width, raw.height), (w, h));
      expect(raw.rgba, px);
    });

    test('außerhalb von asSpriteBitmap weiter PNG', () async {
      final png = await truckArticulatedPng(const TruckModel(), tractorYaw: 0, knick: 0);
      expect(png.sublist(1, 4), 'PNG'.codeUnits);
    });
  });
}
