import 'package:driverroute_eta/animation/tour_camera.dart';
import 'package:driverroute_eta/animation/tour_path.dart';
import 'package:driverroute_eta/ui/map_label_style.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';

/// Gerade Linie mit [n] Punkten.
List<LatLng> _line(LatLng a, LatLng b, int n) => [
      for (var i = 0; i < n; i++)
        LatLng(a.latitude + (b.latitude - a.latitude) * i / (n - 1),
            a.longitude + (b.longitude - a.longitude) * i / (n - 1)),
    ];

void main() {
  group('Kartenbeschriftung (OpenFreeMap-Stil)', () {
    // Ausdrücke wie im echten Stil „Liberty“ (Stand der Prüfung).
    const liberty = {
      'version': 8,
      'layers': [
        {
          'id': 'place_city',
          'type': 'symbol',
          'source-layer': 'place',
          'layout': {
            'text-field': [
              'case',
              ['has', 'name:nonlatin'],
              ['concat', ['get', 'name:latin'], '\n', ['get', 'name:nonlatin']],
              ['coalesce', ['get', 'name_en'], ['get', 'name']]
            ],
            'text-size': 14,
          },
        },
        {
          'id': 'highway-shield',
          'type': 'symbol',
          'layout': {
            'text-field': ['to-string', ['get', 'ref']]
          },
        },
        {'id': 'water', 'type': 'fill', 'paint': {'fill-color': '#9cf'}},
        {
          'id': 'legacy',
          'type': 'symbol',
          'layout': {'text-field': '{name:latin}\n{name:nonlatin}'},
        },
      ],
    };

    test('Orte: Länder/Hauptstädte deutsch, übrige lateinisch; nie Originalschrift daneben', () {
      final out = latinizeStyle(liberty);
      final layers = (out['layers'] as List).cast<Map<String, dynamic>>();
      expect(layers[0]['layout']['text-field'], placeNameExpression); // source-layer place
      expect(layers[3]['layout']['text-field'], latinFirstName); // sonstige Beschriftung
      for (final e in [germanFirstName, latinFirstName, placeNameExpression]) {
        expect(e.toString(), isNot(contains('nonlatin')));
      }
      expect((germanFirstName[1] as List)[1], 'name:de');
      expect((latinFirstName[1] as List)[1], 'name:latin');
      expect((latinFirstName.last as List)[1], 'name'); // lokal nur als Rückfall
      expect(placeNameExpression.toString(), contains('capital'));
    });

    test('Gewässer deutsch (Mittelmeer), Straßen lateinisch', () {
      expect(nameExpressionFor({'source-layer': 'water_name'}), germanFirstName);
      expect(nameExpressionFor({'source-layer': 'transportation_name'}), latinFirstName);
      expect(nameExpressionFor({'source-layer': 'place'}), placeNameExpression);
    });

    test('Straßennummern und andere Ebenen bleiben unverändert', () {
      final out = latinizeStyle(liberty);
      final layers = (out['layers'] as List).cast<Map<String, dynamic>>();
      expect(layers[1]['layout']['text-field'], ['to-string', ['get', 'ref']]);
      expect(layers[2], (liberty['layers'] as List)[2]);
      expect(layers[0]['layout']['text-size'], 14);
      // Original nicht verändert.
      expect(((liberty['layers'] as List)[0] as Map)['layout']['text-field'], isNot(placeNameExpression));
    });

    test('Erkennung, ob eine Beschriftung einen Namen zeigt', () {
      expect(showsName('{name}'), isTrue);
      expect(showsName(['get', 'name_en']), isTrue);
      expect(showsName(['get', 'ref']), isFalse);
      expect(showsName(null), isFalse);
    });
  });

  group('2.5D-Kamera', () {
    test('gerade Strecke: Blick in Fahrtrichtung, Ziel vor dem LKW', () {
      final path = TourPath([TourLeg(points: _line(const LatLng(48, 10), const LatLng(48, 14), 400))]);
      final rig = TourCameraRig(path);
      expect(rig.headingAt(path.totalMeters / 2), closeTo(90, 2)); // Osten
      final mid = path.totalMeters / 2;
      final target = rig.targetAt(mid);
      expect(target.longitude, greaterThan(path.at(mid).point.longitude)); // voraus
      expect(rig.pitch, inInclusiveRange(40, 45));
      expect(rig.zoom, greaterThan(tourFollowZoom(path.totalMeters)));
    });

    test('kleine Kurven drehen die Karte kaum (Zickzack um eine Ostrichtung)', () {
      final pts = <LatLng>[];
      for (var i = 0; i <= 400; i++) {
        pts.add(LatLng(48 + (i.isOdd ? 0.004 : -0.004), 10 + i * 0.01)); // ±450 m alle ~750 m
      }
      final path = TourPath([TourLeg(points: pts)]);
      final rig = TourCameraRig(path);
      double? min, max;
      for (var m = 0.0; m <= path.totalMeters; m += 500) {
        final b = rig.step(m, const Duration(milliseconds: 16));
        min = min == null ? b : (b < min ? b : min);
        max = max == null ? b : (b > max ? b : max);
      }
      expect(max! - min!, lessThan(4)); // kein Pendeln
    });

    test('echte Richtungsänderung: begrenzte, weiche Drehung', () {
      // 100 km Osten, dann 100 km Norden.
      const a = LatLng(48, 10);
      final b = const Distance().offset(a, 100000, 90);
      final c = const Distance().offset(b, 100000, 0);
      final path = TourPath([
        TourLeg(points: [..._line(a, b, 200), ..._line(b, c, 200).skip(1)])
      ]);
      final rig = TourCameraRig(path);
      const dt = Duration(milliseconds: 16);
      var last = rig.step(0, dt);
      var maxStep = 0.0;
      for (var m = 0.0; m <= path.totalMeters; m += 200) {
        final now = rig.step(m, dt);
        maxStep = maxStep < angleDiff(last, now).abs() ? angleDiff(last, now).abs() : maxStep;
        last = now;
      }
      expect(maxStep, lessThanOrEqualTo(22 * 0.016 + 1e-9)); // ≤ 22°/s
      // Nach Ende der Kurve und etwas Zeit zeigt die Kamera nach Norden.
      for (var i = 0; i < 600; i++) {
        last = rig.step(path.totalMeters - 5000, dt);
      }
      expect(angleDiff(last, 0).abs(), lessThan(3));
    });

    test('Neustart: Kamera beginnt wieder in der Startrichtung', () {
      final path = TourPath([TourLeg(points: _line(const LatLng(48, 10), const LatLng(49, 10), 100))]);
      final rig = TourCameraRig(path);
      rig.step(50000, const Duration(seconds: 1));
      rig.reset();
      expect(rig.bearing, isNull);
      expect(rig.step(0, Duration.zero), closeTo(0, 2)); // Norden
    });

    test('Winkeldifferenz über 0°/360° hinweg', () {
      expect(angleDiff(350, 10), 20);
      expect(angleDiff(10, 350), -20);
      expect(angleDiff(0, 180).abs(), 180);
    });
  });
}
