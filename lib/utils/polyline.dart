import 'package:latlong2/latlong.dart';

/// Dekodiert eine Google-"encoded polyline" (Faktor 1e5) zu Koordinaten.
List<LatLng> decodePolyline(String encoded) {
  final points = <LatLng>[];
  int index = 0;
  int lat = 0;
  int lng = 0;
  final len = encoded.length;
  while (index < len) {
    int b;
    int shift = 0;
    int result = 0;
    do {
      b = encoded.codeUnitAt(index++) - 63;
      result |= (b & 0x1f) << shift;
      shift += 5;
    } while (b >= 0x20);
    // ~n entspricht -(n+1). Die ~-Variante liefert unter dart2js (Web) ein
    // vorzeichenloses 32-Bit-Ergebnis und damit völlig falsche Koordinaten;
    // diese Schreibweise verhält sich auf VM und Web identisch.
    final dlat = ((result & 1) != 0) ? -((result >> 1) + 1) : (result >> 1);
    lat += dlat;

    shift = 0;
    result = 0;
    do {
      b = encoded.codeUnitAt(index++) - 63;
      result |= (b & 0x1f) << shift;
      shift += 5;
    } while (b >= 0x20);
    final dlng = ((result & 1) != 0) ? -((result >> 1) + 1) : (result >> 1);
    lng += dlng;

    points.add(LatLng(lat / 1e5, lng / 1e5));
  }
  return points;
}

/// Kodiert Koordinaten als Google-"encoded polyline" (Faktor 1e5) – die
/// Umkehrung von [decodePolyline]. Ohne Bit-Tricks mit Vorzeichen, damit VM
/// und Web (dart2js) identisch rechnen.
String encodePolyline(List<LatLng> points) {
  final out = StringBuffer();
  var lastLat = 0;
  var lastLng = 0;
  void enc(int v) {
    var x = v < 0 ? (-v) * 2 - 1 : v * 2;
    while (x >= 0x20) {
      out.writeCharCode((0x20 | (x & 0x1f)) + 63);
      x = x ~/ 32;
    }
    out.writeCharCode(x + 63);
  }

  for (final p in points) {
    final lat = (p.latitude * 1e5).round();
    final lng = (p.longitude * 1e5).round();
    enc(lat - lastLat);
    enc(lng - lastLng);
    lastLat = lat;
    lastLng = lng;
  }
  return out.toString();
}
