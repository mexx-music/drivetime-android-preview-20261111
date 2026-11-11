// Conditional export: use web implementation when dart:html is available, otherwise use the stub
export 'io_helpers.dart' if (dart.library.html) 'web_helpers.dart';
