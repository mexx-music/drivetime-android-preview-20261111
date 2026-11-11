import 'dart:math' as math;

/// Kodiert Koordinaten als Google "encoded polyline" (Faktor 1e5).
String encodePolyline(List<List<double>> pts) {
  final sb = StringBuffer();
  int lastLat = 0, lastLng = 0;
  for (final p in pts) {
    final lat = (p[0] * 1e5).round();
    final lng = (p[1] * 1e5).round();
    _enc(sb, lat - lastLat);
    _enc(sb, lng - lastLng);
    lastLat = lat;
    lastLng = lng;
  }
  return sb.toString();
}

void _enc(StringBuffer sb, int v) {
  var value = v < 0 ? ~(v << 1) : (v << 1);
  while (value >= 0x20) {
    sb.writeCharCode((0x20 | (value & 0x1f)) + 63);
    value >>= 5;
  }
  sb.writeCharCode(value + 63);
}

/// Dichtet eine grobe Punktfolge auf ~5-km-Schritte auf, damit die
/// Länderprüfung realistische Geometrie sieht.
List<List<double>> densify(List<List<double>> pts, {double stepKm = 5}) {
  final out = <List<double>>[];
  for (var i = 0; i < pts.length - 1; i++) {
    final a = pts[i], b = pts[i + 1];
    final km = _km(a, b);
    final n = math.max(1, (km / stepKm).ceil());
    for (var k = 0; k < n; k++) {
      final t = k / n;
      out.add([a[0] + (b[0] - a[0]) * t, a[1] + (b[1] - a[1]) * t]);
    }
  }
  out.add(pts.last);
  return out;
}

double _km(List<double> a, List<double> b) {
  final latMid = (a[0] + b[0]) / 2 * math.pi / 180;
  final dx = (b[1] - a[1]) * math.pi / 180 * math.cos(latMid);
  final dy = (b[0] - a[0]) * math.pi / 180;
  return 6371.0088 * math.sqrt(dx * dx + dy * dy);
}

/// Baut eine Google-Directions-Antwort mit beliebig vielen Routenvarianten.
/// [routes] ist je Variante eine Liste von Legs, je Leg eine Punktfolge.
Map<String, dynamic> directionsResponse(List<List<List<List<double>>>> routes) {
  return {
    'status': 'OK',
    'routes': [
      for (final legs in routes)
        {
          'warnings': <String>[],
          'legs': [
            for (final leg in legs)
              {
                'distance': {'value': (_pathKm(leg) * 1000).round()},
                'duration': {'value': (_pathKm(leg) / 80 * 3600).round()},
                // Google liefert Distanz und Dauer auch je Etappe – das
                // braucht u. a. die LKW-Fahrzeit.
                'steps': [
                  {
                    'html_instructions': 'drive',
                    'distance': {'value': (_pathKm(leg) * 1000).round()},
                    'duration': {'value': (_pathKm(leg) / 80 * 3600).round()},
                    'polyline': {'points': encodePolyline(densify(leg))},
                  }
                ],
              }
          ],
        }
    ],
  };
}

double _pathKm(List<List<double>> pts) {
  double km = 0;
  for (var i = 0; i < pts.length - 1; i++) {
    km += _km(pts[i], pts[i + 1]);
  }
  return km;
}
