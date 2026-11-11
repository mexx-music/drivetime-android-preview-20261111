// EXPERIMENT – eigene Demo-Seite, nicht Teil der App.
//
// Zeigt die Tour-Animation mit einer festen Testroute İpsala → Odense
// (Linie durch echte Städte, keine Google-Route) und einer synthetischen
// Planung – ohne jeden Google-Aufruf. Zum Vergleich 2D / 2.5D:
//
//   flutter build web -t lib/demo/maplibre_demo.dart -o build/demo
//   …/?mode=2d   bzw.   …/?mode=25d
//   Fahrzeug: &truck=top|threequarter-left|threequarter-right|threequarter-auto|rear|side
//             &brand=gartner|neutral  &trailer=box|curtain|reefer
//             &bias=22 (Schrägstellung °)  &tpitch=42 (Fahrzeug-Neigung °)  &tscale=1
//   Kamera:   &camera=follow|cinematic  &cameraDemo=1 (Fahrten gedrängt)  &cameraDebug=1
//   Licht:    &daynight=off|plan|sim  (sim: ein ganzer Tag über die Fahrt)
//   Sattelzug gekoppelt: &truck=articulated (Standard bei camera=cinematic)
//   Fähre:    &route=ferry  (Thessaloniki → Igoumenitsa ⛴ Bari → Bologna)
//             &route=ferry-long  (… Igoumenitsa ⛴ Ancona → München)
//             Seestrecke wie in der App: Abfahrts- → Ankunftshafen.
//   …/?mode=picker  – Zwischenpunkt auf der Vektorkarte wählen
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:latlong2/latlong.dart';

import '../animation/cinematic_camera.dart';
import '../animation/country_borders.dart';
import '../animation/daylight.dart';
import '../animation/tour_path.dart';
import '../logic/eta_calculator.dart';
import '../ui/tour_animation_view.dart';
import '../ui/truck_sprites.dart';
import '../ui/map_point_picker.dart';

/// Grobe Strecke İpsala → Odense über die üblichen Korridore.
const _via = [
  LatLng(40.92, 26.38), // İpsala
  LatLng(41.68, 26.56), // Edirne
  LatLng(42.15, 24.75), // Plowdiw
  LatLng(42.70, 23.32), // Sofia
  LatLng(43.32, 21.90), // Niš
  LatLng(44.82, 20.46), // Belgrad
  LatLng(45.25, 19.84), // Novi Sad
  LatLng(46.25, 20.15), // Szeged
  LatLng(47.50, 19.04), // Budapest
  LatLng(48.15, 17.11), // Bratislava
  LatLng(49.20, 16.61), // Brünn
  LatLng(50.08, 14.44), // Prag
  LatLng(51.05, 13.74), // Dresden
  LatLng(52.52, 13.40), // Berlin
  LatLng(53.55, 9.99), // Hamburg
  LatLng(54.78, 9.44), // Flensburg
  LatLng(55.40, 10.39), // Odense
];

/// Landweg zum Abfahrtshafen (Egnatia Odos).
const _toIgoumenitsa = [
  LatLng(40.64, 22.94), // Thessaloniki
  LatLng(40.52, 22.20), // Veria
  LatLng(40.30, 21.79), // Kozani
  LatLng(40.08, 21.43), // Grevena
  LatLng(39.77, 21.18), // Metsovo
  LatLng(39.66, 20.85), // Ioannina
  LatLng(39.50, 20.26), // Igoumenitsa (Hafen)
];

const _fromBari = [
  LatLng(41.13, 16.87), // Bari (Hafen)
  LatLng(41.46, 15.55), // Foggia
  LatLng(42.46, 14.21), // Pescara
  LatLng(43.62, 13.52), // Ancona
  LatLng(44.49, 11.34), // Bologna
];

const _fromAncona = [
  LatLng(43.62, 13.52), // Ancona (Hafen)
  LatLng(44.49, 11.34), // Bologna
  LatLng(45.44, 10.99), // Verona
  LatLng(46.07, 11.12), // Trient
  LatLng(47.00, 11.50), // Brenner
  LatLng(47.27, 11.39), // Innsbruck
  LatLng(48.14, 11.58), // München
];

List<LatLng> _densify(List<LatLng> via) {
  const d = Distance(calculator: Haversine());
  final out = <LatLng>[via.first];
  for (var i = 1; i < via.length; i++) {
    final a = via[i - 1], b = via[i];
    final n = (d(a, b) / 2000).ceil();
    for (var k = 1; k <= n; k++) {
      out.add(LatLng(a.latitude + (b.latitude - a.latitude) * k / n,
          a.longitude + (b.longitude - a.longitude) * k / n));
    }
  }
  return out;
}

/// Planung wie die ETA sie liefern würde: 4,5 h fahren, Pause, 4,5 h, Ruhe.
EtaResult _plan(double km) {
  final steps = <EtaStep>[const EtaStep('', type: EtaEventType.start)];
  var t = DateTime(2026, 10, 5, 6, 0);
  var left = km;
  var day = 0.0;
  const kmh = 70.0;
  while (left > 0) {
    final chunk = left < 315 ? left : 315.0; // 4,5 h bei 70 km/h
    final end = t.add(Duration(minutes: (chunk / kmh * 60).round()));
    steps.add(EtaStep('', type: EtaEventType.drive, distanceKm: chunk, start: t, end: end));
    t = end;
    left -= chunk;
    day += chunk;
    if (left <= 0) break;
    if (day >= 630) {
      steps.add(EtaStep('', type: EtaEventType.dailyRest, start: t, end: t.add(const Duration(hours: 11))));
      t = t.add(const Duration(hours: 11));
      day = 0;
    } else {
      steps.add(EtaStep('', type: EtaEventType.breakTime, start: t, end: t.add(const Duration(minutes: 45))));
      t = t.add(const Duration(minutes: 45));
    }
  }
  steps.add(const EtaStep('', type: EtaEventType.destination));
  return EtaResult(steps, t);
}

