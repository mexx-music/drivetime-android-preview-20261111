// Live-Aufnahme im Browser: getDisplayMedia + MediaRecorder.
//
// Bewusst über dart:js_interop mit Merkmalprüfung statt fester Annahmen:
// Fehlt eine API (Android, iPhone/iPad, ältere Browser), meldet
// [apisAvailable] false. Kein Ton, keine Kamera, kein Mikrofon.

import 'dart:async';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:flutter/foundation.dart';

import 'tab_capture.dart';

TabCaptureApi createPlatformTabCaptureApi() => _WebTabCaptureApi();

/// Ziel-Bitrate: ruhige Kartenbilder brauchen wenig; ~2,5 min ≈ 90 MB.
const int _videoBitsPerSecond = 5000000;

/// Datenblöcke im Sekundentakt: endet die Freigabe abrupt, fehlt höchstens
/// die letzte Sekunde.
const int _timesliceMs = 1000;

bool _isFunction(JSAny? v) => v != null && v.typeofEquals('function');

String? _string(JSAny? v) => v != null && v.typeofEquals('string') ? (v as JSString).toDart : null;

/// Fehlername eines DOMException-ähnlichen Werts (nur Diagnose).
String _errorName(JSAny? err) {
  if (err != null && (err.typeofEquals('object') || err.typeofEquals('function'))) {
    final o = err as JSObject;
    return _string(o['name']) ?? 'Error';
  }
  return 'Error';
}

String? _errorMessage(JSAny? err) {
  if (err != null && err.typeofEquals('object')) return _string((err as JSObject)['message']);
  return null;
}

class _WebTabCaptureApi implements TabCaptureApi {
  JSObject? get _mediaDevices {
    final nav = globalContext['navigator'];
    if (nav == null || !nav.typeofEquals('object')) return null;
    final md = (nav as JSObject)['mediaDevices'];
    return md != null && md.typeofEquals('object') ? md as JSObject : null;
  }

  JSObject? get _recorderClass {
    final mr = globalContext['MediaRecorder'];
    return _isFunction(mr) ? mr as JSObject : null;
  }

  @override
  bool get apisAvailable {
    try {
      final md = _mediaDevices;
      final mr = _recorderClass;
      return md != null && _isFunction(md['getDisplayMedia']) && mr != null && _isFunction(mr['isTypeSupported']);
    } catch (_) {
      return false;
    }
  }

