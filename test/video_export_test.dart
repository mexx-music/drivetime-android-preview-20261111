import 'dart:convert';
import 'dart:io';

import 'package:driverroute_eta/export/film_spec.dart';
import 'package:driverroute_eta/export/film_view.dart';
import 'package:driverroute_eta/export/studio_export_backend.dart';
import 'package:driverroute_eta/export/video_export_entitlement.dart';
import 'package:driverroute_eta/export/video_export_job.dart';
import 'package:driverroute_eta/export/video_export_preset.dart';
import 'package:driverroute_eta/logic/eta_calculator.dart';
import 'package:driverroute_eta/services/map_launcher.dart';
import 'package:driverroute_eta/ui/map_osm_view.dart' show MapSegment;
import 'package:driverroute_eta/ui/tour_animation_view.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:latlong2/latlong.dart';

// Kleine Fährtour als Testfilm: Landweg, Seeweg, Landweg, ein Stopp.
TourFilmSpec _spec({FilmFormat format = FilmFormat.landscape16x9, double shift = 0}) {
  final t0 = DateTime.utc(2026, 10, 10, 6).toLocal();
  return TourFilmSpec(
    plan: RouteMapPlan.restored(
      start: LatLng(56.36 + shift, 8.62),
      dest: const LatLng(38.06, 23.59),
      segments: [
        MapSegment(points: [LatLng(56.36 + shift, 8.62), const LatLng(50.0, 11.0), const LatLng(43.62, 13.50)], label: 'Anfahrt → Ancona'),
        const MapSegment(points: [LatLng(43.62, 13.50), LatLng(40.3, 19.0), LatLng(38.24, 21.72)], label: 'Ancona–Patras', isFerry: true),
        const MapSegment(points: [LatLng(38.24, 21.72), LatLng(38.06, 23.59)], label: 'Patras → Ziel'),
      ],
      stops: const [LatLng(50.0, 11.0)],
      subtitle: 'Fährroute',
    ),
    eta: EtaResult(
      [
        EtaStep('Start', type: EtaEventType.start, start: t0, end: t0),
        EtaStep('Fahrt', type: EtaEventType.drive, title: 'Fahrt', start: t0, end: t0.add(const Duration(hours: 4, minutes: 30)), distanceKm: 360),
        EtaStep('Pause', type: EtaEventType.breakTime, start: t0.add(const Duration(hours: 4, minutes: 30)), end: t0.add(const Duration(hours: 5, minutes: 15))),
        EtaStep('Fähre', type: EtaEventType.ferry, detail: 'Superfast', start: t0.add(const Duration(hours: 20)), end: t0.add(const Duration(hours: 42)), restSatisfied: true),
        EtaStep('Ziel', type: EtaEventType.destination, start: t0.add(const Duration(hours: 46)), end: t0.add(const Duration(hours: 46))),
        const EtaStep('intern', technical: true),
      ],
      t0.add(const Duration(hours: 46)),
      summary: const EtaSummary(
        distanceKm: 2217, averageKmh: 72.5, drivingMinutes: 1830, breakMinutes: 180, restMinutes: 660,
        waitingMinutes: 40, ferryMinutes: 1320, ferryRestMinutes: 660, tankMinutes: 0, tenHourDaysUsed: 1, reducedDailyRestsUsed: 0),
    ),
    title: 'Holstebro → Aspropyrgos',
    fromName: 'Holstebro',
    toName: 'Aspropyrgos',
    format: format,
    timeZone: 'Europe/Vienna',
  );
}

/// Exportdienst zum Testen: zählt Aufrufe, Ablauf frei einstellbar.
class _FakeBackend implements VideoExportBackend {
  _FakeBackend({this.failStarts = 0, this.steps = const ['rendering', 'rendering', 'encoding', 'ready']});
  int failStarts;
  final List<String> steps;
  int starts = 0, cancels = 0, polls = 0;
  final presets = <VideoExportPreset>[];
  @override
  Future<bool> available() async => true;
  @override
  Future<Map<VideoExportPreset, bool>> entitlements(String filmId) async => {VideoExportPreset.controlPreview: true, VideoExportPreset.fullHD: false};
  @override
  Future<String> start(TourFilmSpec spec, VideoExportPreset preset) async {
    starts++;
    presets.add(preset);
    if (failStarts > 0) {
      failStarts--;
      throw const VideoExportException('Der Export konnte nicht gestartet werden.', 'chrome missing');
    }
    return 'job$starts';
  }
  @override
  Future<VideoExportProgress> status(String jobId) async {
    final s = steps[polls.clamp(0, steps.length - 1)];
    polls++;
    return VideoExportProgress(status: VideoExportStatus.values.byName(s), framesDone: polls, framesTotal: 4, bytes: s == 'ready' ? 1234 : null,
        error: s == 'failed' ? 'Der Export ist fehlgeschlagen. Bitte erneut versuchen.' : null, detail: s == 'failed' ? 'ffmpeg 1' : null);
  }
  @override
  Future<void> cancel(String jobId) async => cancels++;
  @override
  Uri download(String jobId) => Uri.parse('http://127.0.0.1:8150/api/export/$jobId/video');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Exportprofile', () {
    test('Kontrollvideo: 640×360 bzw. 360×640, 10 fps, H.264 CRF 34, Wasserzeichen', () {
      final l = VideoExportProfile.of(VideoExportPreset.controlPreview, FilmFormat.landscape16x9);
      final p = VideoExportProfile.of(VideoExportPreset.controlPreview, FilmFormat.portrait9x16);
      expect([l.width, l.height], [640, 360]);
      expect([p.width, p.height], [360, 640]);
      expect(l.fps, 10);
      expect(l.crf, inInclusiveRange(32, 35));
      expect(l.audioKbps, 64);
      expect(l.watermark, 'DRIVETIME PREVIEW');
    });