/// Fährtour wie aus der Kartenplanung der App: Landweg, Seestrecke
/// (Abfahrts- → Ankunftshafen), Landweg.
TourPath _ferryPath(List<LatLng> after, String ferry) {
  final a = _densify(_toIgoumenitsa), b = _densify(after);
  return TourPath([
    TourLeg(points: a, label: 'Anfahrt → Igoumenitsa'),
    TourLeg(points: [a.last, b.first], kind: TourLegKind.ferry, label: ferry),
    TourLeg(points: b, label: 'Ziel'),
  ]);
}

/// Planung mit Fähre: Anfahrt, Warten am Hafen, Überfahrt über Nacht, weiter.
EtaResult _ferryPlan(TourPath path, {required int crossingHours}) {
  final spans = path.legSpans;
  final kmA = (spans.first.to - spans.first.from) / 1000;
  final kmB = (spans.last.to - spans.last.from) / 1000;
  final steps = <EtaStep>[const EtaStep('', type: EtaEventType.start)];
  var t = DateTime(2026, 10, 5, 12, 0);
  DateTime drive(double km) {
    var left = km;
    while (left > 0) {
      final chunk = left < 315 ? left : 315.0;
      final end = t.add(Duration(minutes: (chunk / 70 * 60).round()));
      steps.add(EtaStep('', type: EtaEventType.drive, distanceKm: chunk, start: t, end: end));
      t = end;
      left -= chunk;
      if (left > 0) {
        steps.add(EtaStep('', type: EtaEventType.breakTime, start: t, end: t.add(const Duration(minutes: 45))));
        t = t.add(const Duration(minutes: 45));
      }
    }
    return t;
  }

  drive(kmA);
  final departure = DateTime(2026, 10, 5, 20, 30);
  if (t.isBefore(departure)) {
    steps.add(EtaStep('', type: EtaEventType.wait, start: t, end: departure));
    t = departure;
  }
  final arrival = t.add(Duration(hours: crossingHours));
  steps.add(EtaStep('', type: EtaEventType.ferry, title: 'Fähre', start: t, end: arrival));
  t = arrival;
  drive(kmB);
  steps.add(const EtaStep('', type: EtaEventType.destination));
  return EtaResult(steps, t);
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await initializeDateFormatting('de');
  final q = Uri.base.queryParameters;
  final route = q['route'];
  final path = switch (route) {
    'ferry' => _ferryPath(_fromBari, 'Igoumenitsa → Bari'),
    'ferry-long' => _ferryPath(_fromAncona, 'Igoumenitsa → Ancona'),
    _ => TourPath([TourLeg(points: _densify(_via))]),
  };
  final (title, fromName, toName) = switch (route) {
    'ferry' => ('Thessaloniki → Bologna', 'Thessaloniki', 'Bologna'),
    'ferry-long' => ('Thessaloniki → München', 'Thessaloniki', 'München'),
    _ => ('İpsala → Odense', 'İpsala', 'Odense'),
  };
  final eta = switch (route) {
    'ferry' => _ferryPlan(path, crossingHours: 10),
    'ferry-long' => _ferryPlan(path, crossingHours: 16),
    _ => _plan(path.roadMeters / 1000),
  };
  final mode = q['mode'] ?? '25d';
  runApp(MaterialApp(
    debugShowCheckedModeBanner: false,
    locale: const Locale('de'),
    supportedLocales: const [Locale('de')],
    localizationsDelegates: GlobalMaterialLocalizations.delegates,
    theme: ThemeData(colorSchemeSeed: const Color(0xFF0A6EBD), useMaterial3: true),
    home: mode == 'picker'
        ? MapPointPicker(
            initialCenter: const LatLng(41.6, 23.5), // Balkan: Griechenland, Bulgarien
            initialZoom: 7,
            start: _via.first,
            dest: _via.last,
            countries: CountryIndex.load(),
          )
        : TourAnimationView(
      path: path,
      title: title,
      fromName: fromName,
      toName: toName,
      eta: eta,
      countries: CountryIndex.load(),
      startIn25D: mode != '2d',
      cameraMode: q['camera'] == 'cinematic' ? CameraMode.cinematic : CameraMode.follow,
      cinematicDemo: q['cameraDemo'] == '1',
      cameraDebug: q['cameraDebug'] == '1',
      dayNight: switch (q['daynight']) {
        'plan' => DayNightMode.plan,
        'sim' => DayNightMode.simulated,
        _ => DayNightMode.off,
      },
      truckView: switch (q['truck'] ?? (q['camera'] == 'cinematic' ? 'articulated' : 'top')) {
        'articulated' => TruckView.articulated,
        'rear' => TruckView.rear,
        'side' => TruckView.side,
        'threequarter-left' => TruckView.threeQuarterLeft,
        'threequarter-right' => TruckView.threeQuarterRight,
        'threequarter-auto' => TruckView.threeQuarterAuto,
        _ => TruckView.top,
      },
      truckModel: TruckModel(
        trailer: switch (q['trailer']) {
          'curtain' => TrailerKind.curtain,
          'reefer' => TrailerKind.reefer,
          _ => TrailerKind.box,
        },
        branding: q['brand'] == 'neutral' ? TruckBranding.neutral : TruckBranding.gartnerTest,
      ),
      truckBias: double.tryParse(q['bias'] ?? '') ?? 22,
      truckPitch: double.tryParse(q['tpitch'] ?? '') ?? 42,
      truckScale: double.tryParse(q['tscale'] ?? '') ?? 1,
    ),
  ));
}
