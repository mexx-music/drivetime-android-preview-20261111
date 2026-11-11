import 'package:flutter_test/flutter_test.dart';

import 'package:driverroute_eta/utils/polyline.dart';

/// Dieser Test muss ZUSÄTZLICH im Browser laufen:
///   flutter test --platform chrome test/polyline_test.dart
/// Der ursprüngliche Decoder benutzte `~x`, was unter dart2js ein
/// vorzeichenloses 32-Bit-Ergebnis liefert. In der VM war alles grün, im
/// Browser kamen Koordinaten wie 193.874.870 heraus – genau der Grund,
/// warum die Routenberechnung im Web einfror.
void main() {
  test('dekodiert das Google-Beispiel exakt', () {
    // Referenzbeispiel aus der Google-Dokumentation.
    final pts = decodePolyline('_p~iF~ps|U_ulLnnqC_mqNvxq`@');
    expect(pts, hasLength(3));
    expect(pts[0].latitude, closeTo(38.5, 0.00001));
    expect(pts[0].longitude, closeTo(-120.2, 0.00001));
    expect(pts[1].latitude, closeTo(40.7, 0.00001));
    expect(pts[1].longitude, closeTo(-120.95, 0.00001));
    expect(pts[2].latitude, closeTo(43.252, 0.00001));
    expect(pts[2].longitude, closeTo(-126.453, 0.00001));
  });

  test('negative Deltas bleiben negativ (dart2js-Falle)', () {
    // Enthält ausschließlich negative Verschiebungen.
    final pts = decodePolyline('_p~iF~ps|U~ulL_nqC');
    expect(pts, hasLength(2));
    expect(pts[1].latitude, lessThan(pts[0].latitude));
    expect(pts[1].longitude, greaterThan(pts[0].longitude));
  });

  test('alle Punkte liegen im gültigen Koordinatenbereich', () {
    final pts = decodePolyline('_p~iF~ps|U_ulLnnqC_mqNvxq`@');
    for (final p in pts) {
      expect(p.latitude.abs(), lessThanOrEqualTo(90));
      expect(p.longitude.abs(), lessThanOrEqualTo(180));
    }
  });
}
