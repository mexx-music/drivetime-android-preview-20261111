// Live-Aufnahme der Touranimation – Ablauf.
//
// ready → requesting → recording → finalizing → fileReady
//            ↘ cancelled / failed (jederzeit; danach erneut startbar)
// unsupported: Browser kann es nicht (Option bleibt aus).
//
// Die Aufnahme beginnt erst mit dem tatsächlichen Start der Fahrt
// ([LiveRecordingSignals.started]) – Ladezeit der Karte landet nicht im
// Video – und endet mit dem Filmende samt Outro plus kurzem Nachlauf.
// Kein Netzwerkaufruf: Der Controller kennt nur [TabCaptureApi].

import 'dart:async';

import 'package:flutter/foundation.dart';

import 'tab_capture.dart';

enum LiveRecordingStatus {
  ready,
  requesting,
  recording,
  finalizing,
  fileReady,
  cancelled,
  unsupported,
  failed;

  bool get busy => this == requesting || this == recording || this == finalizing;
}

/// Wie die Aufnahme geendet hat (für die Meldung).
enum LiveRecordingEnd { filmEnd, manual, browser }

/// Signale der Touranimation an die laufende Aufnahme (an genau einen
/// Versuch gebunden; spätere Signale eines alten Versuchs wirken nicht).
class LiveRecordingSignals {
  const LiveRecordingSignals({required this.started, required this.finished, required this.closeRequest});
  final VoidCallback started;
  final VoidCallback finished;

  /// Wird true, sobald die Aufnahme nicht mehr läuft (fertig, abgebrochen,
  /// Fehler): Die Animation schließt sich dann selbst – im sauberen
  /// Aufnahmemodus gibt es keine eigene Schließen-Schaltfläche.
  final ValueListenable<bool> closeRequest;
}

class LiveRecordingController extends ChangeNotifier {
  LiveRecordingController({
    TabCaptureApi? api,
    this.postRoll = const Duration(seconds: 1),
    DateTime Function()? clock,
  })  : api = api ?? tabCaptureApi(),
        _clock = clock ?? DateTime.now {
    _mimeType = this.api.apisAvailable ? pickRecordingMimeType(this.api.isTypeSupported) : null;
    _status = _mimeType == null ? LiveRecordingStatus.unsupported : LiveRecordingStatus.ready;
  }

  final TabCaptureApi api;

  /// Nachlauf nach dem Filmende, bevor die Aufnahme schließt.
  final Duration postRoll;
  final DateTime Function() _clock;

  late final String? _mimeType;
  late LiveRecordingStatus _status;
  LiveRecordingStatus get status => _status;

  /// Funktion wird angeboten (APIs vorhanden, ein Format unterstützt).
  bool get supported => _mimeType != null;

  /// Format, mit dem dieser Browser aufnehmen wird (vor dem Start bekannt).
  String? get plannedMimeType => _mimeType;

  /// Browser kann MP4 mit H.264 erzeugen (iPhone, Android, TikTok direkt).
  bool get plannedH264Mp4 => _mimeType != null && isH264Mp4Mime(_mimeType);

  /// Browser kann nur WebM speichern.
  bool get plannedWebmOnly => _mimeType != null && isWebmMime(_mimeType);

  /// Verständliche Meldung zum aktuellen Zustand (ohne Technikdetails).
  String? userMessage;

  /// Technische Einzelheiten – nur für den Diagnosebereich.
  String? debugDetail;

  /// Gewählte Freigabe laut Browser.
  DisplaySurfaceKind? surface;

  /// Seite war während der Aufnahme verdeckt (mögliche Ruckler).
  bool wasHidden = false;

  /// Bildgröße hat sich während der Aufnahme geändert (MP4 evtl. defekt).
  bool frameSizeChanged = false;
  String? _frameSizeAtStart;

  void _checkFrameSize() {
    final now = _stream?.frameSize;
    if (_frameSizeAtStart != null && now != null && now != _frameSizeAtStart) frameSizeChanged = true;
  }

  LiveRecordingEnd? endedBy;

  /// Beginn der Aufnahme (für Dateiname und Dauer).
  DateTime? startedAt;
  DateTime? _stoppedAt;

  Duration get recordedDuration {
    final s = startedAt;
    if (s == null) return Duration.zero;
    return (_stoppedAt ?? _clock()).difference(s);
  }

  /// Die Fahrt läuft und wird aufgenommen.
  bool get capturing => _status == LiveRecordingStatus.recording && _recorder != null;

  RecordedVideo? _video;
  String? get videoMimeType => _video?.mimeType;
  int? get videoBytes => _video?.sizeBytes;
  String? get videoExtension => _video == null ? null : extensionForMimeType(_video!.mimeType);

  /// Tatsächlich in der Datei gefundener Codec.
  VideoCodec? get videoCodec => _video?.codec;

  /// Fertige Datei ist MP4 mit H.264 (laut Dateiinhalt).
  bool get videoIsH264Mp4 => videoExtension == 'mp4' && videoCodec == VideoCodec.h264;

