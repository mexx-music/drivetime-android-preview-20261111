import 'package:driverroute_eta/animation/tour_story.dart';
import 'package:driverroute_eta/ui/tour_story_overlay.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

/// Länderfolge Bursa → Odense (9 Länder, 8 Grenzübertritte).
const _route = ['TR', 'GR', 'BG', 'RO', 'HU', 'AT', 'CZ', 'DE', 'DK'];
const _crossKm = [422.0, 554.0, 1067.0, 1471.0, 1854.0, 1997.0, 2320.0, 3009.0];

List<TourStoryEvent> _borders() => [
      for (var i = 0; i < _crossKm.length; i++)
        TourStoryEvent(
          kind: TourStoryKind.borderCrossing,
          meters: _crossKm[i] * 1000,
          km: _crossKm[i],
          fromIso: _route[i],
          toIso: _route[i + 1],
        ),
    ];

Future<void> _pumpHud(WidgetTester tester, double km) => tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: TourStoryHud(
          title: 'Bursa → Odense',
          km: '🚛 ${km.round()} / 3.161 km',
          progress: km / 3161,
          frame: TourFrame(meters: km * 1000),
          events: _borders(),
          startIso: 'TR',
        ),
      ),
    ));

/// Deckkraft der Flagge (steckt im Bild, nicht in einer eigenen Ebene).
double _flagOpacity(WidgetTester tester, String key) {
  final inner = tester.widget<Container>(
      find.descendant(of: find.byKey(Key(key)), matching: find.byType(Container)).last);
  return (inner.decoration! as BoxDecoration).image!.opacity;
}

/// Rahmenfarbe (Hervorhebung) der Flagge.
Color _frame(WidgetTester tester, String key) {
  final outer = tester.widget<Container>(find.byKey(Key(key)));
  return ((outer.decoration! as BoxDecoration).border! as Border).top.color;
}

void main() {
  testWidgets('Flaggenleiste: keine eigene Ebene je Flagge (Opacity/ClipRRect)', (tester) async {
    // Gemessen: jede Flagge als Opacity-/ClipRRect-Ebene über der Karte kostete
    // in Chrome ≈ 30–35 MB GPU-Speicher; bei 9 Ländern ≈ 370 MB über die ganze
    // Tour – auf dem iPhone der Kipppunkt. Die Leiste muss ohne Ebenen je
    // Flagge auskommen.
    await _pumpHud(tester, 790);
    final hud = find.byKey(const Key('tour-hud'));
    expect(find.descendant(of: hud, matching: find.byType(Opacity)), findsNothing);
    expect(find.descendant(of: hud, matching: find.byType(ClipRRect)), findsNothing);
    expect(find.descendant(of: hud, matching: find.byType(FadeTransition)), findsNothing);
    // Auch indirekt nicht: keine Opacity- oder RRect-Clip-Ebene im Ebenenbaum.
    expect(tester.layers.whereType<OpacityLayer>(), isEmpty);
    expect(tester.layers.whereType<ClipRRectLayer>(), isEmpty);
  });

  testWidgets('Flaggenleiste: alle Länder, durchfahren/aktuell/kommend wie bisher', (tester) async {
    await _pumpHud(tester, 790); // in Bulgarien
    for (var i = 0; i < _route.length; i++) {
      expect(find.byKey(Key('strip-$i-${_route[i]}')), findsOneWidget);
    }
    expect(_flagOpacity(tester, 'strip-0-TR'), closeTo(0.5, 1e-9)); // durchfahren
    expect(_flagOpacity(tester, 'strip-1-GR'), closeTo(0.5, 1e-9));
    expect(_flagOpacity(tester, 'strip-2-BG'), 1); // aktuell
    expect(_flagOpacity(tester, 'strip-3-RO'), closeTo(0.28, 1e-9)); // kommend
    expect(_flagOpacity(tester, 'strip-8-DK'), closeTo(0.28, 1e-9));
    // Nur das aktuelle Land gerahmt.
    expect(_frame(tester, 'strip-2-BG').a, 1);
    expect(_frame(tester, 'strip-1-GR').a, 0);
    expect(_frame(tester, 'strip-3-RO').a, 0);
  });
}
