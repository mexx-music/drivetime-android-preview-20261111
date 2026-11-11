import 'dart:js_interop';

@JS('Intl.DateTimeFormat')
external JSObject _dateTimeFormat();

extension type _Resolved(JSObject _) implements JSObject {
  external String get timeZone;
}

extension type _Format(JSObject _) implements JSObject {
  external _Resolved resolvedOptions();
}

String? browserTimeZone() {
  try {
    return _Format(_dateTimeFormat()).resolvedOptions().timeZone;
  } catch (_) {
    return null;
  }
}
