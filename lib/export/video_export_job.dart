// DriveTime Studio – Ablauf eines Videoexports.
//
// idle → preparing → rendering → encoding → ready
//                 ↘ failed / cancelled (jederzeit; danach erneut startbar)
//
// Der Controller kennt nur die Schnittstelle [VideoExportBackend]. Heute ist
// das der lokale Exportdienst (tool/studio_export/server.mjs, Mac mit Chrome +
// ffmpeg); später kann derselbe Vertrag ein serverseitiger Exportjob erfüllen.

import 'dart:async';

import 'package:flutter/foundation.dart';

import 'film_spec.dart';
import 'video_export_entitlement.dart';
import 'video_export_preset.dart';

enum VideoExportStatus {
  idle,
  preparing,
  rendering,
  encoding,
  ready,
  failed,
  cancelled;

  bool get running => this == preparing || this == rendering || this == encoding;
  bool get finished => this == ready || this == failed || this == cancelled;
}

@immutable
class VideoExportJobState {
  const VideoExportJobState({
    this.status = VideoExportStatus.idle,
    this.preset,
    this.filmId,
    this.jobId,
    this.framesDone = 0,
    this.framesTotal = 0,
    this.bytes,
    this.downloadUrl,
    this.userMessage,
    this.debugDetail,
  });

  final VideoExportStatus status;
  final VideoExportPreset? preset;
  final String? filmId;
  final String? jobId;

  /// Aufgenommene Bilder / Bilder insgesamt (Fortschritt der Aufnahme).
  final int framesDone;
  final int framesTotal;

  /// Dateigröße der fertigen Datei.
  final int? bytes;

  /// Nur gesetzt, wenn [status] == ready – nie eine vorgetäuschte Datei.
  final Uri? downloadUrl;

  /// Verständliche Meldung für Nutzer (Fehler, Abbruch).
  final String? userMessage;

  /// Technische Einzelheiten (nur im Debugmodus anzeigen).
  final String? debugDetail;

  double? get progress => switch (status) {
        VideoExportStatus.preparing => 0,
        VideoExportStatus.rendering => framesTotal <= 0 ? null : (framesDone / framesTotal).clamp(0.0, 1.0) * 0.95,
        VideoExportStatus.encoding => 0.97,
        VideoExportStatus.ready => 1,
        _ => null,
      };

  VideoExportJobState copyWith({
    VideoExportStatus? status,
    String? jobId,
    int? framesDone,
    int? framesTotal,
    int? bytes,
    Uri? downloadUrl,
    String? userMessage,
    String? debugDetail,
  }) =>
      VideoExportJobState(
        status: status ?? this.status,
        preset: preset,
        filmId: filmId,
        jobId: jobId ?? this.jobId,
        framesDone: framesDone ?? this.framesDone,
        framesTotal: framesTotal ?? this.framesTotal,
        bytes: bytes ?? this.bytes,
        downloadUrl: downloadUrl ?? this.downloadUrl,
        userMessage: userMessage ?? this.userMessage,
        debugDetail: debugDetail ?? this.debugDetail,
      );
}

/// Fehler des Exportdienstes mit Nutzer- und Technikmeldung.
class VideoExportException implements Exception {
  const VideoExportException(this.userMessage, [this.detail]);
  final String userMessage;
  final String? detail;
  @override
  String toString() => 'VideoExportException: $userMessage${detail == null ? '' : ' ($detail)'}';
}

/// Rückmeldung des Dienstes zu einem Auftrag.
class VideoExportProgress {
  const VideoExportProgress({
    required this.status,
    this.framesDone = 0,
    this.framesTotal = 0,
    this.bytes,
    this.error,
    this.detail,
  });
  final VideoExportStatus status;
  final int framesDone;
  final int framesTotal;
  final int? bytes;
  final String? error;
  final String? detail;
}

/// Vertrag zwischen App und Exportdienst (lokal heute, serverseitig später).
abstract class VideoExportBackend {
  /// Erreichbar und betriebsbereit?
  Future<bool> available();

  /// Was der Dienst für diese Filmversion erlaubt (maßgeblich).
  Future<Map<VideoExportPreset, bool>> entitlements(String filmId);

