import 'package:flutter/foundation.dart';

import 'tab_capture.dart';

/// Ohne Browser (Apps, Tests): keine Live-Aufnahme.
TabCaptureApi createPlatformTabCaptureApi() => const _UnsupportedTabCaptureApi();

class _UnsupportedTabCaptureApi implements TabCaptureApi {
  const _UnsupportedTabCaptureApi();

  @override
  bool get apisAvailable => false;

  @override
  bool isTypeSupported(String mimeType) => false;

  @override
  Future<TabCaptureStream> requestDisplay() =>
      Future.error(const TabCaptureException('NotSupportedError', 'Keine Browserumgebung'));

  @override
  VoidCallback watchPageHidden(VoidCallback onHidden) => () {};
}
