import 'dart:convert';
import 'dart:io';

import 'package:driverroute_eta/animation/country_borders.dart';
import 'package:driverroute_eta/logic/ferry_leg_plan.dart';
import 'package:driverroute_eta/models/map_waypoint.dart';
import 'package:driverroute_eta/models/route_preset.dart';
import 'package:driverroute_eta/ui/map_point_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';

void main() {
  // Widget-Tests: OSM-Rasterkarte statt MapLibre (Plattformansicht).
  setUpAll(() => debugMapPickerUseMapLibre = false);

  const thessaloniki = LatLng(40.640123, 22.944456);

  group('Kartenpunkt als Zwischenstopp', () {
    test('Text trägt die volle Koordinate, Anzeige ohne sie', () {
      final label = MapWaypoint.label(thessaloniki, country: 'Griechenland');
      expect(label, '📍 Kartenpunkt · Griechenland @40.640123,22.944456');
      expect(MapWaypoint.display(label), '📍 Kartenpunkt · Griechenland');
      expect(MapWaypoint.shortCoordinates(label), '40.6401, 22.9445');
      expect(MapWaypoint.parse(label), thessaloniki);
      expect(MapWaypoint.isMapPoint(label), isTrue);
    });

    test('für Directions: genau lat,lng – kein Ortsname nötig', () {
      final label = MapWaypoint.label(thessaloniki, country: 'Griechenland');
      expect(MapWaypoint.routing(label), '40.640123,22.944456');
      final noCountry = MapWaypoint.label(const LatLng(-33.9, 151.2));
      expect(noCountry, '📍 Kartenpunkt @-33.900000,151.200000');
      expect(MapWaypoint.routing(noCountry), '-33.900000,151.200000');
      expect(MapWaypoint.display(noCountry), '📍 Kartenpunkt');
    });

    test('Text-Stopps bleiben vollständig unverändert', () {
      for (final s in ['Nürnberg', 'Thessaloniki, Griechenland', 'Hafen @ Bari', '40.1,22.2']) {
        expect(MapWaypoint.isMapPoint(s), isFalse);
        expect(MapWaypoint.routing(s), s);
        expect(MapWaypoint.display(s), s);
        expect(MapWaypoint.shortCoordinates(s), isNull);
      }
    });

    test('ungültige Koordinaten werden nicht als Kartenpunkt gelesen', () {
      expect(MapWaypoint.parse('📍 Kartenpunkt @95.0,10.0'), isNull);
      expect(MapWaypoint.parse('📍 Kartenpunkt @10.0,190.0'), isNull);
      expect(MapWaypoint.parse('📍 Kartenpunkt ohne Koordinate'), isNull);
    });

    test('Routen-Vorlage: Kartenpunkt übersteht Speichern, Laden und Umkehren', () {
      final label = MapWaypoint.label(thessaloniki, country: 'Griechenland');
      final preset = RoutePreset(id: 'p1', name: 'Balkan', stops: ['Sofia', label]);
      final restored =
          RoutePreset.fromJson(jsonDecode(jsonEncode(preset.toJson())) as Map<String, dynamic>)!;
      expect(restored.stops.last, label);
      expect(MapWaypoint.parse(restored.stops.last), thessaloniki);
      expect(restored.reversed.stops.first, label);
    });

    test('Fähre: Kartenpunkt wird über seine Koordinate vor/nach der Fähre einsortiert', () {
      final split = FerryLegPlan.splitStops(
        stops: [MapWaypoint.routing(MapWaypoint.label(thessaloniki)), 'Rom'],
        stopCoords: [thessaloniki, const LatLng(41.9, 12.5)],
        portFrom: const LatLng(39.50, 20.26), // Igoumenitsa
        portTo: const LatLng(41.13, 16.87), // Bari
      );
      expect(split.before, ['40.640123,22.944456']);
      expect(split.after, ['Rom']);
    });
  });

  // ============================================================ Karte
  group('Auf Karte wählen', () {
    late CountryIndex europe;
    setUpAll(() {
      europe = CountryIndex.fromJson(
          jsonDecode(File(CountryIndex.assetPath).readAsStringSync()) as Map<String, dynamic>);
    });

    Future<PickedMapPoint?> open(WidgetTester tester, {LatLng center = const LatLng(48.2, 16.37)}) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(1000, 900);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      PickedMapPoint? result;
      await tester.pumpWidget(MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: TextButton(
                onPressed: () async {
                  result = await Navigator.of(context).push<PickedMapPoint>(MaterialPageRoute(
                    builder: (_) => MapPointPicker(
                      initialCenter: center,
                      initialZoom: 9,
                      showTiles: false,
                      countries: Future.value(europe),
                    ),
                  ));
                },
                child: const Text('öffnen'),
              ),
            ),
          ),
        ),
      ));
      await tester.tap(find.text('öffnen'));
      await tester.pumpAndSettle();
      return result;
    }

    Future<void> tapMap(WidgetTester tester, Offset offset) async {
      final c = tester.getCenter(find.byType(FlutterMap));
      await tester.tapAt(c + offset);
      await tester.pump(const Duration(milliseconds: 400)); // Doppeltipp-Fenster
      await tester.pump();
    }

    Finder accept() => find.ancestor(
        of: find.text('Als Zwischenpunkt übernehmen'),
        matching: find.byWidgetPredicate((w) => w is ButtonStyleButton));

    testWidgets('ohne Punkt nichts zu übernehmen', (tester) async {
      await open(tester);
      expect(find.byKey(const Key('picked-marker')), findsNothing);
      expect(tester.widget<ButtonStyleButton>(accept()).onPressed, isNull);
      expect(find.text('Noch kein Punkt gewählt'), findsOneWidget);
    });

    testWidgets('Tippen setzt Marker, erneutes Tippen versetzt ihn; Land aus lokalen Grenzen',
        (tester) async {
      PickedMapPoint? result;
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(1000, 900);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      await tester.pumpWidget(MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () async {
              result = await Navigator.of(context).push<PickedMapPoint>(MaterialPageRoute(
                builder: (_) => MapPointPicker(
                  initialCenter: const LatLng(48.2, 16.37), // Wien
                  initialZoom: 9,
                  showTiles: false,
                  countries: Future.value(europe),
                ),
              ));
            },
            child: const Text('öffnen'),
          ),
        ),
      ));
      await tester.tap(find.text('öffnen'));
      await tester.pumpAndSettle();

      await tapMap(tester, Offset.zero); // Wien
      expect(find.byKey(const Key('picked-marker')), findsOneWidget);
      expect(find.text('📍 Kartenpunkt · Österreich'), findsOneWidget);
      final first = tester.widget<Text>(find.byKey(const Key('picked-coordinates'))).data;

      await tapMap(tester, const Offset(220, 0)); // weiter östlich: Slowakei
      expect(find.byKey(const Key('picked-marker')), findsOneWidget); // weiterhin genau einer
      expect(tester.widget<Text>(find.byKey(const Key('picked-coordinates'))).data, isNot(first));
      expect(find.text('📍 Kartenpunkt · Slowakei'), findsOneWidget);

      await tester.tap(accept());
      await tester.pumpAndSettle();
      expect(result, isNotNull);
      expect(result!.country, 'Slowakei');
      expect(result!.point.longitude, greaterThan(16.9));
      expect(europe.countryAt(result!.point), 'SK');
    });

    testWidgets('Abbrechen liefert nichts', (tester) async {
      await open(tester);
      await tapMap(tester, Offset.zero);
      await tester.tap(find.byTooltip('Abbrechen'));
      await tester.pumpAndSettle();
      expect(find.byType(MapPointPicker), findsNothing);
    });

    testWidgets('auf See: Punkt ohne Land, Koordinate genügt', (tester) async {
      PickedMapPoint? result;
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(1000, 900);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      await tester.pumpWidget(MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () async {
              result = await Navigator.of(context).push<PickedMapPoint>(MaterialPageRoute(
                builder: (_) => MapPointPicker(
                  initialCenter: const LatLng(42.5, 16.0), // Adria
                  initialZoom: 9,
                  showTiles: false,
                  countries: Future.value(europe),
                ),
              ));
            },
            child: const Text('öffnen'),
          ),
        ),
      ));
      await tester.tap(find.text('öffnen'));
      await tester.pumpAndSettle();
      await tapMap(tester, Offset.zero);
      expect(find.text('📍 Kartenpunkt'), findsOneWidget);
      await tester.tap(accept());
      await tester.pumpAndSettle();
      expect(result!.country, isNull);
      expect(MapWaypoint.label(result!.point), startsWith('📍 Kartenpunkt @42.'));
    });
  });
}