  /// Startet einen Auftrag und liefert seine Kennung.
  Future<String> start(TourFilmSpec spec, VideoExportPreset preset);

  Future<VideoExportProgress> status(String jobId);

  /// Bricht ab; der Dienst räumt temporäre Dateien auf.
  Future<void> cancel(String jobId);

  /// Adresse der fertigen Datei.
  Uri download(String jobId);
}

class VideoExportController extends ChangeNotifier {
  VideoExportController({
    required this.backend,
    this.entitlements = const DefaultVideoExportEntitlements(),
    this.pollInterval = const Duration(seconds: 1),
  });

  final VideoExportBackend backend;
  final VideoExportEntitlements entitlements;
  final Duration pollInterval;

  VideoExportJobState _state = const VideoExportJobState();
  VideoExportJobState get state => _state;

  bool _cancelRequested = false;
  bool _disposed = false;

  void _set(VideoExportJobState s) {
    if (_disposed) return;
    _state = s;
    notifyListeners();
  }

  /// Startet einen Export. Läuft bereits einer, passiert nichts (kein Doppelstart).
  /// Liefert den Endzustand.
  Future<VideoExportJobState> start(TourFilmSpec spec, VideoExportPreset preset) async {
    if (_state.status.running) return _state;
    final filmId = spec.filmId;
    _cancelRequested = false;
    _set(VideoExportJobState(status: VideoExportStatus.preparing, preset: preset, filmId: filmId));
    if (!entitlements.allows(preset, filmId)) {
      _set(_state.copyWith(
          status: VideoExportStatus.failed,
          userMessage: entitlements.lockedReason(preset) ?? 'Dieses Exportprofil ist nicht freigeschaltet.'));
      return _state;
    }
    try {
      final jobId = await backend.start(spec, preset);
      _set(_state.copyWith(jobId: jobId));
      while (!_disposed) {
        if (_cancelRequested) {
          await backend.cancel(jobId);
          _set(_state.copyWith(status: VideoExportStatus.cancelled, userMessage: 'Export abgebrochen.'));
          return _state;
        }
        final p = await backend.status(jobId);
        switch (p.status) {
          case VideoExportStatus.ready:
            _set(_state.copyWith(
                status: VideoExportStatus.ready,
                framesDone: p.framesDone,
                framesTotal: p.framesTotal,
                bytes: p.bytes,
                downloadUrl: backend.download(jobId)));
            return _state;
          case VideoExportStatus.failed:
            _set(_state.copyWith(
                status: VideoExportStatus.failed,
                userMessage: p.error ?? 'Der Export ist fehlgeschlagen. Bitte erneut versuchen.',
                debugDetail: p.detail));
            return _state;
          case VideoExportStatus.cancelled:
            _set(_state.copyWith(status: VideoExportStatus.cancelled, userMessage: 'Export abgebrochen.'));
            return _state;
          default:
            _set(_state.copyWith(status: p.status, framesDone: p.framesDone, framesTotal: p.framesTotal));
        }
        await Future<void>.delayed(pollInterval);
      }
    } on VideoExportException catch (e) {
      _set(_state.copyWith(status: VideoExportStatus.failed, userMessage: e.userMessage, debugDetail: e.detail));
    } catch (e) {
      _set(_state.copyWith(
          status: VideoExportStatus.failed,
          userMessage: 'Der Exportdienst ist nicht erreichbar. Bitte erneut versuchen.',
          debugDetail: '$e'));
    }
    return _state;
  }

  /// Abbrechen ist sauber möglich, solange ein Auftrag läuft: Der Dienst
  /// beendet Aufnahme und Kodierung und löscht die temporären Dateien.
  bool get canCancel => _state.status.running && _state.jobId != null;

  void cancel() {
    if (canCancel) _cancelRequested = true;
  }

  /// Zurück auf „idle“ (z. B. vor einem erneuten Versuch).
  void reset() {
    if (!_state.status.running) _set(const VideoExportJobState());
  }

  @override
  void dispose() {
    // Ansicht verlassen: laufenden Auftrag nicht verwaist weiterrechnen lassen.
    if (canCancel) unawaited(backend.cancel(_state.jobId!).catchError((Object _) {}));
    _disposed = true;
    _cancelRequested = true;
    super.dispose();
  }
}
