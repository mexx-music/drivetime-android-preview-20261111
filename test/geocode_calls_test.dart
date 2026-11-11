import 'dart:convert';

import 'package:driverroute_eta/main.dart';
import 'package:driverroute_eta/services/maps_proxy.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Zählt die Google-Aufrufe, die bei der Adresseingabe tatsächlich beim Proxy
/// ankommen. Die App läuft dafür auf dem Web-Weg (über den Proxy), obwohl der
/// Test in der VM läuft; der Proxy selbst ist ein Fake.

/// Bekannte Orte des Fake-Proxys: Suchtext → (Beschreibung, lat, lng).
const _places = {
  'Lambach': ('Lambach, Österreich', 48.0925, 13.8733),
  'Hamburg': ('Hamburg, Deutschland', 53.5511, 9.9937),
  'Wels': ('Wels, Österreich', 48.1575, 14.0289),
  'Sofia': ('Sofia, Bulgarien', 42.6977, 23.3219),
};

const _gpsLat = 48.123456;
const _gpsLng = 13.765432;
const _gpsAddress = 'Marktplatz 1, 4650 Lambach, Österreich';

class _FakeProxy {
  final List<String> forwardGeocodes = [];
  final List<String> reverseGeocodes = [];
  final List<Map<String, dynamic>> autocompletes = [];
  final List<Map<String, dynamic>> directions = [];

  (String, double, double)? _lookup(String text) {
    for (final entry in _places.entries) {
      if (text
          .toLowerCase()
          .startsWith(entry.key.toLowerCase().substring(0, 3))) {
        return entry.value;
      }
    }
    return null;
  }

  http.Response _json(Object body) => http.Response(
        jsonEncode(body),
        200,
        headers: {'content-type': 'application/json; charset=utf-8'},
      );

  Future<http.Response> handle(http.Request request) async {
    final body = jsonDecode(request.body) as Map<String, dynamic>;
    switch (request.url.path) {
      case '/api/autocomplete':
        autocompletes.add(body);
        final hit = _lookup(body['input'] as String);
        return _json({
          'suggestions': [
            if (hit != null)
              {
                'placePrediction': {
                  'placeId': 'id-${hit.$1}',
                  'text': {'text': hit.$1},
                },
              },
          ],
        });
      case '/api/geocode':
        if (body['address'] == null) {
          reverseGeocodes.add('${body['lat']},${body['lng']}');
          return _json({
            'status': 'OK',
            'results': [
              {
                'formatted_address': _gpsAddress,
                'geometry': {
                  // Der Adressmittelpunkt liegt bewusst neben der GPS-Position.
                  'location': {'lat': 48.1, 'lng': 13.8},
                },
              },
            ],
          });
        }
        final address = body['address'] as String;
        forwardGeocodes.add(address);
        final hit = _lookup(address);
        if (hit == null) {
          return _json({'status': 'ZERO_RESULTS', 'results': []});
        }
        return _json({
          'status': 'OK',
          'results': [
            {
              'formatted_address': hit.$1,
              'geometry': {
                'location': {'lat': hit.$2, 'lng': hit.$3},
              },
            },
          ],
        });
      case '/api/directions':
        directions.add(body);
        return _json({'status': 'ZERO_RESULTS', 'routes': []});
    }
    return http.Response('not found', 404);
  }
}

class _FakeGeolocator extends GeolocatorPlatform {
  @override
  Future<bool> isLocationServiceEnabled() async => true;

  @override
  Future<LocationPermission> checkPermission() async =>
      LocationPermission.whileInUse;

  @override
  Future<Position> getCurrentPosition({
    LocationSettings? locationSettings,
  }) async =>
      Position(
        latitude: _gpsLat,
        longitude: _gpsLng,
        timestamp: DateTime(2026, 9, 26),
        accuracy: 5,
        altitude: 0,
        altitudeAccuracy: 0,
        heading: 0,
        headingAccuracy: 0,
        speed: 0,
        speedAccuracy: 0,
      );
}

