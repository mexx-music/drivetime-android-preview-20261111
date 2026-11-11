import 'screen_wake_lock.dart';

/// Ohne Browser (native Apps, Tests): keine Wirkung.
ScreenWakeLock createPlatformScreenWakeLock() => const _NoWakeLock();

class _NoWakeLock implements ScreenWakeLock {
  const _NoWakeLock();

  @override
  bool get supported => false;

  @override
  Future<void> acquire() async {}

  @override
  Future<void> release() async {}
}
