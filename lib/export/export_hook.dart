// Videoexport: Schnittstelle zum bildgenauen Weiterschalten der Animation
// (nur Web, nur im Exportmodus). Auf anderen Plattformen ohne Wirkung.
export 'export_hook_stub.dart' if (dart.library.js_interop) 'export_hook_web.dart';
