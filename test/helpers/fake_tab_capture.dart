// Ersatz für Bildschirmfreigabe und MediaRecorder des Browsers – Tests
// brauchen keine echte Freigabe.

import 'dart:async';

import 'package:driverroute_eta/export/live_recording/tab_capture.dart';
import 'package:flutter/foundation.dart';

class FakeVideo implements RecordedVideo {
  FakeVideo(this.mimeType, this.sizeBytes, [VideoCodec? codec])
      : codec = codec ?? (mimeType.contains('avc') ? VideoCodec.h264 : VideoCodec.vp9);
  @override
  final String mimeType;
  @override
  final int sizeBytes;
  @override
  final VideoCodec codec;
  final List<String> downloads = [];
  bool released = false;

  @override
  bool download(String fileName) {
    if (released) return false;
    downloads.add(fileName);
    return true;
  }

  @override
  void release() => released = true;
}

class FakeRecorder implements TabRecorder {
  FakeRecorder(this.mimeType, this._api);
  @override
  final String mimeType;
  final FakeTabCaptureApi _api;
  void Function(Object error)? errorCallback;
  bool started = false, stopped = false, aborted = false;

  @override
  set onError(void Function(Object error)? callback) => errorCallback = callback;

  @override
  void start() {
    started = true;
    _api.recordersStarted++;
  }

  @override
  Future<RecordedVideo?> stop() async {
    stopped = true;
    final v = _api.videoFor(this);
    if (v is FakeVideo) _api.videos.add(v);
    return v;
  }

  @override
  void abort() => aborted = true;

  /// Browser meldet einen Recorder-Fehler.
  void fail([Object error = const TabCaptureException('UnknownError')]) => errorCallback?.call(error);
}

class FakeStream implements TabCaptureStream {
  FakeStream(this._api, this.surface);
  final FakeTabCaptureApi _api;
  @override
  final DisplaySurfaceKind surface;
  VoidCallback? ended;
  bool tracksStopped = false;

  @override
  String? frameSize = '1350x1832';
  bool _live = true;
  final List<FakeRecorder> recorders = [];

  @override
  bool get active => _live && !tracksStopped;

  @override
  set onEnded(VoidCallback? callback) => ended = callback;

  @override
  TabRecorder createRecorder(String mimeType) {
    final r = FakeRecorder(mimeType, _api);
    recorders.add(r);
    return r;
  }

  @override
  void stop() {
    tracksStopped = true;
    ended = null;
  }

  /// Nutzer klickt in der Browserleiste „Freigabe beenden“.
  void browserEnds() {
    _live = false;
    ended?.call();
  }
}

class FakeTabCaptureApi implements TabCaptureApi {
  FakeTabCaptureApi({this.apis = true, Set<String>? types})
      : types = types ?? {'video/webm;codecs=vp9', 'video/webm;codecs=vp8', 'video/webm'};

  bool apis;
  Set<String> types;
  int requests = 0;
  int recordersStarted = 0;
  Completer<TabCaptureStream>? _pending;
  final List<FakeStream> streams = [];
  final List<FakeVideo> videos = [];
  final List<VoidCallback> _hiddenListeners = [];
  int hiddenUnsubscribed = 0;

  /// Ergebnis von `stop()` je Recorder (Standard: 2 MB im gewählten Typ).
  RecordedVideo? Function(FakeRecorder r) videoFor = (r) => FakeVideo(r.mimeType, 2000000);

  @override
  bool get apisAvailable => apis;

  @override
  bool isTypeSupported(String mimeType) => types.contains(mimeType);

  @override
  Future<TabCaptureStream> requestDisplay() {
    requests++;
    _pending = Completer<TabCaptureStream>();
    return _pending!.future;
  }

  bool get waiting => _pending != null && !_pending!.isCompleted;

  FakeStream grant([DisplaySurfaceKind surface = DisplaySurfaceKind.browser]) {
    final s = FakeStream(this, surface);
    streams.add(s);
    _pending!.complete(s);
    return s;
  }

  void deny() => _pending!.completeError(const TabCaptureDeniedException('Permission denied'));

  void fail(String name) => _pending!.completeError(TabCaptureException(name));

  @override
  VoidCallback watchPageHidden(VoidCallback onHidden) {
    _hiddenListeners.add(onHidden);
    return () {
      _hiddenListeners.remove(onHidden);
      hiddenUnsubscribed++;
    };
  }

  int get hiddenListeners => _hiddenListeners.length;

  void hidePage() {
    for (final l in List.of(_hiddenListeners)) {
      l();
    }
  }
}
