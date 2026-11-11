// Bildschirm wach halten, solange eine Touranimation läuft.
//
// Web: Screen Wake Lock API (`navigator.wakeLock`). Andere Plattformen:
// ohne Wirkung (native Apps werden noch nicht verteilt). Fehlt die API oder
// lehnt der Browser ab, passiert nichts – die Animation läuft unverändert.

import 'package:flutter/foundation.dart';

import 'screen_wake_lock_platform.dart';

abstract class ScreenWakeLock {
  /// Der Browser kennt die Screen Wake Lock API.
  bool get supported;

  /// Bildschirm wach halten (wiederholbar). Wirft nie; ohne Unterstützung
  /// oder bei Ablehnung ohne Wirkung. Ist der Tab gerade verdeckt, wird bei
  /// Rückkehr automatisch neu angefordert, solange nicht [release] kam.
  Future<void> acquire();

  /// Wieder freigeben (wiederholbar). Wirft nie.
  Future<void> release();
}

/// Nur für Tests: ersetzt die Plattformumsetzung.
@visibleForTesting
ScreenWakeLock? debugScreenWakeLockOverride;

ScreenWakeLock? _platform;

/// Umsetzung der aktuellen Plattform (eine je App).
ScreenWakeLock screenWakeLock() => debugScreenWakeLockOverride ?? (_platform ??= createPlatformScreenWakeLock());