    test('Full HD: 1920×1080 bzw. 1080×1920, 30 fps, kein Wasserzeichen', () {
      final l = VideoExportProfile.of(VideoExportPreset.fullHD, FilmFormat.landscape16x9);
      final p = VideoExportProfile.of(VideoExportPreset.fullHD, FilmFormat.portrait9x16);
      expect([l.width, l.height], [1920, 1080]);
      expect([p.width, p.height], [1080, 1920]);
      expect(l.fps, 30);
      expect(l.watermark, isNull);
      expect(p.watermark, isNull);
    });

    test('Kontrollprofil bleibt technisch unter Full HD', () {
      for (final f in FilmFormat.values) {
        final c = VideoExportProfile.of(VideoExportPreset.controlPreview, f);
        final h = VideoExportProfile.of(VideoExportPreset.fullHD, f);
        expect(c.width * c.height, lessThan(h.width * h.height));
        expect(c.fps, lessThan(h.fps));
        expect(c.crf, greaterThan(h.crf));
        expect(c.audioKbps, lessThan(h.audioKbps));
      }
    });

    test('identische Zeitleiste und Bildausschnitt: gleiches Seitenverhältnis, gleiche Dauer', () {
      for (final f in FilmFormat.values) {
        final c = VideoExportProfile.of(VideoExportPreset.controlPreview, f);
        final h = VideoExportProfile.of(VideoExportPreset.fullHD, f);
        expect(c.width / c.height, closeTo(h.width / h.height, 1e-9));
        expect(c.format.viewport, h.format.viewport);
        expect(VideoExportProfile.timelineFps, TourAnimationView.exportFrameRate);
        expect(VideoExportProfile.timelineFps % c.fps, 0, reason: 'jedes n-te Filmbild, keine eigene Zeitleiste');
        const frames = 4455; // „Roll On“-Film, 148,5 s
        expect(c.capturedFrames(frames) / c.fps, closeTo(frames / 30, 1 / c.fps));
        expect(h.capturedFrames(frames) / h.fps, frames / 30);
      }
    });

    test('Wasserzeichen nur beim Kontrollvideo', () {
      for (final f in FilmFormat.values) {
        expect(VideoExportProfile.of(VideoExportPreset.controlPreview, f).watermark, isNotNull);
        expect(VideoExportProfile.of(VideoExportPreset.fullHD, f).watermark, isNull);
      }
    });

