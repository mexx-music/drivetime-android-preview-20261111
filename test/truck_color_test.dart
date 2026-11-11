// Truckfarbe Blau/Grün: Speicher, Filmspezifikation, Sprites, 2D-Symbol,
// Studio-Export. Die App-Abläufe (Auswahl → Animation/Live-Aufnahme)
// stehen in tour_animation_test.dart.

import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:driverroute_eta/animation/tour_path.dart';
import 'package:driverroute_eta/export/film_spec.dart';
import 'package:driverroute_eta/export/film_view.dart';
import 'package:driverroute_eta/export/studio_export_backend.dart';
import 'package:driverroute_eta/export/video_export_preset.dart';
import 'package:driverroute_eta/logic/eta_calculator.dart';
import 'package:driverroute_eta/services/truck_color_store.dart';
import 'package:driverroute_eta/services/map_launcher.dart' show RouteMapPlan;
import 'package:driverroute_eta/ui/map_osm_view.dart' show MapSegment;
import 'package:driverroute_eta/ui/tour_animation_view.dart';
import 'package:driverroute_eta/ui/truck_sprites.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:latlong2/latlong.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _blue = Color(0xFF0D47A1);
const _green = Color(0xFF1E7D45);
const _greenRoof = Color(0xFF2E9B5A);

/// PNG → Pixel (RGBA, nicht vormultipliziert).
Future<(int, List<int>)> _decode(Uint8List png) async {
  final frame = await (await ui.instantiateImageCodec(png)).getNextFrame();
  final bytes = await frame.image.toByteData(format: ui.ImageByteFormat.rawStraightRgba);
  return (frame.image.width, bytes!.buffer.asUint8List().toList());
}

/// Anzahl Pixel, die (fast) genau [c] haben.
Future<int> _count(Uint8List png, Color c) async {
  final (_, px) = await _decode(png);
  final r = (c.r * 255).round(), g = (c.g * 255).round(), b = (c.b * 255).round();
  var n = 0;
  for (var i = 0; i + 3 < px.length; i += 4) {
    if (px[i + 3] > 250 && (px[i] - r).abs() < 3 && (px[i + 1] - g).abs() < 3 && (px[i + 2] - b).abs() < 3) n++;
  }
  return n;
}

/// Pixel mit deutlich grünem bzw. blauem Farbton (auch schattiert).
Future<({int green, int blue})> _hues(Uint8List png) async {
  final (_, px) = await _decode(png);
  var g = 0, b = 0;
  for (var i = 0; i + 3 < px.length; i += 4) {
    if (px[i + 3] < 200) continue;
    final r = px[i], gr = px[i + 1], bl = px[i + 2];
    if (gr > r + 30 && gr > bl + 20) g++;
    if (bl > r + 40 && bl > gr + 20) b++;
  }
  return (green: g, blue: b);
}

List<LatLng> _line(LatLng a, LatLng b, int n) => [
      for (var i = 0; i <= n; i++)
        LatLng(a.latitude + (b.latitude - a.latitude) * i / n, a.longitude + (b.longitude - a.longitude) * i / n),
    ];