  TabCaptureStream? _stream;
  TabRecorder? _recorder;
  Timer? _clockTimer;
  Timer? _postRollTimer;
  VoidCallback? _unwatchHidden;
  int _attempt = 0;
  bool _disposed = false;

  /// Schließwunsch an die Animation des laufenden Versuchs.
  ValueNotifier<bool> _closeRequest = ValueNotifier<bool>(false);

  void _set(LiveRecordingStatus s, {String? message, String? detail}) {
    if (_disposed) return;
    _status = s;
    if (s != LiveRecordingStatus.requesting && s != LiveRecordingStatus.recording) _closeRequest.value = true;
    userMessage = message;
    debugDetail = detail;
    notifyListeners();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  /// Startet einen Versuch. MUSS synchron aus dem Klick des Nutzers kommen:
  /// Die Freigabe wird vor jedem `await` angefragt.
  ///
  /// [openAnimation] öffnet die Touranimation genau einmal und endet, wenn
  /// sie wieder geschlossen ist. [confirmSurface] fragt nach, wenn statt
  /// eines Tabs ein Fenster oder der Bildschirm freigegeben wurde.
  Future<void> start({
    required Future<void> Function(LiveRecordingSignals signals) openAnimation,
    Future<bool> Function(DisplaySurfaceKind surface)? confirmSurface,
  }) async {
    if (_disposed || _status.busy || !supported) return;
    _releaseVideo();
    final attempt = ++_attempt;
    _closeRequest = ValueNotifier<bool>(false);
    surface = null;
    wasHidden = false;
    frameSizeChanged = false;
    _frameSizeAtStart = null;
    endedBy = null;
    startedAt = null;
    _stoppedAt = null;

    final Future<TabCaptureStream> request;
    try {
      request = api.requestDisplay(); // vor jedem await – Nutzeraktion
    } catch (e) {
      _set(LiveRecordingStatus.failed, message: 'Die Bildschirmfreigabe konnte nicht angefragt werden.', detail: '$e');
      return;
    }
    _set(LiveRecordingStatus.requesting);

    final TabCaptureStream stream;
    try {
      stream = await request;
    } on TabCaptureDeniedException catch (e) {
      if (attempt == _attempt) {
        _set(LiveRecordingStatus.cancelled,
            message: 'Die Freigabe wurde nicht erteilt. Es wurde nichts aufgenommen.', detail: e.detail);
      }
      return;
    } catch (e) {
      if (attempt == _attempt) {
        _set(LiveRecordingStatus.failed,
            message: e is TabCaptureException && e.name == 'InvalidStateError'
                ? 'Die Freigabe konnte nicht angefragt werden. Bitte die Schaltfläche erneut direkt anklicken.'
                : 'Die Bildschirmfreigabe ist nicht möglich. Bitte erneut versuchen.',
            detail: '$e');
      }
      return;
    }
    if (_disposed || attempt != _attempt) {
      stream.stop();
      return;
    }
    _stream = stream;
    stream.onEnded = () => _browserEnded(attempt);
    surface = stream.surface;

    if ((surface == DisplaySurfaceKind.window || surface == DisplaySurfaceKind.monitor) && confirmSurface != null) {
      bool ok;
      try {
        ok = await confirmSurface(surface!);
      } catch (_) {
        ok = false;
      }
      // Inzwischen beendet (Browser, dispose)? Dann ist schon aufgeräumt.
      if (_disposed || attempt != _attempt || _status != LiveRecordingStatus.requesting) return;
      if (!ok) {
        _cleanup();
        _set(LiveRecordingStatus.cancelled, message: 'Aufnahme abgebrochen. Es wurde nichts aufgenommen.');
        return;
      }
    }
    if (!stream.active) {
      _cleanup();
      _set(LiveRecordingStatus.cancelled, message: 'Die Freigabe wurde bereits beendet. Es wurde nichts aufgenommen.');
      return;
    }

    _set(LiveRecordingStatus.recording);
    try {
      await openAnimation(LiveRecordingSignals(
        started: () => _animationStarted(attempt),
        finished: () => _animationFinished(attempt),
        closeRequest: _closeRequest,
      ));
    } catch (e) {
      if (attempt == _attempt && _status == LiveRecordingStatus.recording) {
        _cleanup();
        _set(LiveRecordingStatus.failed, message: 'Die Touranimation konnte nicht geöffnet werden.', detail: '$e');
      }
      return;
    }
    if (attempt == _attempt) _animationClosed();
  }

  void _animationStarted(int attempt) {
    if (attempt != _attempt || _status != LiveRecordingStatus.recording || _recorder != null) return;
    final stream = _stream;
    if (stream == null) return;
    final TabRecorder recorder;
    try {
      recorder = stream.createRecorder(_mimeType!);
      recorder.onError = (e) => _recorderFailed(attempt, e);
      recorder.start();
    } catch (e) {
      _cleanup();
      _set(LiveRecordingStatus.failed, message: 'Die Aufnahme konnte nicht gestartet werden.', detail: '$e');
      return;
    }
    _recorder = recorder;
    startedAt = _clock();
    _frameSizeAtStart = stream.frameSize;
    _clockTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      _checkFrameSize();
      _notify();
    });
    _unwatchHidden = api.watchPageHidden(() => wasHidden = true);
    _notify();
  }

  void _animationFinished(int attempt) {
    if (attempt != _attempt || !capturing || _postRollTimer != null) return;
    _postRollTimer = Timer(postRoll, () => _finish(attempt, LiveRecordingEnd.filmEnd));
  }

  /// „Aufnahme beenden“: bisheriges Video fertigstellen.
  Future<void> stop() => _finish(_attempt, LiveRecordingEnd.manual);

  void _browserEnded(int attempt) {
    if (attempt != _attempt) return;
    if (_status == LiveRecordingStatus.requesting || (_status == LiveRecordingStatus.recording && _recorder == null)) {
      _cleanup();
      _set(LiveRecordingStatus.cancelled,
          message: 'Die Freigabe wurde beendet, bevor die Aufnahme begonnen hat. Es wurde nichts aufgenommen.');
    } else if (_status == LiveRecordingStatus.recording) {
      _finish(attempt, LiveRecordingEnd.browser);
    }
  }

  /// Animation verlassen (Zurück, Schließen, Navigation).
  void _animationClosed() {
    if (_status != LiveRecordingStatus.recording) return;
    if (_postRollTimer != null) {
      // Film war schon zu Ende – nur der Nachlauf fehlt: fertigstellen.
      _finish(_attempt, LiveRecordingEnd.filmEnd);
      return;
    }
    _cleanup();
    _set(LiveRecordingStatus.cancelled,
        message: 'Aufnahme abgebrochen – die Animation wurde verlassen. Das Teilvideo wurde verworfen.');
  }

  void _recorderFailed(int attempt, Object error) {
    if (attempt != _attempt || !(_status == LiveRecordingStatus.recording || _status == LiveRecordingStatus.finalizing)) {
      return;
    }
    _attempt++; // laufendes Fertigstellen dieses Versuchs verwerfen
    _cleanup();
    _set(LiveRecordingStatus.failed, message: 'Die Aufnahme wurde unterbrochen. Bitte erneut versuchen.', detail: '$error');
  }

  Future<void> _finish(int attempt, LiveRecordingEnd how) async {
    if (attempt != _attempt || _status != LiveRecordingStatus.recording) return;
    final recorder = _recorder;
    if (recorder == null) {
      _cleanup();
      _set(LiveRecordingStatus.cancelled, message: 'Es wurde nichts aufgenommen.');
      return;
    }
    _checkFrameSize();
    _recorder = null;
    _stoppedAt = _clock();
    endedBy = how;
    _stopTimers();
    _set(LiveRecordingStatus.finalizing);
    RecordedVideo? video;
    try {
      video = await recorder.stop();
    } catch (e) {
      if (attempt == _attempt) {
        _cleanup();
        _set(LiveRecordingStatus.failed, message: 'Das Video konnte nicht fertiggestellt werden.', detail: '$e');
      }
      return;
    }
    if (_disposed || attempt != _attempt) {
      video?.release();
      return;
    }
    _cleanup();
    if (video == null || video.sizeBytes <= 0 || extensionForMimeType(video.mimeType) == null) {
      video?.release();
      _set(LiveRecordingStatus.failed,
          message: 'Es sind keine verwertbaren Videodaten entstanden. Bitte erneut versuchen.',
          detail: video == null ? 'leer oder unvollständig' : '${video.mimeType}, ${video.sizeBytes} B');
      return;
    }
    _video = video;
    _set(LiveRecordingStatus.fileReady,
        message: switch (how) {
          LiveRecordingEnd.filmEnd => 'Video bereit.',
          LiveRecordingEnd.manual => 'Aufnahme beendet – das bis dahin aufgenommene Video ist bereit.',
          LiveRecordingEnd.browser =>
            'Die Freigabe wurde im Browser beendet – das bis dahin aufgenommene Video ist bereit.',
        });
  }

  /// Bietet die fertige Datei an. false, wenn keine Datei bereitliegt.
  bool download(String fileName) {
    final v = _video;
    if (_status != LiveRecordingStatus.fileReady || v == null) return false;
    return v.download(fileName);
  }

  void _stopTimers() {
    _clockTimer?.cancel();
    _clockTimer = null;
    _postRollTimer?.cancel();
    _postRollTimer = null;
    _unwatchHidden?.call();
    _unwatchHidden = null;
  }

  /// Freigabe, Spuren, Recorder, Listener und Zeitgeber freigeben.
  void _cleanup() {
    _stopTimers();
    final r = _recorder;
    _recorder = null;
    r?.onError = null;
    r?.abort();
    final s = _stream;
    _stream = null;
    s?.onEnded = null;
    s?.stop();
  }

  void _releaseVideo() {
    _video?.release();
    _video = null;
  }

  @override
  void dispose() {
    _closeRequest.value = true; // offene Aufnahmeansicht schließt sich
    _disposed = true;
    _attempt++;
    _cleanup();
    _releaseVideo();
    super.dispose();
  }
}
