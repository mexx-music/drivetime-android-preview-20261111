// Persönlicher Tourtitel: Bereinigung, lokaler Speicher, Filmspezifikation,
// Darstellung in Intro/Outro, Studio-Export. App-Abläufe (Eingabe →
// Animation/Live-Aufnahme) stehen in tour_animation_test.dart.

import 'dart:convert';

import 'package:driverroute_eta/animation/cinematic_camera.dart' show CameraMode;
import 'package:driverroute_eta/animation/tour_outro.dart';
import 'package:driverroute_eta/animation/tour_path.dart';
import 'package:driverroute_eta/animation/tour_story.dart';
import 'package:driverroute_eta/export/film_spec.dart';
import 'package:driverroute_eta/export/film_view.dart';
import 'package:driverroute_eta/export/studio_export_backend.dart';
import 'package:driverroute_eta/export/video_export_preset.dart';
import 'package:driverroute_eta/logic/eta_calculator.dart';
import 'package:driverroute_eta/services/map_launcher.dart' show RouteMapPlan;
import 'package:driverroute_eta/services/personal_title_store.dart';
import 'package:driverroute_eta/ui/map_osm_view.dart' show MapSegment;
import 'package:driverroute_eta/ui/tour_animation_scene_maplibre.dart';
import 'package:driverroute_eta/ui/tour_animation_view.dart';
import 'package:driverroute_eta/ui/tour_outro_overlay.dart';
import 'package:driverroute_eta/ui/tour_story_overlay.dart';
import 'package:driverroute_eta/ui/truck_sprites.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:latlong2/latlong.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Film-IDs, berechnet mit dem Code VOR dieser Änderung (Stand 8a182db):
/// Ohne persönlichen Titel müssen sie gleich bleiben.
const _goldenBlue = 'c62dbfa7c667b7cc1ae7609c';
const _goldenGreen = 'b433b89ad7f905f1aa37722b';

/// 40 Zeichen ohne Leerzeichen – das härteste Wort für Intro/Outro.
const _longWord = 'Donaudampfschifffahrtsgesellschaftskapit';

TourFilmSpec _spec({String? personalTitle, String truck = 'neutral'}) {
  final t0 = DateTime.utc(2026, 10, 10, 6);
  final pts = [for (var i = 0; i <= 20; i++) LatLng(48.09 + (53.55 - 48.09) * i / 20, 13.87 + (9.99 - 13.87) * i / 20)];
  return TourFilmSpec(
    plan: RouteMapPlan.restored(
        start: pts.first, dest: pts.last, segments: [MapSegment(points: pts, label: 'L')], stops: const [], subtitle: 'S'),
    eta: EtaResult([
      EtaStep('Start', type: EtaEventType.start, start: t0, end: t0),
      EtaStep('Ziel', type: EtaEventType.destination, start: t0.add(const Duration(hours: 8)), end: t0.add(const Duration(hours: 8))),
    ], t0.add(const Duration(hours: 8))),
    title: 'Lambach → Hamburg',
    fromName: 'Lambach',
    toName: 'Hamburg',
    timeZone: 'Europe/Vienna',
    truckBranding: truck,
    personalTitle: personalTitle,
  );
}

List<LatLng> _line(LatLng a, LatLng b, int n) => [
      for (var i = 0; i <= n; i++)
        LatLng(a.latitude + (b.latitude - a.latitude) * i / n, a.longitude + (b.longitude - a.longitude) * i / n),
    ];

const _sizes = [
  Size(360, 640),
  Size(390, 844),
  Size(540, 960),
  Size(1080, 1920),
  Size(1280, 720), // Desktop quer
];

Future<void> _setSize(WidgetTester tester, Size size) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  addTearDown(tester.view.reset);
}