Finder _field(String label) => find.byWidgetPredicate(
    (w) => w is TextField && w.decoration?.labelText == label);

final _start = _field('Start eingeben');
final _dest = _field('Ziel eingeben');
final _stop = _field('Adresse oder Ort eingeben');

void main() {
  late _FakeProxy proxy;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    proxy = _FakeProxy();
    debugMapsDirectCallsAllowed = false;
    debugMapsProxyBase = 'https://proxy.test';
    debugMapsProxyClient = MockClient(proxy.handle);
  });

  tearDown(() {
    debugMapsDirectCallsAllowed = null;
    debugMapsProxyBase = null;
    debugMapsProxyClient = null;
  });

  Future<void> pumpApp(WidgetTester tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1280, 1600);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    await tester.pumpWidget(const DriverRouteApp());
    await tester.pumpAndSettle();
  }

  /// Tippt, wartet die Autovervollständigung ab und tippt den Vorschlag an.
  Future<void> pickSuggestion(
      WidgetTester tester, Finder field, String typed, String shortName) async {
    await tester.enterText(field, typed);
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pumpAndSettle();
    final suggestion = find.descendant(
      of: find.byType(ListTile),
      matching: find.text(shortName),
    );
    await tester.ensureVisible(suggestion);
    await tester.tap(suggestion);
    await tester.pumpAndSettle();
  }

  Future<void> calculate(WidgetTester tester) async {
    final button = find.text('Route berechnen');
    await tester.ensureVisible(button);
    await tester.tap(button);
    await tester.pumpAndSettle();
  }

  Future<void> finish(WidgetTester tester) async {
    // Snackbars und Eingabe-Timer auslaufen lassen.
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  }

  testWidgets('1) Start und Ziel per Vorschlag: je genau ein Geocode',
      (tester) async {
    await pumpApp(tester);

    await pickSuggestion(tester, _start, 'Lamb', 'Lambach');
    expect(proxy.forwardGeocodes, ['Lambach, Österreich']);

    await pickSuggestion(tester, _dest, 'Hamb', 'Hamburg');
    expect(
        proxy.forwardGeocodes, ['Lambach, Österreich', 'Hamburg, Deutschland']);

    await calculate(tester);
    // Beim Berechnen wird nichts erneut aufgelöst.
    expect(
        proxy.forwardGeocodes, ['Lambach, Österreich', 'Hamburg, Deutschland']);
    expect(proxy.reverseGeocodes, isEmpty);
    expect(proxy.directions.first['origin'], 'Lambach, Österreich');
    expect(proxy.directions.first['destination'], 'Hamburg, Deutschland');
    await finish(tester);
  });

  testWidgets('2) Zwischenstopp per Vorschlag: genau ein Geocode',
      (tester) async {
    await pumpApp(tester);
    await tester.ensureVisible(find.text('ZWISCHENSTOPPS'));
    await tester.tap(find.text('ZWISCHENSTOPPS'));
    await tester.pumpAndSettle();

    await pickSuggestion(tester, _stop, 'Sofi', 'Sofia');
    expect(proxy.forwardGeocodes, ['Sofia, Bulgarien']);

    final add = find.text('Zwischenstopp hinzufügen');
    await tester.ensureVisible(add);
    await tester.tap(add);
    await tester.pumpAndSettle();

    expect(find.text('1. Sofia, Bulgarien'), findsOneWidget);
    expect(proxy.forwardGeocodes, ['Sofia, Bulgarien']);
    await finish(tester);
  });

  testWidgets('3) Lupe und Enter: je genau ein Geocode, auch beim Berechnen',
      (tester) async {
    await pumpApp(tester);

    // Start über die Lupe.
    await tester.enterText(_start, 'Wels');
    await tester.tap(find.descendant(
        of: find.ancestor(of: _start, matching: find.byType(Column)).first,
        matching: find.byTooltip('Suchen')));
    await tester.pumpAndSettle();
    expect(find.text('Wels, Österreich'), findsWidgets);

    // Ziel über Enter.
    await tester.enterText(_dest, 'Hamburg');
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pumpAndSettle();

    expect(proxy.forwardGeocodes, ['Wels', 'Hamburg']);

    await calculate(tester);
    expect(proxy.forwardGeocodes, ['Wels', 'Hamburg']);
    expect(proxy.directions.first['origin'], 'Wels, Österreich');
    expect(proxy.directions.first['destination'], 'Hamburg, Deutschland');
    await finish(tester);
  });

  testWidgets(
      '4) Meine Position: ein Reverse-Geocode, kein Vorwärts-Geocode, '
      'GPS-Koordinaten bleiben', (tester) async {
    final previous = GeolocatorPlatform.instance;
    GeolocatorPlatform.instance = _FakeGeolocator();
    addTearDown(() => GeolocatorPlatform.instance = previous);
    await pumpApp(tester);

    await tester.tap(find.text('Meine Position'));
    await tester.pumpAndSettle();
    expect(proxy.reverseGeocodes, ['$_gpsLat,$_gpsLng']);
    expect(proxy.forwardGeocodes, isEmpty);

    // Die Zielsuche wird um die exakte GPS-Position gewichtet, nicht um den
    // Adressmittelpunkt aus dem Reverse-Geocoding.
    await pickSuggestion(tester, _dest, 'Hamb', 'Hamburg');
    expect(proxy.autocompletes.last['location'], '$_gpsLat,$_gpsLng');

    await calculate(tester);
    expect(proxy.reverseGeocodes, hasLength(1));
    expect(proxy.forwardGeocodes, ['Hamburg, Deutschland']);
    expect(proxy.directions.first['origin'], _gpsAddress);
    await finish(tester);
  });

  testWidgets('5) Nur Text eintippen und berechnen: genau ein Geocode je Feld',
      (tester) async {
    await pumpApp(tester);

    await tester.enterText(_start, 'Lambach');
    await tester.enterText(_dest, 'Hamburg');
    await tester.pumpAndSettle();
    expect(proxy.forwardGeocodes, isEmpty);

    await calculate(tester);
    expect(proxy.forwardGeocodes, ['Lambach', 'Hamburg']);
    expect(proxy.directions.first['origin'], 'Lambach, Österreich');
    expect(proxy.directions.first['destination'], 'Hamburg, Deutschland');

    // Eine zweite Berechnung ohne Änderung löst nichts erneut auf.
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
    await calculate(tester);
    expect(proxy.forwardGeocodes, ['Lambach', 'Hamburg']);
    await finish(tester);
  });

  testWidgets('6) Lambach wählen, auf Wels ändern: nie mehr Lambach',
      (tester) async {
    await pumpApp(tester);

    await pickSuggestion(tester, _start, 'Lamb', 'Lambach');
    final (_, lambachLat, lambachLng) = _places['Lambach']!;
    final (_, welsLat, welsLng) = _places['Wels']!;

    // Von Hand überschrieben, kein Vorschlag gewählt.
    await tester.enterText(_start, 'Wels');
    await tester.pumpAndSettle();

    // Die Zielsuche darf nicht mehr um Lambach gewichtet werden.
    await pickSuggestion(tester, _dest, 'Hamb', 'Hamburg');
    for (final request in proxy.autocompletes
        .where((r) => (r['input'] as String).startsWith('Hamb'))) {
      expect(request['location'], isNot('$lambachLat,$lambachLng'));
    }

    await calculate(tester);
    expect(proxy.forwardGeocodes,
        ['Lambach, Österreich', 'Hamburg, Deutschland', 'Wels']);
    expect(proxy.directions.first['origin'], 'Wels, Österreich');
    for (final call in proxy.directions) {
      expect(jsonEncode(call), isNot(contains('Lambach')));
    }
    expect(find.text('Wels, Österreich'), findsWidgets);

    // Nach der Berechnung gehören die Koordinaten zu Wels.
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
    await tester.enterText(_dest, 'Hamburg Hafen');
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pumpAndSettle();
    expect(proxy.autocompletes.last['location'], '$welsLat,$welsLng');
    await finish(tester);
  });
}
