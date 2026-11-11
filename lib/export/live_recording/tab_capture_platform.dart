// Browseranbindung der Live-Aufnahme: im Web echte Browser-APIs, sonst Stub.
export 'tab_capture_stub.dart' if (dart.library.js_interop) 'tab_capture_web.dart';
