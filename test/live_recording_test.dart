// Live-Aufnahme der Touranimation im Browser („Tour live aufnehmen“).
// Alle Browser-APIs sind über [FakeTabCaptureApi] simuliert – es gibt keine
// echte Bildschirmfreigabe im Test.

import 'dart:async';
import 'dart:typed_data';

import 'package:driverroute_eta/animation/cinematic_camera.dart' show CameraMode;
import 'package:driverroute_eta/animation/tour_path.dart';
import 'package:driverroute_eta/export/live_recording/live_recording_controller.dart';
import 'package:driverroute_eta/export/live_recording/live_recording_panel.dart';
import 'package:driverroute_eta/export/live_recording/tab_capture.dart';
import 'package:driverroute_eta/export/live_recording/tab_capture_platform.dart' as platform;
import 'package:driverroute_eta/ui/tour_animation_scene_maplibre.dart';
import 'package:driverroute_eta/ui/tour_animation_view.dart';
import 'package:driverroute_eta/ui/truck_sprites.dart' show TruckView;
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:latlong2/latlong.dart';

import 'helpers/fake_tab_capture.dart';

Future<void> _flush() async {
  for (var i = 0; i < 20; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

/// Ersatz für „Touranimation öffnen“: zählt Aufrufe, hält die Signale und
/// endet, wenn die Animation geschlossen wird.
class _Animation {
  int opened = 0;
  LiveRecordingSignals? signals;
  Completer<void>? _closed;

  Future<void> open(LiveRecordingSignals s) {
    opened++;
    signals = s;
    _closed = Completer<void>();
    s.closeRequest.addListener(() {
      if (s.closeRequest.value) close();
    });
    return _closed!.future;
  }

  void close() {
    if (_closed != null && !_closed!.isCompleted) _closed!.complete();
  }
}

List<LatLng> _line(LatLng a, LatLng b, int n) => [
      for (var i = 0; i <= n; i++)
        LatLng(a.latitude + (b.latitude - a.latitude) * i / n, a.longitude + (b.longitude - a.longitude) * i / n),
    ];

void main() {
  // =========================================================== reine Regeln
  group('Format und Dateiname', () {
    test('MP4/H.264 wird vor WebM bevorzugt – nur unterstützte Typen', () {
      expect(pickRecordingMimeType((m) => true), 'video/mp4;codecs=avc1');
      // Nur eine bestimmte H.264-Variante: die wird genommen, nicht WebM.
      expect(pickRecordingMimeType({'video/webm;codecs=vp9', 'video/mp4;codecs=avc1.42e01e'}.contains),
          'video/mp4;codecs=avc1.42e01e');
      // Ohne H.264: WebM VP9 vor VP8 vor allgemeinem WebM.
      expect(pickRecordingMimeType({'video/webm;codecs=vp9', 'video/webm', 'video/mp4'}.contains), 'video/webm;codecs=vp9');
      expect(pickRecordingMimeType({'video/webm;codecs=vp8', 'video/webm'}.contains), 'video/webm;codecs=vp8');
      // Allgemeines MP4 (Codec offen) erst nach WebM.
      expect(pickRecordingMimeType({'video/webm', 'video/mp4'}.contains), 'video/webm');
      expect(pickRecordingMimeType({'video/mp4'}.contains), 'video/mp4');
      expect(pickRecordingMimeType((m) => false), isNull);
      // Wirft der Browser bei einem Typ, wird er übersprungen.
      expect(pickRecordingMimeType((m) => m.contains('avc') ? throw StateError('x') : m == 'video/webm'), 'video/webm');
      expect(kRecordingMimeCandidates.indexOf('video/mp4;codecs=avc1'), 0);
      expect(kRecordingMimeCandidates.indexWhere(isWebmMime),
          greaterThan(kRecordingMimeCandidates.lastIndexWhere(isH264Mp4Mime)));
      final asked = <String>[];
      pickRecordingMimeType((m) {
        asked.add(m);
        return false;
      });
      expect(asked, kRecordingMimeCandidates);
    });

    test('Dateiendung folgt dem tatsächlich erzeugten Typ – WebM wird nie MP4', () {
      expect(extensionForMimeType('video/webm;codecs=vp9'), 'webm');
      expect(extensionForMimeType('video/webm'), 'webm');
      expect(extensionForMimeType('VIDEO/MP4; codecs=avc1'), 'mp4');
      expect(extensionForMimeType('video/x-matroska;codecs=avc1'), 'mkv');
      expect(extensionForMimeType('video/ogg'), isNull);
      expect(extensionForMimeType(''), isNull);
    });

    test('Dateiname: drivetime_start-ziel_YYYY-MM-DD_HH-mm.ext, bereinigt', () {
      final at = DateTime(2026, 11, 11, 9, 5);
      expect(recordingFileName(from: 'Lambach', to: 'Hamburg', at: at, extension: 'webm'),
          'drivetime_lambach-hamburg_2026-11-11_09-05.webm');
      expect(recordingFileName(from: 'Köln / Süd', to: 'Göteborg (Hafen)', at: at, extension: 'mp4'),
          'drivetime_koeln-sued-goeteborg-hafen_2026-11-11_09-05.mp4');
      expect(recordingFileName(from: '../../etc', to: 'a\\b:c*?', at: at, extension: 'webm'),
          'drivetime_etc-a-b-c_2026-11-11_09-05.webm');
      expect(recordingFileName(from: null, to: '', at: at, extension: 'webm'), 'drivetime_tour_2026-11-11_09-05.webm');
      expect(sanitizeFileNamePart('x' * 80).length, 40);
      expect(sanitizeFileNamePart('Straße'), 'strasse');
    });

    test('H.264-MP4 erkannt; WebM ist nie H.264-MP4', () {
      expect(isH264Mp4Mime('video/mp4;codecs=avc1'), isTrue);
      expect(isH264Mp4Mime('video/mp4; codecs="avc1.64001F"'), isTrue);
      expect(isH264Mp4Mime('video/mp4'), isFalse); // Codec offen
      expect(isH264Mp4Mime('video/mp4;codecs=vp9'), isFalse);
      expect(isH264Mp4Mime('video/webm;codecs=avc1'), isFalse);
      expect(isH264Mp4Mime('video/x-matroska;codecs=avc1'), isFalse);
      expect(isWebmMime('video/webm;codecs=vp9'), isTrue);
      expect(isWebmMime('video/mp4'), isFalse);
    });

    test('Codec aus dem Dateiinhalt, nicht aus dem Namen', () {
      Uint8List bytes(String s) => Uint8List.fromList([0, 0, 0, 0x18, ...s.codeUnits]);
      expect(detectVideoCodec(bytes('ftypisom....moov....stsd....avc1....avcC'), 'video/mp4'), VideoCodec.h264);
      expect(detectVideoCodec(bytes('ftypisom....moov....vp09....vpcC'), 'video/mp4;codecs=avc1'), VideoCodec.vp9);
      expect(detectVideoCodec(bytes('ftypisom....moov'), 'video/mp4'), VideoCodec.unknown);
      final webm = Uint8List.fromList([0x1A, 0x45, 0xDF, 0xA3, ...'....V_VP9....'.codeUnits]);
      expect(detectVideoCodec(webm, 'video/webm'), VideoCodec.vp9);
      expect(detectVideoCodec(Uint8List.fromList([0x1A, 0x45, 0xDF, 0xA3, ...'V_VP8'.codeUnits]), 'video/webm'),
          VideoCodec.vp8);
    });

    test('nur gültige Videodaten gelten als Datei (WebM/EBML, MP4 mit ftyp-Kopf)', () {
      final webm = Uint8List.fromList([0x1A, 0x45, 0xDF, 0xA3, 0, 0, 0, 0]);
      final mp4 = Uint8List.fromList([0, 0, 0, 0x18, ...'ftypisom'.codeUnits]);
      // MP4 ohne ftyp als erste Box (z. B. moov zuerst) gilt nicht.
      expect(looksLikeRecordedVideo(Uint8List.fromList([0, 0, 0, 0x18, ...'moovxxxx'.codeUnits]), 'video/mp4'), isFalse);
      expect(looksLikeRecordedVideo(Uint8List.fromList([0, 0, 0, 0x18, ...'ftyp'.codeUnits]), 'video/mp4'), isFalse);
      expect(looksLikeRecordedVideo(Uint8List.fromList([0, 0, 0, 4, ...'ftypisom'.codeUnits]), 'video/mp4'), isFalse);
      expect(looksLikeRecordedVideo(webm, 'video/webm;codecs=vp9'), isTrue);
      expect(looksLikeRecordedVideo(mp4, 'video/mp4'), isTrue);
      expect(looksLikeRecordedVideo(webm, 'video/mp4'), isFalse);
      expect(looksLikeRecordedVideo(mp4, 'video/webm'), isFalse);
      expect(looksLikeRecordedVideo(Uint8List(0), 'video/webm'), isFalse);
      expect(looksLikeRecordedVideo(webm, 'video/ogg'), isFalse);
    });
  });

  // ============================================================ Plattform
  group('Plattform', () {
    test('außerhalb des Browsers: nicht unterstützt, Freigabe nicht anfragbar', () async {
      final api = platform.createPlatformTabCaptureApi();
      expect(api.apisAvailable, isFalse);
      expect(api.isTypeSupported('video/webm'), isFalse);
      await expectLater(api.requestDisplay(), throwsA(isA<TabCaptureException>()));
      final c = LiveRecordingController(api: api);
      expect(c.supported, isFalse);
      expect(c.status, LiveRecordingStatus.unsupported);
      c.dispose();
    });

    test('Browser ohne APIs oder ohne passendes Format: nicht unterstützt, kein Start', () async {
      for (final api in [FakeTabCaptureApi(apis: false), FakeTabCaptureApi(types: {'video/ogg'})]) {
        final c = LiveRecordingController(api: api);
        expect(c.status, LiveRecordingStatus.unsupported);
        final anim = _Animation();
        await c.start(openAnimation: anim.open);
        expect(api.requests, 0);
        expect(anim.opened, 0);
        c.dispose();
      }
    });
  });

  // ============================================================ Ablauf
  group('Ablauf', () {
    late FakeTabCaptureApi api;
    late LiveRecordingController c;
    late _Animation anim;

    setUp(() {
      api = FakeTabCaptureApi();
      c = LiveRecordingController(api: api, postRoll: Duration.zero);
      anim = _Animation();
    });
    tearDown(() => c.dispose());

    test('Freigabe wird synchron im Klick angefragt (vor jedem await)', () {
      unawaited(c.start(openAnimation: anim.open));
      expect(api.requests, 1); // ohne einen einzigen Event-Loop-Durchlauf
      expect(c.status, LiveRecordingStatus.requesting);
    });

    test('Freigabe abgelehnt → keine Animation, keine Aufnahme; neuer Versuch möglich', () async {
      final run = c.start(openAnimation: anim.open);
      api.deny();
      await run;
      expect(c.status, LiveRecordingStatus.cancelled);
      expect(c.userMessage, contains('nicht erteilt'));
      expect(anim.opened, 0);
      expect(api.recordersStarted, 0);
      expect(c.download('x.webm'), isFalse);

      unawaited(c.start(openAnimation: anim.open));
      expect(api.requests, 2);
    });

    test('anderer Freigabefehler → verständliche Meldung, Technik nur in der Diagnose', () async {
      final run = c.start(openAnimation: anim.open);
      api.fail('NotReadableError');
      await run;
      expect(c.status, LiveRecordingStatus.failed);
      expect(c.userMessage, isNot(contains('NotReadableError')));
      expect(c.debugDetail, contains('NotReadableError'));
      expect(anim.opened, 0);
    });

    test('Animation erst nach Freigabe und genau einmal; Aufnahme erst mit der Fahrt', () async {
      unawaited(c.start(openAnimation: anim.open));
      await _flush();
      expect(anim.opened, 0);
      final stream = api.grant();
      await _flush();
      expect(anim.opened, 1);
      expect(c.status, LiveRecordingStatus.recording);
      expect(c.capturing, isFalse); // Karte lädt noch: nichts aufnehmen
      expect(api.recordersStarted, 0);

      anim.signals!.started();
      anim.signals!.started(); // doppelt gemeldet: wirkt nur einmal
      expect(api.recordersStarted, 1);
      expect(stream.recorders.single.mimeType, 'video/webm;codecs=vp9');
      expect(c.capturing, isTrue);
      expect(anim.opened, 1);
    });

    test('Filmende → Nachlauf → Datei bereit; Freigabe beendet, Animation schließt', () async {
      unawaited(c.start(openAnimation: anim.open));
      final stream = api.grant();
      await _flush();
      anim.signals!.started();
      anim.signals!.finished();
      anim.signals!.finished();
      await _flush();
      expect(c.status, LiveRecordingStatus.fileReady);
      expect(c.endedBy, LiveRecordingEnd.filmEnd);
      expect(stream.tracksStopped, isTrue);
      expect(stream.recorders.single.stopped, isTrue);
      expect(api.hiddenListeners, 0);
      expect(anim.signals!.closeRequest.value, isTrue);
      expect(c.videoExtension, 'webm');
      expect(c.download('drivetime_a-b.webm'), isTrue);
      expect(api.videos.single.downloads, ['drivetime_a-b.webm']);
    });

    test('Nachlauf: Aufnahme endet nicht sofort mit dem Filmende', () async {
      final slow = LiveRecordingController(api: api, postRoll: const Duration(milliseconds: 300));
      addTearDown(slow.dispose);
      unawaited(slow.start(openAnimation: anim.open));
      api.grant();
      await _flush();
      anim.signals!.started();
      anim.signals!.finished();
      await _flush();
      expect(slow.status, LiveRecordingStatus.recording);
      await Future<void>.delayed(const Duration(milliseconds: 400));
      await _flush();
      expect(slow.status, LiveRecordingStatus.fileReady);
    });

    test('manuelles Beenden: Teilvideo wird fertiggestellt', () async {
      unawaited(c.start(openAnimation: anim.open));
      final stream = api.grant();
      await _flush();
      anim.signals!.started();
      await c.stop();
      expect(c.status, LiveRecordingStatus.fileReady);
      expect(c.endedBy, LiveRecordingEnd.manual);
      expect(c.userMessage, contains('bis dahin'));
      expect(stream.tracksStopped, isTrue);
    });

    test('Browser beendet die Freigabe: Teilvideo wird kontrolliert fertiggestellt', () async {
      unawaited(c.start(openAnimation: anim.open));
      final stream = api.grant();
      await _flush();
      anim.signals!.started();
      stream.browserEnds();
      await _flush();
      expect(c.status, LiveRecordingStatus.fileReady);
      expect(c.endedBy, LiveRecordingEnd.browser);
      expect(c.userMessage, contains('im Browser beendet'));
      expect(anim.signals!.closeRequest.value, isTrue);
    });

    test('Browser beendet die Freigabe vor Fahrtbeginn: nichts aufgenommen, Animation schließt', () async {
      unawaited(c.start(openAnimation: anim.open));
      final stream = api.grant();
      await _flush();
      stream.browserEnds();
      await _flush();
      expect(c.status, LiveRecordingStatus.cancelled);
      expect(api.recordersStarted, 0);
      expect(stream.tracksStopped, isTrue);
      expect(anim.signals!.closeRequest.value, isTrue);
    });

    test('Animation verlassen (Zurück/Schließen) → abgebrochen, Teilvideo verworfen', () async {
      unawaited(c.start(openAnimation: anim.open));
      final stream = api.grant();
      await _flush();
      anim.signals!.started();
      anim.close();
      await _flush();
      expect(c.status, LiveRecordingStatus.cancelled);
      expect(c.userMessage, contains('verworfen'));
      expect(stream.recorders.single.aborted, isTrue);
      expect(stream.recorders.single.stopped, isFalse); // keine Datei zusammengesetzt
      expect(stream.tracksStopped, isTrue);
      expect(api.videos, isEmpty);
      expect(c.download('x.webm'), isFalse);
    });

    test('Doppelstart während einer Aufnahme wird verhindert', () async {
      unawaited(c.start(openAnimation: anim.open));
      unawaited(c.start(openAnimation: anim.open));
      expect(api.requests, 1);
      api.grant();
      await _flush();
      unawaited(c.start(openAnimation: anim.open));
      expect(api.requests, 1);
      expect(anim.opened, 1);
    });

    test('erneute Aufnahme ohne Neuladen; alte Datei wird freigegeben, alte Signale wirken nicht', () async {
      unawaited(c.start(openAnimation: anim.open));
      api.grant();
      await _flush();
      final first = anim.signals!;
      first.started();
      first.finished();
      await _flush();
      expect(c.status, LiveRecordingStatus.fileReady);
      final firstVideo = api.videos.single;

      unawaited(c.start(openAnimation: anim.open));
      expect(firstVideo.released, isTrue);
      final stream2 = api.grant();
      await _flush();
      expect(anim.opened, 2);
      first.started(); // Signal des alten Versuchs
      expect(stream2.recorders, isEmpty);
      anim.signals!.started();
      anim.signals!.finished();
      await _flush();
      expect(c.status, LiveRecordingStatus.fileReady);
      expect(api.videos, hasLength(2));
    });

    test('Fehler während der Aufnahme → Fehlerzustand, alles freigegeben, neu startbar', () async {
      unawaited(c.start(openAnimation: anim.open));
      final stream = api.grant();
      await _flush();
      anim.signals!.started();
      stream.recorders.single.fail();
      await _flush();
      expect(c.status, LiveRecordingStatus.failed);
      expect(c.userMessage, isNot(contains('UnknownError')));
      expect(stream.tracksStopped, isTrue);
      expect(stream.recorders.single.aborted, isTrue);
      expect(anim.signals!.closeRequest.value, isTrue);
      expect(api.hiddenListeners, 0);
      unawaited(c.start(openAnimation: anim.open));
      expect(api.requests, 2);
    });

    test('leere oder ungültige Aufnahme erzeugt keinen Download', () async {
      for (final make in <RecordedVideo? Function(FakeRecorder)>[
        (_) => null,
        (r) => FakeVideo(r.mimeType, 0),
        (r) => FakeVideo('video/ogg', 5000),
      ]) {
        api.videoFor = make;
        unawaited(c.start(openAnimation: anim.open));
        final stream = api.grant();
        await _flush();
        anim.signals!.started();
        await c.stop();
        expect(c.status, LiveRecordingStatus.failed);
        expect(c.userMessage, contains('keine verwertbaren Videodaten'));
        expect(c.download('x.webm'), isFalse);
        expect(stream.tracksStopped, isTrue);
        for (final v in api.videos) {
          expect(v.released, isTrue);
          expect(v.downloads, isEmpty);
        }
      }
    });

    test('MP4-Browser: Datei heißt .mp4 (H.264), WebM-Browser: .webm', () async {
      final mp4Api = FakeTabCaptureApi(types: {'video/mp4;codecs=avc1', 'video/webm;codecs=vp9'});
      final m = LiveRecordingController(api: mp4Api, postRoll: Duration.zero);
      addTearDown(m.dispose);
      unawaited(m.start(openAnimation: anim.open));
      final s = mp4Api.grant();
      await _flush();
      anim.signals!.started();
      expect(s.recorders.single.mimeType, 'video/mp4;codecs=avc1');
      expect(m.plannedH264Mp4, isTrue);
      await m.stop();
      expect(m.videoExtension, 'mp4');
      expect(m.videoIsH264Mp4, isTrue);

      // Recorder-MIME entscheidet: verlangt MP4, Browser liefert WebM → .webm.
      final liar = FakeTabCaptureApi(types: {'video/mp4;codecs=avc1'})
        ..videoFor = (r) => FakeVideo('video/webm;codecs=vp9', 1000);
      final l = LiveRecordingController(api: liar, postRoll: Duration.zero);
      addTearDown(l.dispose);
      unawaited(l.start(openAnimation: anim.open));
      liar.grant();
      await _flush();
      anim.signals!.started();
      await l.stop();
      expect(l.videoExtension, 'webm');
      expect(l.videoIsH264Mp4, isFalse);

      // WebM-Browser bleibt bei .webm.
      unawaited(c.start(openAnimation: anim.open));
      api.grant();
      await _flush();
      anim.signals!.started();
      await c.stop();
      expect(c.plannedWebmOnly, isTrue);
      expect(c.videoExtension, 'webm');
    });

    test('Größenwechsel während der Aufnahme wird erkannt (MP4 evtl. defekt), sonst nicht', () async {
      final mp4 = FakeTabCaptureApi(types: {'video/mp4;codecs=avc1'});
      final m = LiveRecordingController(api: mp4, postRoll: Duration.zero);
      addTearDown(m.dispose);
      unawaited(m.start(openAnimation: anim.open));
      final s1 = mp4.grant();
      s1.frameSize = '2940x1912'; // Wert vor dem ersten Bild – vor Aufnahmebeginn egal
      await _flush();
      s1.frameSize = '1350x1832';
      anim.signals!.started();
      await m.stop();
      expect(m.frameSizeChanged, isFalse);

      unawaited(m.start(openAnimation: anim.open));
      final s2 = mp4.grant();
      await _flush();
      anim.signals!.started();
      s2.frameSize = '1350x1700';
      await m.stop();
      expect(m.frameSizeChanged, isTrue);
      expect(m.status, LiveRecordingStatus.fileReady); // Datei bleibt, Hinweis zeigt die Karte
    });

    test('verdeckter Tab wird vermerkt (Hinweis auf mögliche Ruckler)', () async {
      unawaited(c.start(openAnimation: anim.open));
      api.grant();
      await _flush();
      anim.signals!.started();
      expect(c.wasHidden, isFalse);
      api.hidePage();
      await c.stop();
      expect(c.wasHidden, isTrue);
      expect(api.hiddenUnsubscribed, 1);
    });

    test('Fenster/Bildschirm statt Tab: Rückfrage; Abbrechen gibt alles frei', () async {
      final asked = <DisplaySurfaceKind>[];
      final run = c.start(
          openAnimation: anim.open,
          confirmSurface: (s) async {
            asked.add(s);
            return false;
          });
      final stream = api.grant(DisplaySurfaceKind.monitor);
      await run;
      expect(asked, [DisplaySurfaceKind.monitor]);
      expect(c.status, LiveRecordingStatus.cancelled);
      expect(stream.tracksStopped, isTrue);
      expect(anim.opened, 0);

      unawaited(c.start(openAnimation: anim.open, confirmSurface: (s) async => true));
      api.grant(DisplaySurfaceKind.window);
      await _flush();
      expect(anim.opened, 1);
      // Tab-Freigabe: keine Rückfrage.
    });

    test('Dispose während der Aufnahme stoppt Spuren und Recorder; danach Datei freigegeben', () async {
      unawaited(c.start(openAnimation: anim.open));
      final stream = api.grant();
      await _flush();
      anim.signals!.started();
      final local = LiveRecordingController(api: api, postRoll: Duration.zero);
      final anim2 = _Animation();
      unawaited(local.start(openAnimation: anim2.open));
      final stream2 = api.grant();
      await _flush();
      anim2.signals!.started();
      await local.stop();
      expect(local.status, LiveRecordingStatus.fileReady);
      local.dispose();
      expect(api.videos.single.released, isTrue);

      c.dispose();
      expect(stream.tracksStopped, isTrue);
      expect(stream.recorders.single.aborted, isTrue);
      expect(stream2.tracksStopped, isTrue);
      expect(anim.signals!.closeRequest.value, isTrue);
      c = LiveRecordingController(api: api); // für tearDown
    });

    test('Aufnahme löst keinen HTTP-, Routen- oder Provider-Aufruf aus', () async {
      var calls = 0;
      await http.runWithClient(() async {
        unawaited(c.start(openAnimation: anim.open));
        api.grant();
        await _flush();
        anim.signals!.started();
        anim.signals!.finished();
        await _flush();
        expect(c.status, LiveRecordingStatus.fileReady);
        c.download('x.webm');
      }, () => MockClient((r) async {
            calls++;
            return http.Response('{}', 500);
          }));
      expect(calls, 0);
    });
  });

  // ============================================================ Oberfläche
  group('Panel', () {
    Future<void> pumpPanel(WidgetTester tester, FakeTabCaptureApi api,
        {bool available = true, Future<void> Function(LiveRecordingHooks)? open}) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: LiveRecordingPanel(
              api: api,
              available: available,
              fromName: 'Lambach',
              toName: 'Hamburg',
              postRoll: Duration.zero,
              openAnimation: open ?? (h) async {},
            ),
          ),
        ),
      ));
    }

    testWidgets('nicht unterstützt: verständlicher Hinweis, keine Startschaltfläche', (tester) async {
      final api = FakeTabCaptureApi(apis: false);
      await pumpPanel(tester, api);
      expect(find.text(kLiveRecordingUnsupportedText), findsOneWidget);
      expect(find.byKey(const Key('live-recording-start')), findsNothing);
    });

    testWidgets('unterstützt: Hinweis vor der Freigabe; Abbrechen fragt nichts an', (tester) async {
      final api = FakeTabCaptureApi();
      await pumpPanel(tester, api);
      await tester.tap(find.byKey(const Key('live-recording-start')));
      await tester.pumpAndSettle();
      expect(find.textContaining('Tab dieser Seite („DriverRoute ETA“) auswählen'), findsOneWidget);
      expect(find.textContaining('„Diesen Tab freigeben“'), findsOneWidget);
      expect(find.textContaining('Freigabe beenden'), findsOneWidget);
      // Nie als garantiert dargestellt.
      expect(find.textContaining('automatisch nur diesen Tab'), findsNothing);
      await tester.tap(find.text('Abbrechen'));
      await tester.pumpAndSettle();
      expect(api.requests, 0);
    });

    testWidgets('nur WebM möglich: Kompatibilitätshinweis vor der Aufnahme (Karte und Dialog)', (tester) async {
      final api = FakeTabCaptureApi(types: {'video/webm;codecs=vp9', 'video/webm'});
      await pumpPanel(tester, api);
      expect(find.byKey(const Key('live-recording-webm-hint')), findsOneWidget);
      expect(find.text(kWebmOnlyHintText), findsOneWidget);
      await tester.tap(find.byKey(const Key('live-recording-start')));
      await tester.pumpAndSettle();
      expect(find.text(kWebmOnlyHintText), findsNWidgets(2)); // Karte + Dialog
      expect(find.textContaining('TikTok-kompatibel'), findsNothing); // kein falsches Versprechen
      expect(api.requests, 0); // Hinweis kommt VOR der Freigabe
    });

    testWidgets('MP4/H.264 möglich: kein WebM-Hinweis, Format genannt; Hochformat-Hinweis vor der Aufnahme',
        (tester) async {
      final api = FakeTabCaptureApi(types: {'video/mp4;codecs=avc1', 'video/webm;codecs=vp9'});
      await pumpPanel(tester, api);
      expect(find.byKey(const Key('live-recording-webm-hint')), findsNothing);
      await tester.tap(find.byKey(const Key('live-recording-start')));
      await tester.pumpAndSettle();
      expect(find.text('Dieser Browser speichert die Aufnahme als MP4 (H.264).'), findsOneWidget);
      expect(find.text(kWebmOnlyHintText), findsNothing);
      expect(find.byKey(const Key('live-recording-portrait-hint')), findsOneWidget);
      expect(find.text(kPortraitHintText), findsOneWidget);
      expect(api.requests, 0);
    });

    testWidgets('fertige WebM-Datei: ehrlicher Hinweis, keine MP4-Bezeichnung', (tester) async {
      final api = FakeTabCaptureApi(types: {'video/webm;codecs=vp9'});
      await pumpPanel(tester, api, open: (h) async {
        h.onPlaybackStarted();
        h.onPlaybackFinished();
        await Future<void>.delayed(const Duration(milliseconds: 10));
      });
      await tester.tap(find.byKey(const Key('live-recording-start')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('live-recording-confirm')));
      await tester.pump();
      api.grant();
      await tester.pumpAndSettle();
      expect(find.textContaining('WebM (VP9)'), findsOneWidget);
      expect(find.textContaining('MP4 (H.264)'), findsNothing);
      expect(find.byKey(const Key('live-recording-compat-note')), findsOneWidget);
    });

    testWidgets('Freigabe auswählen → abgelehnt: Meldung, keine Animation, erneut startbar', (tester) async {
      final api = FakeTabCaptureApi();
      var opened = 0;
      await pumpPanel(tester, api, open: (h) async => opened++);
      await tester.tap(find.byKey(const Key('live-recording-start')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('live-recording-confirm')));
      await tester.pump();
      expect(api.requests, 1); // direkt im Klick
      expect(find.text('Warte auf die Freigabe im Browser …'), findsOneWidget);
      expect(tester.widget<FilledButton>(find.byKey(const Key('live-recording-start'))).onPressed, isNull);
      api.deny();
      await tester.pumpAndSettle();
      expect(opened, 0);
      expect(find.textContaining('nicht erteilt'), findsOneWidget);
      expect(tester.widget<FilledButton>(find.byKey(const Key('live-recording-start'))).onPressed, isNotNull);
    });

    testWidgets('fertig: „Video herunterladen“ mit passendem Dateinamen', (tester) async {
      final api = FakeTabCaptureApi();
      await pumpPanel(tester, api, open: (h) async {
        h.onPlaybackStarted();
        h.onPlaybackFinished();
        await Future<void>.delayed(const Duration(milliseconds: 10));
      });
      await tester.tap(find.byKey(const Key('live-recording-start')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('live-recording-confirm')));
      await tester.pump();
      api.grant();
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('live-recording-download')), findsOneWidget);
      expect(find.textContaining('WebM'), findsWidgets);
      await tester.tap(find.byKey(const Key('live-recording-download')));
      expect(api.videos.single.downloads.single, matches(RegExp(r'^drivetime_lambach-hamburg_\d{4}-\d{2}-\d{2}_\d{2}-\d{2}\.webm$')));
      // Panel verschwindet → alles freigegeben.
      await tester.pumpWidget(const SizedBox());
      expect(api.videos.single.released, isTrue);
    });
  });

  // ================================================= Animation, sauberer Modus
  group('Touranimation im sauberen Aufnahmemodus', () {
    final path = TourPath([
      TourLeg(points: _line(const LatLng(48.09, 13.87), const LatLng(53.55, 9.99), 400)),
    ]);
    final total = tourAnimationDuration(path.totalMeters);

    Future<void> pumpView(WidgetTester tester, {required bool clean, VoidCallback? started, VoidCallback? finished,
        ValueNotifier<bool>? close, bool in25D = false}) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(1000, 1400);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      await tester.pumpWidget(MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: TextButton(
                onPressed: () => Navigator.of(context).push(MaterialPageRoute(
                  builder: (_) => TourAnimationView(
                    path: path,
                    title: 'Lambach → Hamburg',
                    showTiles: false,
                    startIn25D: in25D,
                    cameraMode: in25D ? CameraMode.cinematic : CameraMode.follow,
                    truckView: in25D ? TruckView.articulated : TruckView.top,
                    cleanRecording: clean,
                    onPlaybackStarted: started,
                    onPlaybackFinished: finished,
                    closeRequest: close,
                  ),
                )),
                child: const Text('öffnen'),
              ),
            ),
          ),
        ),
      ));
      await tester.tap(find.text('öffnen'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
    }

    void expectNoControls() {
      expect(find.byType(AppBar), findsNothing);
      expect(find.byTooltip('Schließen'), findsNothing);
      expect(find.byKey(const Key('renderer-switch')), findsNothing);
      expect(find.text('2D'), findsNothing);
      expect(find.text('Pause'), findsNothing);
      expect(find.text('Start'), findsNothing);
      expect(find.text('Weiter'), findsNothing);
      expect(find.text('Neustart'), findsNothing);
      for (final s in ['1×', '2×', '4×']) {
        expect(find.text(s), findsNothing);
      }
      expect(find.byTooltip('Näher heran'), findsNothing);
      expect(find.byTooltip('Weiter weg'), findsNothing);
      expect(find.byKey(const Key('tour-zoom-auto')), findsNothing);
    }

    testWidgets('blendet alle Bedienelemente aus; HUD und Kartenquellenangabe bleiben', (tester) async {
      await pumpView(tester, clean: true);
      expectNoControls();
      expect(find.byKey(const Key('tour-km')), findsOneWidget);
      expect(find.byKey(const Key('tour-progress')), findsOneWidget);
      expect(find.byKey(const Key('tour-vehicle')), findsOneWidget);
      expect(find.byType(RichAttributionWidget), findsOneWidget);
      // Zum Ende fahren, damit kein Ticker offen bleibt.
      await tester.pump(total * 2);
      await tester.pump(const Duration(seconds: 1));
      expectNoControls(); // auch am Filmende kein „Start“
    });

    for (final size in const [Size(360, 640), Size(540, 960), Size(1080, 1920)]) {
      for (final in25D in const [false, true]) {
        testWidgets('9:16 (${size.width.toInt()}×${size.height.toInt()}, ${in25D ? '2.5D' : '2D'}): '
            'ohne Bedienelemente, HUD vollständig im Bild', (tester) async {
          await pumpView(tester, clean: true, in25D: in25D);
          tester.view.physicalSize = size;
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 100));
          expect(tester.takeException(), isNull); // kein Überlauf, kein Layoutfehler
          expectNoControls();
          final screen = Offset.zero & size;
          for (final key in const ['tour-hud', 'tour-km', 'tour-progress']) {
            final f = find.byKey(Key(key));
            if (f.evaluate().isEmpty) continue;
            final r = tester.getRect(f.first);
            expect(screen.contains(r.topLeft) && screen.contains(r.bottomRight - const Offset(0.01, 0.01)), isTrue,
                reason: '$key liegt bei $r außerhalb von $screen');
          }
          expect(find.byKey(const Key('tour-hud')).evaluate().isNotEmpty || find.byKey(const Key('tour-km')).evaluate().isNotEmpty,
              isTrue);
          if (!in25D) expect(find.byType(RichAttributionWidget), findsOneWidget);
          await tester.pumpWidget(const SizedBox());
        });
      }
    }

    testWidgets('normale Touranimation behält alle Bedienelemente', (tester) async {
      await pumpView(tester, clean: false);
      expect(find.byType(AppBar), findsOneWidget);
      expect(find.byTooltip('Schließen'), findsOneWidget);
      expect(find.byKey(const Key('renderer-switch')), findsOneWidget);
      expect(find.text('Pause'), findsOneWidget);
      expect(find.text('Neustart'), findsOneWidget);
      for (final s in ['1×', '2×', '4×']) {
        expect(find.text(s), findsOneWidget);
      }
      expect(find.byTooltip('Näher heran'), findsOneWidget);
      expect(find.byTooltip('Weiter weg'), findsOneWidget);
      await tester.tap(find.text('4×'));
      await tester.pump();
      await tester.pump(total);
      await tester.pump(const Duration(seconds: 1));
      expect(find.text('Start'), findsOneWidget);
      await tester.tap(find.byTooltip('Schließen'));
      await tester.pumpAndSettle();
      expect(find.byType(TourAnimationView), findsNothing);
    });

    testWidgets('Start- und Ende-Signal genau einmal; Filmende ohne Bedienleiste; Schließwunsch schließt',
        (tester) async {
      var started = 0, finished = 0;
      final close = ValueNotifier<bool>(false);
      await pumpView(tester, clean: true, started: () => started++, finished: () => finished++, close: close);
      expect(started, 1);
      expect(finished, 0);
      await tester.pump(total ~/ 2);
      expect(finished, 0);
      await tester.pump(total);
      await tester.pump(const Duration(seconds: 2));
      expect(started, 1);
      expect(finished, 1);
      // Abspielen in Echtzeit (1×): nach Gesamtdauer wirklich fertig.
      final progress = tester.widget<LinearProgressIndicator>(find.byKey(const Key('tour-progress'))).value;
      expect(progress, 1);
      close.value = true;
      await tester.pumpAndSettle();
      expect(find.byType(TourAnimationView), findsNothing);
      expect(finished, 1);
    });

    testWidgets('Live-Aufnahme läuft fest mit 1×: Dauer wie normale Wiedergabe', (tester) async {
      var finished = 0;
      await pumpView(tester, clean: true, finished: () => finished++);
      await tester.pump(total - const Duration(milliseconds: 500));
      expect(finished, 0); // bei 2× oder 4× wäre es längst vorbei
      await tester.pump(const Duration(seconds: 2));
      expect(finished, 1);
    });

    testWidgets('schon beendete Aufnahme: Ansicht schließt sich gleich wieder', (tester) async {
      final close = ValueNotifier<bool>(true);
      await pumpView(tester, clean: true, close: close);
      await tester.pumpAndSettle();
      expect(find.byType(TourAnimationView), findsNothing);
    });

    testWidgets('2.5D-Film: dieselbe Szene samt HUD und Outro wie bei „Tour animieren“', (tester) async {
      TourAnimationSceneMapLibre scene() =>
          tester.widget<TourAnimationSceneMapLibre>(find.byType(TourAnimationSceneMapLibre));
      await pumpView(tester, clean: false, in25D: true);
      final normal = scene();
      await tester.pumpWidget(const SizedBox());
      await pumpView(tester, clean: true, in25D: true);
      final clean = scene();
      expectNoControls();
      expect(clean.outro != null, normal.outro != null);
      expect(clean.outroTimeline?.duration, normal.outroTimeline?.duration);
      expect(clean.quality, normal.quality);
      expect(clean.cameraMode, normal.cameraMode);
      expect(clean.frameDt, isNull); // Echtzeit, nicht der Bild-für-Bild-Export
      expect(clean.cameraDebug, isFalse);
      await tester.pumpWidget(const SizedBox());
    });
  });
}
