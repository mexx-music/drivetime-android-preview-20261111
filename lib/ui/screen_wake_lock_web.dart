// Screen Wake Lock API: `navigator.wakeLock.request('screen')`.
//
// Der Browser gibt die Sperre selbst frei, wenn der Tab verdeckt wird. Solange
// sie gewünscht ist, wird sie bei Rückkehr (visibilitychange → visible) neu
// angefordert. Alle Fehler bleiben folgenlos (nur Debug-Ausgabe).

import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:flutter/foundation.dart';

import 'screen_wake_lock.dart';

ScreenWakeLock createPlatformScreenWakeLock() => _WebWakeLock();

class _WebWakeLock implements ScreenWakeLock {
  JSObject? _sentinel;
  bool _wanted = false;
  bool _requesting = false;
  JSFunction? _visibilityListener;

  JSObject? get _api {
    try {
      final nav = globalContext['navigator'];
      if (nav == null || !nav.typeofEquals('object')) return null;
      final wl = (nav as JSObject)['wakeLock'];
      if (wl == null || !wl.typeofEquals('object')) return null;
      final req = (wl as JSObject)['request'];
      return req != null && req.typeofEquals('function') ? wl : null;
    } catch (_) {
      return null;
    }
  }

  JSObject? get _document {
    final d = globalContext['document'];
    return d != null && d.typeofEquals('object') ? d as JSObject : null;
  }

  bool get _visible {
    try {
      final state = _document?['visibilityState'];
      return state == null || !state.typeofEquals('string') || (state as JSString).toDart == 'visible';
    } catch (_) {
      return true;
    }
  }

  @override
  bool get supported => _api != null;

  void _log(String message) {
    if (kDebugMode) debugPrint('[ScreenWakeLock] $message');
  }

  @override
  Future<void> acquire() async {
    _wanted = true;
    _watchVisibility();
    await _request();
  }

  Future<void> _request() async {
    final api = _api;
    if (api == null || !_wanted || _sentinel != null || _requesting) return;
    // Verdeckt lehnt der Browser ab; bei Rückkehr wird erneut angefordert.
    if (!_visible) return;
    _requesting = true;
    try {
      final sentinel = await api.callMethod<JSPromise<JSObject>>('request'.toJS, 'screen'.toJS).toDart;
      if (!_wanted) {
        // Inzwischen freigegeben (Animation geschlossen): sofort zurückgeben.
        await _releaseSentinel(sentinel);
        return;
      }
      _sentinel = sentinel;
      sentinel.callMethod<JSAny?>(
        'addEventListener'.toJS,
        'release'.toJS,
        ((JSAny? _) {
          if (identical(_sentinel, sentinel)) _sentinel = null;
        }).toJS,
      );
    } catch (e) {
      _log('nicht erhalten: $e');
    } finally {
      _requesting = false;
    }
  }

  @override
  Future<void> release() async {
    _wanted = false;
    _unwatchVisibility();
    final s = _sentinel;
    _sentinel = null;
    if (s != null) await _releaseSentinel(s);
  }

  Future<void> _releaseSentinel(JSObject sentinel) async {
    try {
      final released = sentinel['released'];
      if (released != null && released.typeofEquals('boolean') && (released as JSBoolean).toDart) return;
      await sentinel.callMethod<JSPromise<JSAny?>>('release'.toJS).toDart;
    } catch (e) {
      _log('Freigabe fehlgeschlagen: $e');
    }
  }

  void _watchVisibility() {
    if (_visibilityListener != null) return;
    final doc = _document;
    if (doc == null) return;
    final listener = ((JSAny? _) {
      if (_wanted && _visible) _request();
    }).toJS;
    try {
      doc.callMethod<JSAny?>('addEventListener'.toJS, 'visibilitychange'.toJS, listener);
      _visibilityListener = listener;
    } catch (_) {}
  }

  void _unwatchVisibility() {
    final listener = _visibilityListener;
    _visibilityListener = null;
    if (listener == null) return;
    try {
      _document?.callMethod<JSAny?>('removeEventListener'.toJS, 'visibilitychange'.toJS, listener);
    } catch (_) {}
  }
}
