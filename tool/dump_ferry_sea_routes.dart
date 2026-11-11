// Gibt die lokalen Seewege als JSON aus (für tool/check_ferry_sea_routes.mjs).
//   dart run tool/dump_ferry_sea_routes.dart > /tmp/sea.json
import 'dart:convert';

import 'package:driverroute_eta/logic/ferry_sea_routes.dart';

void main() {
  // ignore: avoid_print
  print(jsonEncode([
    for (final r in ferrySeaRoutes)
      {
        'a': r.portA,
        'b': r.portB,
        'points': [for (final p in densifySeaRoute(r.points, 2000)) [p.latitude, p.longitude]],
        'waypoints': [for (final p in r.points) [p.latitude, p.longitude]],
      },
  ]));
}