    test('Exportdienst nutzt dieselben Zahlen (tool/studio_export/presets.json)', () {
      final j = jsonDecode(File('tool/studio_export/presets.json').readAsStringSync()) as Map<String, dynamic>;
      expect(j['timelineFps'], VideoExportProfile.timelineFps);
      for (final f in FilmFormat.values) {
        expect(j['viewport'][f.name], {'width': f.viewport.width, 'height': f.viewport.height});
      }
      for (final p in VideoExportPreset.values) {
        final d = VideoExportProfile.of(p, FilmFormat.landscape16x9);
        final s = j['presets'][p.name] as Map<String, dynamic>;
        expect((s['deviceScaleFactor'] as num).toDouble(), closeTo(d.deviceScaleFactor, 1e-9));
        expect([s['fps'], s['crf'], s['x264Preset'], s['audioKbps'], s['watermark']], [d.fps, d.crf, d.x264Preset, d.audioKbps, d.watermark]);
      }
      // Wasserzeichen-Bilder für beide Formate vorhanden.
      for (final f in FilmFormat.values) {
        final c = VideoExportProfile.of(VideoExportPreset.controlPreview, f);
        expect(File('tool/studio_export/assets/watermark_preview_${c.width}x${c.height}.png').existsSync(), isTrue);
      }
    });
  });

  group('Filmspezifikation und Filmkennung', () {
    test('JSON hin und zurück: gleicher Film, gleiche Kennung', () {
      final a = _spec();
      final b = TourFilmSpec.fromJson(jsonDecode(jsonEncode(a.toJson())) as Map<String, dynamic>);
      expect(b.filmId, a.filmId);
      expect(b.eta.steps.length, a.eta.steps.length);
      expect(b.eta.arrival, a.eta.arrival);
      expect(b.eta.steps[3].start, a.eta.steps[3].start);
      expect(b.eta.summary!.ferryRestMinutes, 660);
      expect(b.plan.segments[1].isFerry, isTrue);
      final pa = filmPathFor(a)!, pb = filmPathFor(b)!;
      expect(pb.totalMeters, pa.totalMeters);
      expect([for (final l in pb.legs) l.kind], [for (final l in pa.legs) l.kind]);
    });

    test('Kennung stabil, ändert sich nur mit filmrelevantem Inhalt', () {
      expect(_spec().filmId, _spec().filmId);
      expect(_spec(shift: 0.01).filmId, isNot(_spec().filmId), reason: 'Route/Start geändert');
      expect(_spec(format: FilmFormat.portrait9x16).filmId, isNot(_spec().filmId), reason: 'Filmformat geändert');
      expect(_spec().copyWith(format: FilmFormat.landscape16x9).filmId, _spec().filmId);
    });

    test('beschädigte Spezifikation wird abgelehnt', () {
      final j = _spec().toJson();
      (j['plan'] as Map)['start'] = [0.0, 0.0];
      expect(() => TourFilmSpec.fromJson(jsonDecode(jsonEncode(j)) as Map<String, dynamic>), throwsFormatException);
    });

    test('eine Filmregie: Exportprofil ist kein Eingang des Films', () {
      final s = _spec();
      final path = filmPathFor(s)!;
      final view = filmViewFor(s, path: path, videoExport: true) as TourAnimationView;
      final preview = filmViewFor(s, path: path, videoExport: false) as TourAnimationView;
      // Gleiche Inhalte; nur der Aufnahmemodus unterscheidet sich.
      expect(view.title, preview.title);
      expect(view.eta, same(preview.eta));
      expect(view.stops, preview.stops);
      expect(view.cameraMode, preview.cameraMode);
      expect(view.truckModel.id, preview.truckModel.id);
      expect(view.dayNight, preview.dayNight);
      expect(view.videoExport, isTrue);
    });

    test('Export löst keinen Routen-/Geocoding-Aufruf aus', () async {
      var calls = 0;
      await http.runWithClient(() async {
        final s = _spec();
        final again = TourFilmSpec.fromJson(jsonDecode(jsonEncode(s.toJson())) as Map<String, dynamic>);
        expect(filmPathFor(again), isNotNull);
        final c = VideoExportController(backend: _FakeBackend(), pollInterval: Duration.zero);
        expect((await c.start(again, VideoExportPreset.controlPreview)).status, VideoExportStatus.ready);
      }, () => MockClient((r) async {
            calls++;
            return http.Response('{}', 500);
          }));
      expect(calls, 0);
    });
  });

  group('Berechtigung', () {
    test('Full HD standardmäßig gesperrt, Kontrollvideo frei', () {
      const e = DefaultVideoExportEntitlements(devUnlockFullHd: false);
      expect(e.allows(VideoExportPreset.controlPreview, 'x'), isTrue);
      expect(e.allows(VideoExportPreset.fullHD, 'x'), isFalse);
      expect(kDevUnlockFullHd, isFalse, reason: 'Test-Build ohne Dev-Freischaltung');
    });

    test('Dienst ist maßgeblich: lokale Freischaltung allein genügt nicht', () {
      const app = DefaultVideoExportEntitlements(devUnlockFullHd: true);
      expect(const CombinedVideoExportEntitlements(app, {VideoExportPreset.fullHD: false}).allows(VideoExportPreset.fullHD, 'x'), isFalse);
      expect(const CombinedVideoExportEntitlements(app, {VideoExportPreset.fullHD: true}).allows(VideoExportPreset.fullHD, 'x'), isTrue);
    });

    test('gesperrtes Full HD startet keinen Auftrag', () async {
      final b = _FakeBackend();
      final c = VideoExportController(backend: b, pollInterval: Duration.zero, entitlements: const DefaultVideoExportEntitlements(devUnlockFullHd: false));
      final s = await c.start(_spec(), VideoExportPreset.fullHD);
      expect(s.status, VideoExportStatus.failed);
      expect(s.downloadUrl, isNull);
      expect(b.starts, 0);
    });
  });

  group('Exportablauf', () {
    test('Kontrollvideo: preparing → rendering → encoding → ready mit Datei', () async {
      final b = _FakeBackend();
      final c = VideoExportController(backend: b, pollInterval: Duration.zero);
      final seen = <VideoExportStatus>[];
      c.addListener(() => seen.add(c.state.status));
      final s = await c.start(_spec(), VideoExportPreset.controlPreview);
      expect(s.status, VideoExportStatus.ready);
      expect(s.downloadUrl.toString(), endsWith('/api/export/job1/video'));
      expect(s.bytes, 1234);
      expect(seen.toSet(), containsAll([VideoExportStatus.preparing, VideoExportStatus.rendering, VideoExportStatus.encoding, VideoExportStatus.ready]));
      expect(b.presets, [VideoExportPreset.controlPreview]);
    });

    test('Fehler: keine vorgetäuschte Datei, verständliche Meldung, erneuter Versuch klappt', () async {
      final b = _FakeBackend(failStarts: 1);
      final c = VideoExportController(backend: b, pollInterval: Duration.zero);
      final s1 = await c.start(_spec(), VideoExportPreset.controlPreview);
      expect(s1.status, VideoExportStatus.failed);
      expect(s1.downloadUrl, isNull);
      expect(s1.userMessage, isNotEmpty);
      expect(s1.debugDetail, 'chrome missing');
      final s2 = await c.start(_spec(), VideoExportPreset.controlPreview);
      expect(s2.status, VideoExportStatus.ready);
      expect(b.starts, 2);
    });

    test('Dienst meldet Fehler beim Kodieren → failed ohne Datei', () async {
      final c = VideoExportController(backend: _FakeBackend(steps: const ['rendering', 'failed']), pollInterval: Duration.zero);
      final s = await c.start(_spec(), VideoExportPreset.controlPreview);
      expect(s.status, VideoExportStatus.failed);
      expect(s.downloadUrl, isNull);
      expect(s.debugDetail, 'ffmpeg 1');
    });

    test('kein Doppelstart; Abbrechen ruft den Dienst und endet in cancelled', () async {
      final b = _FakeBackend(steps: List.filled(1000, 'rendering'));
      final c = VideoExportController(backend: b, pollInterval: const Duration(milliseconds: 1));
      final f = c.start(_spec(), VideoExportPreset.controlPreview);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(c.state.status.running, isTrue);
      await c.start(_spec(), VideoExportPreset.controlPreview); // zweiter Klick: ignoriert
      expect(b.starts, 1);
      expect(c.canCancel, isTrue);
      c.cancel();
      final s = await f;
      expect(s.status, VideoExportStatus.cancelled);
      expect(b.cancels, 1);
      expect(s.downloadUrl, isNull);
    });

    test('HTTP-Anbindung: Vertrag mit dem Exportdienst', () async {
      final requests = <String>[];
      final client = MockClient((r) async {
        requests.add('${r.method} ${r.url.path}');
        if (r.url.path == '/api/export' && r.method == 'POST') {
          final b = jsonDecode(r.body) as Map<String, dynamic>;
          expect(b['preset'], 'controlPreview');
          expect((b['spec'] as Map)['filmId'], _spec().filmId);
          return http.Response('{"jobId":"j1"}', 202);
        }
        if (r.url.path == '/api/export/j1') return http.Response('{"status":"ready","framesDone":10,"framesTotal":10,"bytes":99}', 200);
        if (r.url.path == '/api/health') return http.Response('{"service":"drivetime-studio-export"}', 200);
        return http.Response('{}', 404);
      });
      final b = StudioExportBackend(baseUrl: Uri.parse('http://127.0.0.1:8150/'), client: client);
      expect(await b.available(), isTrue);
      final c = VideoExportController(backend: b, pollInterval: Duration.zero);
      final s = await c.start(_spec(), VideoExportPreset.controlPreview);
      expect(s.status, VideoExportStatus.ready);
      expect(s.downloadUrl.toString(), 'http://127.0.0.1:8150/api/export/j1/video');
      expect(requests, ['GET /api/health', 'POST /api/export', 'GET /api/export/j1']);
    });

    test('HTTP: gesperrtes Profil (403) → verständliche Meldung', () async {
      final b = StudioExportBackend(
          baseUrl: Uri.parse('http://127.0.0.1:8150/'),
          client: MockClient((r) async => http.Response('{"error":"not_entitled"}', 403)));
      final c = VideoExportController(backend: b, pollInterval: Duration.zero);
      final s = await c.start(_spec(), VideoExportPreset.controlPreview);
      expect(s.status, VideoExportStatus.failed);
      expect(s.userMessage, contains('nicht freigeschaltet'));
    });
  });
}
