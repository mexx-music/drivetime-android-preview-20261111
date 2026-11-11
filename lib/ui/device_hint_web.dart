import 'dart:js_interop';
import 'dart:js_interop_unsafe';

/// Touch-Gerät (iPad, Smartphone): grober Zeiger laut Browser oder
/// Berührungspunkte. iPadOS meldet sich als „Macintosh“, hat aber
/// Berührungspunkte.
bool isTouchDevice() {
  try {
    final w = globalContext;
    final mq = w.callMethod<JSObject>('matchMedia'.toJS, '(pointer: coarse)'.toJS);
    if ((mq['matches'] as JSBoolean).toDart) return true;
    final nav = w['navigator'] as JSObject;
    final points = nav['maxTouchPoints'];
    return points != null && (points as JSNumber).toDartInt > 0;
  } catch (_) {
    return false;
  }
}
