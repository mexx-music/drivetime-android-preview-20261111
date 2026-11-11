// Bildschirm wach halten während der Touranimation (Screen Wake Lock).
// Die Browser-API ist über [debugScreenWakeLockOverride] ersetzt.

import 'package:driverroute_eta/animation/tour_path.dart';
import 'package:driverroute_eta/main.dart';
import 'package:driverroute_eta/ui/screen_wake_lock.dart';
import 'package:driverroute_eta/ui/screen_wake_lock_platform.dart' as platform;
import 'package:driverroute_eta/ui/tour_animation_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _FakeWakeLock implements ScreenWakeLock {
  _FakeWakeLock({this.fail = false});
  final bool fail;
  final List<String> calls = [];
  bool held = false;

  int get acquires => calls.where((c) => c == 'acquire').length;
  int get releases => calls.where((c) => c == 'release').length;

  @override
  bool get supported => true;

  @override
  Future<void> acquire() async {
    calls.add('acquire');
    if (fail) throw StateError('NotAllowedError');
    held = true;
  }

  @override
  Future<void> release() async {
    calls.add('release');
    if (fail) throw StateError('kaputt');
    held = false;
  }
}

List<LatLng> _line(LatLng a, LatLng b, int n) => [
      for (var i = 0; i <= n; i++)
        LatLng(a.latitude + (b.latitude - a.latitude) * i / n, a.longitude + (b.longitude - a.longitude) * i / n),
    ];

void main() {
  late _FakeWakeLock lock;
  final path = TourPath([
    TourLeg(points: _line(const LatLng(48.09, 13.87), const LatLng(53.55, 9.99), 400)),
  ]);
  final total = tourAnimationDuration(path.totalMeters);

  setUp(() => debugScreenWakeLockOverride = lock = _FakeWakeLock());
  tearDown(() => debugScreenWakeLockOverride = null);

  /// Startseite mit Knopf, der die Animation als eigene Seite öffnet.
  Future<void> openView(WidgetTester tester,
      {bool autoplay = true, bool videoExport = false, bool cleanRecording = false}) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1000, 1400);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: TextButton(
              onPressed: () => Navigator.of(context).push(MaterialPageRoute(
                builder: (_) => TourAnimationView(
                  path: path,
                  title: 'Lambach → Hamburg',
                  showTiles: false,
                  autoplay: autoplay,
                  videoExport: videoExport,
                  cleanRecording: cleanRecording,
                ),
              )),
              child: const Text('öffnen'),
            ),
          ),
        ),
      ),
    ));
    expect(lock.calls, isEmpty); // Startseite: nichts wach halten
    await tester.tap(find.text('öffnen'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
  }

  Future<void> close(WidgetTester tester) async {
    await tester.binding.handlePopRoute(); // Zurück im Browser
    await tester.pumpAndSettle();
    expect(find.byType(TourAnimationView), findsNothing);
  }

  testWidgets('Animationsstart fordert an; Pause lässt aktiv; Filmende gibt frei', (tester) async {
    await openView(tester);
    expect(lock.calls, ['acquire']);
    expect(lock.held, isTrue);

    await tester.tap(find.text('Pause'));
    await tester.pump();
    expect(lock.calls, ['acquire']); // Pause: bleibt wach
    await tester.tap(find.text('Weiter'));
    await tester.pump();
    expect(lock.acquires, 1); // keine doppelte Anforderung

    await tester.pump(total * 2);
    await tester.pump(const Duration(seconds: 1));
    expect(lock.calls, ['acquire', 'release']);
    expect(lock.held, isFalse);

    // Neustart nach dem Ende: wieder wach halten.
    await tester.tap(find.text('Neustart'));
    await tester.pump();
    expect(lock.calls, ['acquire', 'release', 'acquire']);
    await close(tester);
    expect(lock.calls.last, 'release');
    expect(lock.held, isFalse);
  });

  testWidgets('erst beim tatsächlichen Start – nicht schon beim Öffnen', (tester) async {
    await openView(tester, autoplay: false);
    expect(lock.calls, isEmpty);
    await tester.tap(find.text('Start'));
    await tester.pump();
    expect(lock.calls, ['acquire']);
    await close(tester);
    expect(lock.calls, ['acquire', 'release']);
  });

  testWidgets('Schließen/Zurück mitten in der Fahrt gibt frei (Dispose)', (tester) async {
    await openView(tester);
    await tester.pump(total ~/ 3);
    expect(lock.held, isTrue);
    await tester.tap(find.byTooltip('Schließen'));
    await tester.pumpAndSettle();
    expect(lock.calls, ['acquire', 'release']);
  });

  testWidgets('geöffnet, aber nie gestartet: beim Schließen nichts freizugeben', (tester) async {
    await openView(tester, autoplay: false);
    await close(tester);
    expect(lock.calls, isEmpty);
  });

  testWidgets('Rückkehr in Tab/App während der Fahrt: erneut anfordern; nach Filmende nicht', (tester) async {
    await openView(tester);
    expect(lock.acquires, 1);
    // Tab verdeckt: der Browser gibt selbst frei – die App fordert nichts an.
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    await tester.pump();
    expect(lock.releases, 0);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    expect(lock.acquires, greaterThanOrEqualTo(2));
    final afterReturn = lock.acquires;

    await tester.pump(total * 2);
    await tester.pump(const Duration(seconds: 1));
    expect(lock.calls.last, 'release');
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    expect(lock.acquires, afterReturn); // Film ist zu Ende: nicht wieder wach halten
    await close(tester);
  });

  testWidgets('Fehler der Browser-API bleiben folgenlos: Animation läuft und endet', (tester) async {
    debugScreenWakeLockOverride = lock = _FakeWakeLock(fail: true);
    await openView(tester);
    expect(tester.takeException(), isNull);
    final progress = find.byKey(const Key('tour-progress'));
    await tester.pump(total ~/ 2);
    expect(tester.widget<LinearProgressIndicator>(progress).value, greaterThan(0.2));
    await tester.pump(total);
    await tester.pump(const Duration(seconds: 1));
    expect(tester.widget<LinearProgressIndicator>(progress).value, 1);
    expect(lock.calls, ['acquire', 'release']);
    await close(tester);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Studio-Bild-für-Bild-Export hält den Bildschirm nicht wach', (tester) async {
    await openView(tester, videoExport: true);
    await tester.pump(const Duration(seconds: 2));
    expect(lock.calls, isEmpty);
    await tester.pumpWidget(const SizedBox());
    expect(lock.calls, isEmpty);
  });

  testWidgets('Live-Aufnahme (sauberer Modus): an beim Start, frei beim Filmende', (tester) async {
    await openView(tester, cleanRecording: true);
    expect(lock.calls, ['acquire']);
    await tester.pump(total * 2);
    await tester.pump(const Duration(seconds: 1));
    expect(lock.calls, ['acquire', 'release']);
    await close(tester);
    expect(lock.calls, ['acquire', 'release']);
  });

  testWidgets('normale App-Nutzung (Startseite) hält den Bildschirm nicht wach', (tester) async {
    SharedPreferences.setMockInitialValues({});
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1280, 1800);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    await tester.pumpWidget(const DriverRouteApp());
    await tester.pumpAndSettle();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    expect(lock.calls, isEmpty);
  });

  test('ohne Browser: Stub ohne Unterstützung und ohne Wirkung', () async {
    final stub = platform.createPlatformScreenWakeLock();
    expect(stub.supported, isFalse);
    await stub.acquire();
    await stub.release();
    debugScreenWakeLockOverride = null;
    expect(screenWakeLock().supported, isFalse);
  });
}