  @override
  bool isTypeSupported(String mimeType) {
    try {
      final r = _recorderClass?.callMethod<JSAny?>('isTypeSupported'.toJS, mimeType.toJS);
      return r != null && r.typeofEquals('boolean') && (r as JSBoolean).toDart;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<TabCaptureStream> requestDisplay() {
    final completer = Completer<TabCaptureStream>();
    try {
      final md = _mediaDevices;
      if (md == null) throw const TabCaptureException('NotSupportedError');
      // Nur Hinweise an den Browser; erzwingen lässt sich die Auswahl nicht.
      final video = JSObject()
        ..['frameRate'] = 30.toJS
        ..['displaySurface'] = 'browser'.toJS;
      final options = JSObject()
        ..['video'] = video
        ..['audio'] = false.toJS
        ..['preferCurrentTab'] = true.toJS
        ..['selfBrowserSurface'] = 'include'.toJS
        ..['surfaceSwitching'] = 'exclude'.toJS
        ..['systemAudio'] = 'exclude'.toJS;
      // Synchron im Klick: kein await vor diesem Aufruf.
      final promise = md.callMethod<JSObject>('getDisplayMedia'.toJS, options);
      promise.callMethod<JSAny?>(
        'then'.toJS,
        ((JSObject stream) {
          if (!completer.isCompleted) completer.complete(_WebStream(stream));
        }).toJS,
        ((JSAny? err) {
          if (completer.isCompleted) return;
          final name = _errorName(err);
          completer.completeError(name == 'NotAllowedError'
              ? TabCaptureDeniedException(_errorMessage(err))
              : TabCaptureException(name, _errorMessage(err)));
        }).toJS,
      );
    } on TabCaptureException catch (e) {
      completer.completeError(e);
    } catch (e) {
      completer.completeError(TabCaptureException('Error', '$e'));
    }
    return completer.future;
  }

  @override
  VoidCallback watchPageHidden(VoidCallback onHidden) {
    try {
      final doc = globalContext['document'] as JSObject;
      final listener = ((JSAny? _) {
        final hidden = doc['hidden'];
        if (hidden != null && hidden.typeofEquals('boolean') && (hidden as JSBoolean).toDart) onHidden();
      }).toJS;
      doc.callMethod<JSAny?>('addEventListener'.toJS, 'visibilitychange'.toJS, listener);
      return () {
        try {
          doc.callMethod<JSAny?>('removeEventListener'.toJS, 'visibilitychange'.toJS, listener);
        } catch (_) {}
      };
    } catch (_) {
      return () {};
    }
  }
}

class _WebStream implements TabCaptureStream {
  _WebStream(this._stream) {
    try {
      _tracks = _stream.callMethod<JSArray<JSObject>>('getTracks'.toJS).toDart;
      final videos = _stream.callMethod<JSArray<JSObject>>('getVideoTracks'.toJS).toDart;
      _video = videos.isEmpty ? null : videos.first;
    } catch (_) {
      _tracks = const [];
    }
    _video?.callMethod<JSAny?>('addEventListener'.toJS, 'ended'.toJS, _endedListener);
  }

  final JSObject _stream;
  late final List<JSObject> _tracks;
  JSObject? _video;
  VoidCallback? _onEnded;
  bool _stopped = false;

  late final JSFunction _endedListener = ((JSAny? _) {
    if (!_stopped) _onEnded?.call();
  }).toJS;

  @override
  set onEnded(VoidCallback? callback) => _onEnded = callback;

  @override
  DisplaySurfaceKind get surface {
    try {
      final s = _video?.callMethod<JSObject?>('getSettings'.toJS);
      return DisplaySurfaceKind.parse(_string(s?['displaySurface']));
    } catch (_) {
      return DisplaySurfaceKind.unknown;
    }
  }

  @override
  bool get active => !_stopped && _string(_video?['readyState']) == 'live';

  @override
  String? get frameSize {
    try {
      final s = _video?.callMethod<JSObject?>('getSettings'.toJS);
      final w = s?['width'], h = s?['height'];
      if (w == null || h == null || !w.typeofEquals('number') || !h.typeofEquals('number')) return null;
      return '${(w as JSNumber).toDartInt}x${(h as JSNumber).toDartInt}';
    } catch (_) {
      return null;
    }
  }

  @override
  TabRecorder createRecorder(String mimeType) => _WebRecorder(_stream, mimeType);

  @override
  void stop() {
    if (_stopped) return;
    _stopped = true;
    _onEnded = null;
    try {
      _video?.callMethod<JSAny?>('removeEventListener'.toJS, 'ended'.toJS, _endedListener);
    } catch (_) {}
    for (final t in _tracks) {
      try {
        t.callMethod<JSAny?>('stop'.toJS);
      } catch (_) {}
    }
  }
}

class _WebRecorder implements TabRecorder {
  _WebRecorder(JSObject stream, this._requested) {
    final options = JSObject()
      ..['mimeType'] = _requested.toJS
      ..['videoBitsPerSecond'] = _videoBitsPerSecond.toJS;
    _rec = (globalContext['MediaRecorder'] as JSFunction).callAsConstructor<JSObject>(stream, options);
    _rec.callMethod<JSAny?>('addEventListener'.toJS, 'dataavailable'.toJS, _onData);
    _rec.callMethod<JSAny?>('addEventListener'.toJS, 'stop'.toJS, _onStop);
    _rec.callMethod<JSAny?>('addEventListener'.toJS, 'error'.toJS, _onErr);
  }

  final String _requested;
  late final JSObject _rec;
  final List<JSObject> _chunks = [];
  final Completer<void> _stopped = Completer<void>();
  void Function(Object error)? _errorCallback;
  bool _detached = false;

  late final JSFunction _onData = ((JSObject event) {
    if (_detached) return;
    final data = event['data'];
    if (data == null || !data.typeofEquals('object')) return;
    final size = (data as JSObject)['size'];
    if (size != null && size.typeofEquals('number') && (size as JSNumber).toDartDouble > 0) _chunks.add(data);
  }).toJS;

  late final JSFunction _onStop = ((JSAny? _) {
    if (!_stopped.isCompleted) _stopped.complete();
  }).toJS;

  late final JSFunction _onErr = ((JSAny? event) {
    if (_detached) return;
    JSAny? err = event;
    if (event != null && event.typeofEquals('object')) err = (event as JSObject)['error'] ?? event;
    _errorCallback?.call(TabCaptureException(_errorName(err), _errorMessage(err)));
  }).toJS;

  @override
  set onError(void Function(Object error)? callback) => _errorCallback = callback;

  @override
  String get mimeType {
    try {
      final m = _string(_rec['mimeType']);
      if (m != null && m.isNotEmpty) return m;
    } catch (_) {}
    return _requested;
  }

  String get _state => _string(_rec['state']) ?? 'inactive';

  @override
  void start() => _rec.callMethod<JSAny?>('start'.toJS, _timesliceMs.toJS);

  void _detach() {
    if (_detached) return;
    _detached = true;
    _errorCallback = null;
    for (final (type, fn) in [('dataavailable', _onData), ('stop', _onStop), ('error', _onErr)]) {
      try {
        _rec.callMethod<JSAny?>('removeEventListener'.toJS, type.toJS, fn);
      } catch (_) {}
    }
  }

  @override
  Future<RecordedVideo?> stop() async {
    try {
      if (_state != 'inactive') {
        _rec.callMethod<JSAny?>('stop'.toJS);
      } else if (!_stopped.isCompleted) {
        _stopped.complete();
      }
    } catch (_) {
      if (!_stopped.isCompleted) _stopped.complete();
    }
    // Letzter Datenblock kommt vor dem stop-Ereignis.
    await _stopped.future.timeout(const Duration(seconds: 10), onTimeout: () {});
    final type = mimeType;
    _detach();
    if (_chunks.isEmpty) return null;
    final blob = (globalContext['Blob'] as JSFunction)
        .callAsConstructor<JSObject>(_chunks.toJS, JSObject()..['type'] = type.toJS);
    _chunks.clear();
    final size = ((blob['size'] as JSNumber?)?.toDartDouble ?? 0).round();
    if (size <= 0) return null;
    final VideoCodec codec;
    try {
      // Dateianfang: Kopf prüfen und den tatsächlichen Codec lesen.
      final buffer = await blob
          .callMethod<JSObject>('slice'.toJS, 0.toJS, 65536.toJS)
          .callMethod<JSPromise<JSArrayBuffer>>('arrayBuffer'.toJS)
          .toDart;
      final head = buffer.toDart.asUint8List();
      if (!looksLikeRecordedVideo(head, type)) return null;
      codec = detectVideoCodec(head, type);
    } catch (_) {
      return null;
    }
    return _WebVideo(blob, type, size, codec);
  }

  @override
  void abort() {
    _detach();
    _chunks.clear();
    try {
      if (_state != 'inactive') _rec.callMethod<JSAny?>('stop'.toJS);
    } catch (_) {}
  }
}

class _WebVideo implements RecordedVideo {
  _WebVideo(this._blob, this.mimeType, this.sizeBytes, this.codec);

  JSObject? _blob;
  @override
  final String mimeType;
  @override
  final int sizeBytes;
  @override
  final VideoCodec codec;
  final Map<String, Timer> _urls = {};

  JSObject get _url => globalContext['URL'] as JSObject;

  void _revoke(String url) {
    _urls.remove(url)?.cancel();
    try {
      _url.callMethod<JSAny?>('revokeObjectURL'.toJS, url.toJS);
    } catch (_) {}
  }

  @override
  bool download(String fileName) {
    final blob = _blob;
    if (blob == null) return false;
    try {
      final url = _url.callMethod<JSString>('createObjectURL'.toJS, blob).toDart;
      // Kurz offen halten, damit der Browser den Download sicher beginnt.
      _urls[url] = Timer(const Duration(seconds: 10), () => _revoke(url));
      final doc = globalContext['document'] as JSObject;
      final body = doc['body'] as JSObject;
      final a = doc.callMethod<JSObject>('createElement'.toJS, 'a'.toJS)
        ..['href'] = url.toJS
        ..['download'] = fileName.toJS
        ..['rel'] = 'noopener'.toJS;
      (a['style'] as JSObject)['display'] = 'none'.toJS;
      body.callMethod<JSAny?>('appendChild'.toJS, a);
      a.callMethod<JSAny?>('click'.toJS);
      body.callMethod<JSAny?>('removeChild'.toJS, a);
      return true;
    } catch (_) {
      return false;
    }
  }

  @override
  void release() {
    for (final url in _urls.keys.toList()) {
      _revoke(url);
    }
    _blob = null;
  }
}