void main() {
  group('Bereinigung', () {
    test('leer, nur Leerraum oder null → kein Titel', () {
      expect(sanitizePersonalTitle(null), isNull);
      expect(sanitizePersonalTitle(''), isNull);
      expect(sanitizePersonalTitle('   \n\t  '), isNull);
    });

    test('Trim, Leerraum zusammengefasst, Zeilenumbrüche und Steuerzeichen entfernt', () {
      expect(sanitizePersonalTitle('  Manfreds Tour  '), 'Manfreds Tour');
      expect(sanitizePersonalTitle('Manfreds\nTour'), 'Manfreds Tour');
      expect(sanitizePersonalTitle('Manfreds\r\n\tTour\u0007'), 'Manfreds Tour');
      expect(sanitizePersonalTitle('Unterwegs   mit    Andi'), 'Unterwegs mit Andi');
      expect(sanitizePersonalTitle('A\u2028B\u2029C'), 'A B C');
      // Bidi-Steuerzeichen könnten die Anzeige umdrehen.
      expect(sanitizePersonalTitle('\u202EruoT\u202C'), 'ruoT');
      expect(sanitizePersonalTitle('\uFEFFTour'), 'Tour');
    });

    test('höchstens 40 sichtbare Zeichen (Graphem-Cluster)', () {
      expect(sanitizePersonalTitle('a' * 41)!.length, 40);
      expect(sanitizePersonalTitle('ä' * 50), 'ä' * 40);
      // Familie-Emoji: mehrere Codepunkte, aber ein sichtbares Zeichen.
      const family = '👨\u200D👩\u200D👧';
      expect(sanitizePersonalTitle(family * 45), family * 40);
      // Nach dem Kürzen kein Leerzeichen am Ende.
      expect(sanitizePersonalTitle('${'x' * 39} yyyy'), 'x' * 39);
      expect(sanitizePersonalTitle(_longWord), _longWord);
      expect(_longWord.length, 40);
    });

    test('Unicode bleibt erhalten; kein HTML, kein Rich Text', () {
      for (final t in [
        'Meine Tour nach Wien',
        'Nachttour Ancona–Wien',
        'Şoförün Turu · Ğıda İhracatı',
        'Călătoria lui Ion spre Brașov',
        'Пътуване до София',
        'Ελληνική διαδρομή',
        'Øresund – Malmö – Göteborg',
        'Łódź → Kraków',
      ]) {
        expect(sanitizePersonalTitle(t), t);
      }
      expect(sanitizePersonalTitle('<b>Andi</b> & <i>Co</i>'), '<b>Andi</b> & <i>Co</i>');
    });
  });

  group('Speicher', () {
    test('Standard leer; speichern, wiederherstellen, entfernen', () async {
      SharedPreferences.setMockInitialValues({});
      expect(await PersonalTitleStore.load(), isNull);
      await PersonalTitleStore.save('  Manfreds Tour \n');
      expect(await PersonalTitleStore.load(), 'Manfreds Tour');
      expect((await SharedPreferences.getInstance()).getString(PersonalTitleStore.key), 'Manfreds Tour');
      await PersonalTitleStore.save('');
      expect(await PersonalTitleStore.load(), isNull);
      expect((await SharedPreferences.getInstance()).containsKey(PersonalTitleStore.key), isFalse);
      await PersonalTitleStore.save('Unterwegs mit Andi');
      await PersonalTitleStore.save(null);
      expect(await PersonalTitleStore.load(), isNull);
    });

    test('gespeicherter Wert wird beim Laden nochmals bereinigt', () async {
      SharedPreferences.setMockInitialValues({PersonalTitleStore.key: 'Zeile1\nZeile2'});
      expect(await PersonalTitleStore.load(), 'Zeile1 Zeile2');
    });
  });

  group('Filmspezifikation', () {
    test('ohne Titel: Film-IDs exakt wie vor der Änderung (Blau und Grün)', () {
      expect(_spec().filmId, _goldenBlue);
      expect(_spec(truck: 'neutral-green').filmId, _goldenGreen);
      expect(_spec().toJson().containsKey('personalTitle'), isFalse);
    });

    test('mit Titel: eigene, stabile Film-ID', () {
      final a = _spec(personalTitle: 'Manfreds Tour');
      expect(a.filmId, isNot(_goldenBlue));
      expect(a.filmId, _spec(personalTitle: 'Manfreds Tour').filmId);
      expect(a.filmId, isNot(_spec(personalTitle: 'Andis Tour').filmId));
    });

    test('JSON hin und zurück – mit und ohne Titel, Unicode erhalten', () {
      for (final t in [null, 'Manfreds Tour', 'Şoförün Turu · Ğıda', 'Пътуване до София']) {
        final s = _spec(personalTitle: t);
        final again = TourFilmSpec.fromJson(jsonDecode(jsonEncode(s.toJson())) as Map<String, dynamic>);
        expect(again.personalTitle, t);
        expect(again.filmId, s.filmId);
      }
      expect(_spec(personalTitle: 'x').copyWith(format: FilmFormat.portrait9x16).personalTitle, 'x');
    });

    test('alte Spezifikation ohne neues Feld bleibt lesbar (inkl. Kennungsprüfung)', () {
      final old = _spec().toJson()..remove('personalTitle');
      expect(old['filmId'], _goldenBlue);
      final spec = TourFilmSpec.fromJson(jsonDecode(jsonEncode(old)) as Map<String, dynamic>);
      expect(spec.personalTitle, isNull);
      expect(spec.filmId, _goldenBlue);
    });

    test('Film zur Spezifikation trägt den Titel (Animation, Live-Aufnahme, Export) – nie auf dem Auflieger', () {
      for (final truck in ['neutral', 'neutral-green', 'gartner-test']) {
        final spec = _spec(personalTitle: 'Manfreds Tour', truck: truck);
        for (final export in [false, true]) {
          final view = filmViewFor(spec, path: filmPathFor(spec)!, videoExport: export) as TourAnimationView;
          expect(view.personalTitle, 'Manfreds Tour');
          // Branding unverändert: Titel landet nicht in der Beschriftung.
          expect(view.truckModel.branding, same(truckBrandingById(truck)));
          expect(view.truckModel.branding.sideText, truck == 'gartner-test' ? 'GARTNER' : isNull);
        }
      }
      final none = filmViewFor(_spec(), path: filmPathFor(_spec())!, videoExport: false) as TourAnimationView;
      expect(none.personalTitle, isNull);
    });

    test('Studio-Export erhält denselben Titel; keine weiteren HTTP-Aufrufe', () async {
      final calls = <String>[];
      Map<String, dynamic>? sent;
      final backend = StudioExportBackend(
        baseUrl: Uri.parse('http://studio.test/'),
        client: MockClient((r) async {
          calls.add(r.url.path);
          sent = jsonDecode(r.body) as Map<String, dynamic>;
          return http.Response('{"jobId":"j1"}', 202);
        }),
      );
      await backend.start(_spec(personalTitle: 'Unterwegs mit Andi'), VideoExportPreset.controlPreview);
      expect(calls, ['/api/export']); // nur der Exportauftrag selbst
      final spec = TourFilmSpec.fromJson(sent!['spec'] as Map<String, dynamic>);
      expect(spec.personalTitle, 'Unterwegs mit Andi');
      final view = filmViewFor(spec, path: filmPathFor(spec)!, videoExport: true) as TourAnimationView;
      expect(view.personalTitle, 'Unterwegs mit Andi');
    });
  });

  group('Outro (2.5D)', () {
    OutroData data({String? title}) => OutroData(
          from: 'Ancona',
          to: 'Wien',
          km: 1043,
          days: 2,
          countries: const [OutroCountry('IT', 'Italien'), OutroCountry('SI', 'Slowenien'), OutroCountry('AT', 'Österreich')],
          ferries: 0,
          personalTitle: title,
        );
    final tl = OutroTimeline(countryCount: 3);

    Future<void> pumpOutro(WidgetTester tester, OutroData d, {double? t}) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(body: TourOutroOverlay(data: d, timeline: tl, t: t ?? tl.end)),
      ));
    }

    testWidgets('Titel genau einmal, über der unveränderten DriveTime-Signatur', (tester) async {
      await _setSize(tester, const Size(540, 960));
      await pumpOutro(tester, data(title: 'Manfreds Tour'));
      expect(find.byKey(const Key('outro-personal-title')), findsOneWidget);
      expect(find.text('Manfreds Tour'), findsOneWidget);
      expect(find.byKey(const Key('outro-signature')), findsOneWidget);
      expect(find.text('DriveTime'), findsOneWidget);
      final title = tester.getRect(find.byKey(const Key('outro-personal-title')));
      final sig = tester.getRect(find.byKey(const Key('outro-signature')));
      expect(title.bottom, lessThanOrEqualTo(sig.top)); // darüber
      expect(title.right, closeTo(sig.right, 1)); // rechtsbündig mit der Signatur
      // Start, Ziel, Entfernung bleiben sichtbar.
      expect(find.byKey(const Key('outro-route')), findsOneWidget);
      expect(find.byKey(const Key('outro-km')), findsOneWidget);
      // Keine eigene Formulierung zum Titel.
      expect(find.textContaining('Manfreds Tour abgeschlossen'), findsNothing);
    });

    testWidgets('ohne Titel: Outro wie bisher', (tester) async {
      await _setSize(tester, const Size(540, 960));
      await pumpOutro(tester, data());
      expect(find.byKey(const Key('outro-personal-title')), findsNothing);
      expect(find.byKey(const Key('outro-signature')), findsOneWidget);
    });

    testWidgets('kein Überlauf auf allen Größen – auch mit 40-Zeichen-Wort und Unicode', (tester) async {
      for (final size in _sizes) {
        for (final title in [_longWord, 'Şoförün Turu · Călătoria lui Ion', 'Пътуване до София']) {
          await _setSize(tester, size);
          await pumpOutro(tester, data(title: title));
          expect(tester.takeException(), isNull, reason: '$size / $title');
          final r = tester.getRect(find.byKey(const Key('outro-personal-title')));
          expect(r.left, greaterThanOrEqualTo(0), reason: '$size');
          expect(r.right, lessThanOrEqualTo(size.width), reason: '$size');
        }
      }
    });
  });

  group('Abschlusskarte (2D)', () {
    TourFrame arrival() => const TourFrame(
          meters: 1000,
          event: TourStoryEvent(kind: TourStoryKind.arrival, meters: 1000, km: 1),
          eventProgress: 1,
        );

    testWidgets('Titel genau einmal, kein Überlauf', (tester) async {
      for (final size in _sizes) {
        for (final title in ['Manfreds Tour', _longWord]) {
          await _setSize(tester, size);
          await tester.pumpWidget(MaterialApp(
            home: Scaffold(
              body: TourStoryOverlay(frame: arrival(), fromName: 'Ancona', toName: 'Wien', personalTitle: title),
            ),
          ));
          expect(find.byKey(const Key('arrival-personal-title')), findsOneWidget);
          expect(find.text(title), findsOneWidget);
          expect(tester.takeException(), isNull, reason: '$size / $title');
        }
      }
      await tester.pumpWidget(MaterialApp(
          home: Scaffold(body: TourStoryOverlay(frame: arrival(), fromName: 'Ancona', toName: 'Wien'))));
      expect(find.byKey(const Key('arrival-personal-title')), findsNothing);
    });
  });

  group('Intro in der Touranimation', () {
    final path = TourPath([TourLeg(points: _line(const LatLng(43.62, 13.50), const LatLng(48.21, 16.37), 300))]);
    final total = tourAnimationDuration(path.totalMeters);

    Future<void> pumpView(WidgetTester tester, Size size, {String? title, bool in25D = false, bool clean = false}) async {
      await _setSize(tester, size);
      await tester.pumpWidget(MaterialApp(
        home: TourAnimationView(
          path: path,
          title: 'Ancona → Wien',
          fromName: 'Ancona',
          toName: 'Wien',
          showTiles: false,
          startIn25D: in25D,
          cameraMode: in25D ? CameraMode.cinematic : CameraMode.follow,
          truckView: in25D ? TruckView.articulated : TruckView.top,
          cleanRecording: clean,
          personalTitle: title,
        ),
      ));
      await tester.pump();
    }

    testWidgets('Titel genau einmal unter der Fahrleiste, nach dem Intro wieder weg', (tester) async {
      await pumpView(tester, const Size(390, 844), title: 'Manfreds Tour');
      await tester.pump(const Duration(seconds: 1));
      expect(find.byKey(const Key('intro-personal-title')), findsOneWidget);
      expect(find.text('Manfreds Tour'), findsOneWidget);
      // Route bleibt sichtbar (HUD oben), Titel liegt darunter.
      expect(find.text('Ancona → Wien'), findsOneWidget);
      final hud = tester.getRect(find.byKey(const Key('tour-km')));
      final intro = tester.getRect(find.byKey(const Key('intro-personal-title')));
      expect(intro.top, greaterThan(hud.top));
      await tester.pump(const Duration(seconds: 6));
      expect(find.byKey(const Key('intro-personal-title')), findsNothing);
      await tester.pump(total * 2);
      await tester.pump(const Duration(seconds: 1));
    });

    testWidgets('ohne Titel: kein Intro-Element', (tester) async {
      await pumpView(tester, const Size(390, 844));
      await tester.pump(const Duration(seconds: 1));
      expect(find.byKey(const Key('intro-personal-title')), findsNothing);
      await tester.pump(total * 2);
      await tester.pump(const Duration(seconds: 1));
    });

    testWidgets('kein Überlauf auf allen Größen, 2D und 2.5D, auch im sauberen Aufnahmemodus', (tester) async {
      for (final size in _sizes) {
        for (final in25D in [false, true]) {
          await pumpView(tester, size, title: _longWord, in25D: in25D, clean: in25D);
          await tester.pump(const Duration(milliseconds: 500));
          expect(tester.takeException(), isNull, reason: '$size 2.5D=$in25D');
          await tester.pumpWidget(const SizedBox());
        }
      }
    });

    testWidgets('2.5D: Outro-Daten tragen den Titel; der Truck bleibt unbeschriftet', (tester) async {
      await pumpView(tester, const Size(540, 960), title: 'Nachttour Ancona–Wien', in25D: true);
      final scene = tester.widget<TourAnimationSceneMapLibre>(find.byType(TourAnimationSceneMapLibre));
      expect(scene.outro?.personalTitle, 'Nachttour Ancona–Wien');
      expect(scene.truckModel.branding.sideText, isNull);
      expect(scene.truckModel.branding.rearText, isNull);
      await tester.pumpWidget(const SizedBox());
    });
  });
}