TourFilmSpec _spec({String? truck}) {
  final t0 = DateTime.utc(2026, 10, 10, 6).toLocal();
  final pts = _line(const LatLng(48.09, 13.87), const LatLng(53.55, 9.99), 50);
  final plan = RouteMapPlan.restored(
    start: pts.first,
    dest: pts.last,
    segments: [MapSegment(points: pts, label: 'Lambach → Hamburg')],
    stops: const [],
    subtitle: 'Straße',
  );
  final eta = EtaResult(
    [
      EtaStep('Start', type: EtaEventType.start, start: t0, end: t0),
      EtaStep('Fahrt', type: EtaEventType.drive, title: 'Fahrt', start: t0, end: t0.add(const Duration(hours: 8)), distanceKm: 700),
      EtaStep('Ziel', type: EtaEventType.destination, start: t0.add(const Duration(hours: 8)), end: t0.add(const Duration(hours: 8))),
    ],
    t0.add(const Duration(hours: 8)),
  );
  return truck == null
      ? TourFilmSpec(plan: plan, eta: eta, title: 'Lambach → Hamburg', fromName: 'Lambach', toName: 'Hamburg')
      : TourFilmSpec(
          plan: plan, eta: eta, title: 'Lambach → Hamburg', fromName: 'Lambach', toName: 'Hamburg', truckBranding: truck);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Auswahl und Speicher', () {
    test('Blau ist Standard (nichts gespeichert, unbekannt, kaputt)', () async {
      SharedPreferences.setMockInitialValues({});
      expect(await TruckColorStore.load(), TruckColor.blue);
      SharedPreferences.setMockInitialValues({TruckColorStore.key: 'lila'});
      expect(await TruckColorStore.load(), TruckColor.blue);
      expect(TruckColor.parse(null), TruckColor.blue);
    });

    test('Grün speichern und wiederherstellen', () async {
      SharedPreferences.setMockInitialValues({});
      await TruckColorStore.save(TruckColor.green);
      expect(await TruckColorStore.load(), TruckColor.green);
      await TruckColorStore.save(TruckColor.blue);
      expect(await TruckColorStore.load(), TruckColor.blue);
    });

    test('Film-Build bleibt bei der GARTNER-Testlackierung, sonst die Auswahl', () {
      for (final c in TruckColor.values) {
        expect(filmTruckBrandingId(filmBuild: true, color: c), 'gartner-test');
      }
      expect(filmTruckBrandingId(filmBuild: false, color: TruckColor.blue), 'neutral');
      expect(filmTruckBrandingId(filmBuild: false, color: TruckColor.green), 'neutral-green');
    });
  });

  group('Branding und Filmspezifikation', () {
    test('Grün: eigene stabile Kennung, nur Kabine anders, Werbefläche ohne Schrift', () {
      const g = TruckBranding.neutralGreen;
      expect(g.id, 'neutral-green');
      expect(g.cab, _green);
      expect(g.cabRoof, _greenRoof);
      expect(g.trailer, TruckBranding.neutral.trailer); // weiß
      for (final b in [TruckBranding.neutral, g]) {
        expect(b.sideText, isNull);
        expect(b.subText, isNull);
        expect(b.secondaryText, isNull);
        expect(b.rearText, isNull);
        expect(b.livery, isFalse);
        expect(b.roof, isNull);
        expect(b.skirt, isNull);
      }
      expect(TruckBranding.neutral.cab, _blue);
      expect(const TruckModel(branding: g).id, isNot(const TruckModel().id)); // eigener Bildspeicher
    });

    test('Kennung → Branding; unbekannt fällt auf Blau zurück', () {
      expect(truckBrandingById('neutral'), same(TruckBranding.neutral));
      expect(truckBrandingById('neutral-green'), same(TruckBranding.neutralGreen));
      expect(truckBrandingById('gartner-test'), same(TruckBranding.gartnerTest));
      expect(truckBrandingById('irgendwas'), same(TruckBranding.neutral));
      expect(truckBrandingById(''), same(TruckBranding.neutral));
    });

    test('Film-ID: Blau unverändert, Grün eigene ID; JSON bleibt stabil', () {
      final blueDefault = _spec();
      final blueExplicit = _spec(truck: 'neutral');
      final green = _spec(truck: 'neutral-green');
      expect(blueDefault.truckBranding, 'neutral');
      expect(blueExplicit.filmId, blueDefault.filmId); // bestehende blaue IDs bleiben
      expect(green.filmId, isNot(blueDefault.filmId));
      final again = TourFilmSpec.fromJson(jsonDecode(jsonEncode(green.toJson())) as Map<String, dynamic>);
      expect(again.truckBranding, 'neutral-green');
      expect(again.filmId, green.filmId);
    });

    test('Film zur Spezifikation zeigt den gewählten Truck (Animation, Live-Aufnahme, Export)', () {
      for (final (id, branding) in [
        ('neutral', TruckBranding.neutral),
        ('neutral-green', TruckBranding.neutralGreen),
        ('unbekannt', TruckBranding.neutral),
      ]) {
        final spec = _spec(truck: id);
        for (final export in [false, true]) {
          final view = filmViewFor(spec, path: filmPathFor(spec)!, videoExport: export) as TourAnimationView;
          expect(view.truckModel.branding, same(branding));
        }
      }
    });

    test('Studio-Export übernimmt die Auswahl: Spezifikation geht mit Grün an den Dienst', () async {
      Map<String, dynamic>? sent;
      final backend = StudioExportBackend(
        baseUrl: Uri.parse('http://studio.test/'),
        client: MockClient((r) async {
          sent = jsonDecode(r.body) as Map<String, dynamic>;
          return http.Response('{"jobId":"j1"}', 202);
        }),
      );
      await backend.start(_spec(truck: 'neutral-green'), VideoExportPreset.controlPreview);
      final spec = TourFilmSpec.fromJson(sent!['spec'] as Map<String, dynamic>);
      expect(spec.truckBranding, 'neutral-green');
      // Der Dienst rendert den Film mit derselben App-Regie → grüner Truck.
      final view = filmViewFor(spec, path: filmPathFor(spec)!, videoExport: true) as TourAnimationView;
      expect(view.truckModel.branding.cab, _green);
    });
  });

  group('Darstellung', () {
    testWidgets('Ersatzbilder (Draufsicht, Heck, Seite) folgen dem Branding; Blau unverändert', (tester) async {
      await tester.runAsync(() async {
        for (final draw in <Future<Uint8List> Function(TruckBranding)>[
          (b) => truckTopPng(branding: b),
          (b) => truckRearPng(branding: b),
          (b) => truckSidePng(mirrored: false, branding: b),
          (b) => truckSidePng(mirrored: true, branding: b),
        ]) {
          final blue = await draw(TruckBranding.neutral);
          final green = await draw(TruckBranding.neutralGreen);
          expect(await _count(blue, _blue), greaterThan(20));
          expect(await _count(blue, _green), 0);
          expect(await _count(green, _green), greaterThan(20));
          expect(await _count(green, _blue), 0);
        }
        // Ohne Angabe: Blau wie bisher (bitgleich).
        expect(await truckTopPng(), await truckTopPng(branding: TruckBranding.neutral));
        expect(await truckSidePng(mirrored: false), await truckSidePng(mirrored: false, branding: TruckBranding.neutral));
      });
    });

    testWidgets('2.5D-Truck (gekoppelt, auch im Outro) in der gewählten Kabinenfarbe', (tester) async {
      await tester.runAsync(() async {
        Future<Uint8List> art(TruckBranding b) =>
            truckArticulatedPng(TruckModel(branding: b), tractorYaw: 30, knick: 0, pxPerMeter: 12);
        final green = await _hues(await art(TruckBranding.neutralGreen));
        final blue = await _hues(await art(TruckBranding.neutral));
        // Kabine schattiert: Farbton statt exakter Farbe prüfen. Die blaue
        // Windschutzscheibe gibt es in beiden Varianten.
        expect(green.green, greaterThan(50));
        expect(blue.green, 0);
        expect(blue.blue, greaterThan(green.blue + 50));
      });
    });

    testWidgets('2D-Symbol in der gewählten Farbe', (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(1000, 1400);
      addTearDown(tester.view.reset);
      final path = TourPath([TourLeg(points: _line(const LatLng(48.09, 13.87), const LatLng(53.55, 9.99), 200))]);
      for (final (branding, color) in [(TruckBranding.neutral, _blue), (TruckBranding.neutralGreen, _green)]) {
        await tester.pumpWidget(MaterialApp(
          home: TourAnimationView(
            path: path,
            title: 'x',
            showTiles: false,
            autoplay: false,
            truckModel: TruckModel(branding: branding),
          ),
        ));
        final icon = tester.widget<Icon>(
            find.descendant(of: find.byKey(const Key('tour-vehicle')), matching: find.byIcon(Icons.local_shipping)));
        expect(icon.color, color);
      }
      await tester.pumpWidget(const SizedBox());
    });
  });
}
