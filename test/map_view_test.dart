import 'package:driverroute_eta/ui/map_osm_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';

/// Kacheln, die die Karte gerade tatsächlich anzeigt.
///
/// `Tile` ist in flutter_map nicht exportiert; die Koordinaten stehen am
/// ebenfalls nicht exportierten Widget-Feld `tileImage`.
List<TileCoordinates> _shownTiles(WidgetTester tester) => [
      for (final w in tester.widgetList(
          find.byWidgetPredicate((w) => w.runtimeType.toString() == 'Tile')))
        (w as dynamic).tileImage.coordinates as TileCoordinates,
    ];

/// Kamera der geöffneten Karte.
MapCamera _camera(WidgetTester tester) =>
    MapCamera.of(tester.element(find.byType(MarkerLayer)));

void main() {
  // Lambach → Hamburg, grob wie die berechnete Route.
  const start = LatLng(48.09, 13.87);
  const dest = LatLng(53.55, 9.99);
  final route = [
    start,
    const LatLng(49.45, 11.08),
    const LatLng(51.3, 10.4),
    dest,
  ];

  Future<void> openMap(WidgetTester tester, {MapController? controller}) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1280, 900);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    await tester.pumpWidget(MaterialApp(
      home: MapOsmView(start: start, dest: dest, route: route, mapController: controller),
    ));
    // Keine Geste, keine Bewegung: nur die Frames nach dem Öffnen.
    await tester.pumpAndSettle();
  }

  /// Die angezeigten Kacheln müssen zum aktuellen Kartenausschnitt gehören –
  /// sonst bleibt die Karte grau, bis man sie bewegt.
  void expectTilesMatchCamera(WidgetTester tester) {
    final camera = _camera(tester);
    final tiles = _shownTiles(tester);
    expect(tiles, isNotEmpty, reason: 'keine Kacheln angezeigt');

    final zoom = camera.zoom.round();
    expect(tiles.map((t) => t.z).toSet(), {zoom},
        reason: 'Kacheln einer anderen Zoomstufe als die Karte (${camera.zoom})');

    // Die Kachel unter dem Kartenmittelpunkt muss dabei sein.
    final c = camera.crs.latLngToOffset(camera.center, zoom.toDouble());
    final centerTile = (x: (c.dx / 256).floor(), y: (c.dy / 256).floor());
    expect(tiles.any((t) => t.x == centerTile.x && t.y == centerTile.y), isTrue,
        reason: 'Kachel unter dem Kartenmittelpunkt fehlt');
  }

  /// Die Ursache des grauen Kartenbilds: Die Kachelebene lädt und verwirft
  /// Kacheln anhand der Kamera, die ein Kartenereignis mitbringt. Kommt nach
  /// dem Einpassen noch ein Ereignis mit der alten Kamera (Zoom 5), bleibt die
  /// Karte im Browser grau, bis man sie bewegt. Im Test laden Kachelbilder nie
  /// wirklich, deshalb wird die Reihenfolge der Ereignisse selbst geprüft.
  Future<void> expectLastEventCarriesCurrentCamera(
      WidgetTester tester, MapController c, List<MapEvent> events) async {
    expect(events, isNotEmpty);
    final last = events.last;
    expect(last.camera.zoom, closeTo(c.camera.zoom, 1e-9),
        reason: 'letztes Ereignis ${last.runtimeType} trägt Zoom ${last.camera.zoom}, '
            'die Karte steht aber auf ${c.camera.zoom}');
    expect(last.camera.center, c.camera.center);
    // Nach dem Einpassen darf kein Ereignis mehr mit dem Startzoom kommen.
    final fitIndex = events.lastIndexWhere((e) => e.camera.zoom != 5);
    expect(events.skip(fitIndex + 1).where((e) => e.camera.zoom == 5), isEmpty);
  }

  testWidgets('beim Öffnen: kein veraltetes Kartenereignis nach dem Einpassen', (tester) async {
    final c = MapController();
    final events = <MapEvent>[];
    final sub = c.mapEventStream.listen(events.add);
    addTearDown(sub.cancel);
    await openMap(tester, controller: c);
    expect(c.camera.zoom, isNot(5), reason: 'Route nicht eingepasst');
    await expectLastEventCarriesCurrentCamera(tester, c, events);
  });

  testWidgets('erneutes Öffnen: ebenfalls kein veraltetes Ereignis', (tester) async {
    await openMap(tester, controller: MapController());
    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    await tester.pumpAndSettle();
    final c = MapController();
    final events = <MapEvent>[];
    final sub = c.mapEventStream.listen(events.add);
    addTearDown(sub.cancel);
    await openMap(tester, controller: c);
    await expectLastEventCarriesCurrentCamera(tester, c, events);
  });

  testWidgets('beim Öffnen: Route eingepasst und passende Kacheln angezeigt', (tester) async {
    await openMap(tester);

    // Route sichtbar eingepasst.
    final bounds = _camera(tester).visibleBounds;
    for (final p in route) {
      expect(bounds.contains(p), isTrue, reason: 'Routenpunkt $p außerhalb');
    }
    expect(_camera(tester).zoom, isNot(5), reason: 'Startzoom statt eingepasster Route');

    expectTilesMatchCamera(tester);
    expect(tester.takeException(), isNull);
  });

  testWidgets('erneutes Öffnen verhält sich identisch', (tester) async {
    await openMap(tester);
    final firstZoom = _camera(tester).zoom;
    final firstCenter = _camera(tester).center;

    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    await tester.pumpAndSettle();
    await openMap(tester);

    expect(_camera(tester).zoom, firstZoom);
    expect(_camera(tester).center, firstCenter);
    expectTilesMatchCamera(tester);
    expect(tester.takeException(), isNull);
  });

  testWidgets('"Auf Route zoomen" nach eigenem Verschieben passt wieder ein', (tester) async {
    await openMap(tester);
    final fitted = _camera(tester);
    await tester.drag(find.byType(FlutterMap), const Offset(300, 200));
    await tester.pumpAndSettle();
    expect(_camera(tester).center, isNot(fitted.center));

    await tester.tap(find.byTooltip('Auf Route zoomen'));
    await tester.pumpAndSettle();
    expect(_camera(tester).zoom, closeTo(fitted.zoom, 1e-9));
    expectTilesMatchCamera(tester);
  });
}
