import 'package:latlong2/latlong.dart';

/// Lokale Seewege der Fährverbindungen, die DriveTime kennt
/// (assets/fahrplaene/ferries.json).
///
/// Bisher bestand die Seestrecke auf Karte und Animation nur aus der Geraden
/// Abfahrtshafen → Ankunftshafen; die schnitt teils Land (Igoumenitsa →
/// Bari über Korfu). Hier liegt je Hafenpaar eine plausible Linie über
/// Wasser – kein AIS-Track, sondern eine von Hand gesetzte Folge von
/// Wegpunkten durch die üblichen Fahrwasser. Jede Linie ist geprüft:
/// - im Test gegen die Ländergrenzen (Natural Earth 1:10m),
/// - mit tool/check_ferry_sea_routes.mjs gegen die Wasserflächen der
///   angezeigten Karte (OpenFreeMap) bei Zoom 11–12.
/// Kein Dienst wird gefragt; die Linien sind fest im Code.
///
/// Jede Linie beginnt und endet im Hafenbecken. Gilt für beide Richtungen.
class FerrySeaRoute {
  const FerrySeaRoute(this.portA, this.portB, this.points);

  final String portA;
  final String portB;

  /// Wegpunkte von [portA] nach [portB].
  final List<LatLng> points;
}

/// Gemeinsame Wegpunkte Griechenland ↔ Italien.
const _igouOut = [
  LatLng(39.4985, 20.2470), // Igoumenitsa, Hafenbecken
  LatLng(39.4950, 20.2050),
  LatLng(39.5450, 20.0850),
  LatLng(39.6400, 19.9850), // Korfu-Kanal, Mitte
  LatLng(39.7200, 19.9580),
  LatLng(39.7800, 19.9600), // Nordkanal zwischen Korfu und Albanien
  LatLng(39.8500, 19.9300),
  LatLng(40.0000, 19.6400),
  LatLng(40.3000, 19.0000), // Straße von Otranto
];

const _patrasOut = [
  LatLng(38.2380, 21.7160), // Patras, Hafenbecken
  LatLng(38.2600, 21.6000),
  LatLng(38.2700, 21.4400), // Golf von Patras
  LatLng(38.2000, 21.2400),
  LatLng(38.0300, 20.9300),
  LatLng(37.9900, 20.7900), // zwischen Kefalonia und Zakynthos
  LatLng(38.0000, 20.3000),
  LatLng(38.6000, 19.9500), // westlich Kefalonia/Lefkada
  LatLng(39.3000, 19.6000), // westlich Paxi/Korfu
  LatLng(39.7500, 19.2000),
  LatLng(40.3000, 19.0000), // Straße von Otranto
];

const _otrantoToBari = [
  LatLng(40.3000, 19.0000),
  LatLng(40.9000, 17.6000),
  LatLng(41.1600, 17.0500),
  LatLng(41.1450, 16.8750), // Bari, Hafenbecken
];

const _otrantoToBrindisi = [
  LatLng(40.3000, 19.0000),
  LatLng(40.6000, 18.2000),
  LatLng(40.6600, 18.0200),
  LatLng(40.6610, 17.9994), // Einfahrt Außenhafen
  LatLng(40.6558, 17.9857),
  LatLng(40.6483, 17.9763), // Brindisi, Costa Morena
];

const _otrantoToAncona = [
  LatLng(40.3000, 19.0000),
  LatLng(41.0000, 18.2000),
  LatLng(42.0000, 16.8000),
  LatLng(43.0000, 14.6000),
  LatLng(43.6500, 13.5500),
  LatLng(43.6346, 13.5027),
  LatLng(43.6280, 13.4966), // vor der Hafeneinfahrt
  LatLng(43.6265, 13.5009),
  LatLng(43.6260, 13.5026), // Ancona, Becken nördlich Molo Nord
];

const _otrantoToVenice = [
  LatLng(40.3000, 19.0000),
  LatLng(41.0000, 18.2000),
  LatLng(42.0000, 16.8000),
  LatLng(43.5000, 14.8000),
  LatLng(44.5000, 13.3000),
  LatLng(45.2000, 12.6000),
  LatLng(45.3302, 12.3466),
  LatLng(45.3371, 12.3240), // Bocca di Malamocco
  LatLng(45.3363, 12.3081),
  LatLng(45.3650, 12.2850), // Kanal Malamocco–Marghera
  LatLng(45.4000, 12.2650),
  LatLng(45.4150, 12.2601),
  LatLng(45.4180, 12.2594), // Fusina, Fährterminal
];

List<LatLng> _join(List<LatLng> a, List<LatLng> b) => [...a, ...b.skip(1)];

/// Gemeinsame Wegpunkte Ostsee.
const _kielOut = [
  LatLng(54.3222, 10.1487), // Kiel, Schwedenkai
  LatLng(54.3245, 10.1499),
  LatLng(54.3350, 10.1634),
  LatLng(54.3520, 10.1669),
  LatLng(54.3600, 10.1600),
  LatLng(54.3950, 10.1950), // Friedrichsort
  LatLng(54.4500, 10.2500),
  LatLng(54.5500, 10.4500), // Kieler Bucht
];

const _traveOut = [
  LatLng(53.9464, 10.8593), // Travemünde, Skandinavienkai
  LatLng(53.9540, 10.8635),
  LatLng(53.9565, 10.8721),
  LatLng(53.9602, 10.8841), // Travemündung
  LatLng(53.9650, 10.8950),
  LatLng(54.0200, 10.9500),
  LatLng(54.1500, 11.3000),
  LatLng(54.3500, 11.8000),
  LatLng(54.4800, 12.2000), // Kadetrinne
];

const _kadetToTrelleborg = [
  LatLng(54.4800, 12.2000),
  LatLng(54.6500, 12.5500),
  LatLng(55.0000, 13.0000),
  LatLng(55.2500, 13.1500),
  LatLng(55.3600, 13.1550), // Trelleborg, Hafen
];

const _kattegatNorth = [
  LatLng(54.5500, 10.4500), // Kieler Bucht
  LatLng(54.7800, 10.9000),
  LatLng(55.1000, 10.9700), // Langelandsbelt, westlich Albuen
  LatLng(55.3300, 11.0600), // Großer Belt, Ostrinne
  LatLng(55.4500, 10.9800),
  LatLng(55.6000, 10.8800),
  LatLng(55.7600, 10.7600), // westlich Røsnæs
  LatLng(56.0000, 10.8500), // zwischen Samsø und Sejerø
  LatLng(56.3000, 11.1000),
  LatLng(57.0000, 11.4000), // Kattegat
];

/// Alle bekannten Verbindungen (je Hafenpaar einmal, beide Richtungen).
final List<FerrySeaRoute> ferrySeaRoutes = [
  // ---------------------------------------------- Griechenland ↔ Italien
  FerrySeaRoute('Igoumenitsa', 'Bari', _join(_igouOut, _otrantoToBari)),
  FerrySeaRoute('Igoumenitsa', 'Brindisi', _join(_igouOut, _otrantoToBrindisi)),
  FerrySeaRoute('Igoumenitsa', 'Ancona', _join(_igouOut, _otrantoToAncona)),
  FerrySeaRoute('Igoumenitsa', 'Venedig', _join(_igouOut, _otrantoToVenice)),
  FerrySeaRoute('Patras', 'Bari', _join(_patrasOut, _otrantoToBari)),
  FerrySeaRoute('Patras', 'Brindisi', _join(_patrasOut, _otrantoToBrindisi)),
  FerrySeaRoute('Patras', 'Ancona', _join(_patrasOut, _otrantoToAncona)),
  FerrySeaRoute('Patras', 'Venedig', _join(_patrasOut, _otrantoToVenice)),
  // ---------------------------------------------- Ostsee
  FerrySeaRoute('Travemünde', 'Trelleborg', _join(_traveOut, _kadetToTrelleborg)),
  const FerrySeaRoute('Kiel', 'Trelleborg', [
    ..._kielOut,
    LatLng(54.5700, 11.2000), // Fehmarnbelt
    LatLng(54.4800, 11.7000),
    ..._kadetToTrelleborg,
  ]),
  const FerrySeaRoute('Travemünde', 'Malmö', [
    ..._traveOut,
    LatLng(54.6500, 12.5500),
    LatLng(55.0500, 12.7000),
    LatLng(55.3000, 12.6200), // östlich Stevns, westlich Falsterbo
    LatLng(55.4700, 12.7500),
    LatLng(55.5600, 12.8500), // Flintrinne
    LatLng(55.6300, 12.9300),
    LatLng(55.6250, 12.9800), // Malmö, Hafen
  ]),
  const FerrySeaRoute('Rostock', 'Trelleborg', [
    LatLng(54.1530, 12.0964), // Rostock, Überseehafen
    LatLng(54.1700, 12.0969), // Unterwarnow
    LatLng(54.1810, 12.0939),
    LatLng(54.1850, 12.0900), // Warnemünde
    LatLng(54.1889, 12.0899), // zwischen den Molen
    LatLng(54.3000, 12.1500),
    LatLng(54.5500, 12.3500), // westlich Darßer Ort
    LatLng(54.7000, 12.8500),
    LatLng(55.1000, 13.1000),
    LatLng(55.3600, 13.1550), // Trelleborg
  ]),
  const FerrySeaRoute('Świnoujście', 'Trelleborg', [
    LatLng(53.9158, 14.2814), // Świnoujście, Swine am Fährterminal
    LatLng(53.9168, 14.2814),
    LatLng(53.9219, 14.2809),
    LatLng(53.9238, 14.2809),
    LatLng(53.9275, 14.2810),
    LatLng(53.9326, 14.2844), // zwischen den Molen
    LatLng(53.9350, 14.2900),
    LatLng(54.1000, 14.3000),
    LatLng(54.5000, 13.8000), // östlich Rügen
    LatLng(54.8500, 13.5500),
    LatLng(55.2000, 13.2500),
    LatLng(55.3600, 13.1550), // Trelleborg
  ]),
  FerrySeaRoute('Kiel', 'Göteborg', [
    ..._join(_kielOut, _kattegatNorth),
    const LatLng(57.6400, 11.5500),
    const LatLng(57.6670, 11.7363), // Hake fjord
    const LatLng(57.6818, 11.8300), // Göta-älv-Mündung
    const LatLng(57.6836, 11.8515),
    const LatLng(57.6881, 11.8757),
    const LatLng(57.6893, 11.8924), // Göteborg, Göta älv
  ]),
  FerrySeaRoute('Kiel', 'Oslo', [
    ..._join(_kielOut, _kattegatNorth),
    const LatLng(57.8500, 10.9000), // östlich Skagen
    const LatLng(58.6000, 10.6000), // Skagerrak
    const LatLng(59.0000, 10.6400), // Oslofjord, Einfahrt
    const LatLng(59.2000, 10.6250), // östlich der Bolærne
    const LatLng(59.3000, 10.5600),
    const LatLng(59.4300, 10.5350), // westlich Jeløya
    const LatLng(59.5600, 10.6300),
    const LatLng(59.6200, 10.6400),
    const LatLng(59.6650, 10.6150), // Drøbaksund
    const LatLng(59.7200, 10.5850),
    const LatLng(59.7183, 10.5725), // südlich Aspond
    const LatLng(59.7221, 10.5707),
    const LatLng(59.7291, 10.5608), // westlich Lågøya
    const LatLng(59.7517, 10.5348),
    const LatLng(59.8000, 10.5300), // Vestfjord, westlich Nesodden
    const LatLng(59.8207, 10.5588),
    const LatLng(59.8500, 10.6103), // östlich Gåsøya
    const LatLng(59.8680, 10.6250),
    const LatLng(59.8850, 10.6600),
    const LatLng(59.9000, 10.7100), // Oslo, Color-Line-Terminal
  ]),
  const FerrySeaRoute('Grenaa', 'Halmstad', [
    LatLng(56.4100, 10.9300), // Grenaa, Hafen
    LatLng(56.4300, 11.3000),
    LatLng(56.5000, 11.8000), // zwischen Anholt und Hesselø
    LatLng(56.6000, 12.6000),
    LatLng(56.6200, 12.7800), // Laholmsbucht
    LatLng(56.6350, 12.8182),
    LatLng(56.6550, 12.8450), // Halmstad, Hafen
  ]),
  // ---------------------------------------------- Norwegen
  const FerrySeaRoute('Hirtshals', 'Kristiansand', [
    LatLng(57.5950, 9.9600), // Hirtshals, Hafen
    LatLng(57.8000, 9.7500),
    LatLng(58.0800, 8.4000),
    LatLng(58.0850, 8.0600),
    LatLng(58.1000, 8.0500),
    LatLng(58.1431, 8.0136), // Kristiansand, Hafen östlich Odderøya
  ]),
  const FerrySeaRoute('Hirtshals', 'Stavanger', [
    LatLng(57.5950, 9.9600),
    LatLng(57.8000, 7.0000), // südlich Lindesnes
    LatLng(58.4500, 5.3500),
    LatLng(58.9900, 5.4200), // südlich Kvitsøy
    LatLng(59.0300, 5.5500),
    LatLng(59.0480, 5.6000), // nördlich Tungenes
    LatLng(59.0122, 5.6739), // Byfjord
    LatLng(58.9872, 5.7154),
    LatLng(58.9826, 5.7195),
    LatLng(58.9808, 5.7229),
    LatLng(58.9772, 5.7244),
    LatLng(58.9750, 5.7300), // Stavanger, Hafen
  ]),
  const FerrySeaRoute('Hirtshals', 'Bergen', [
    LatLng(57.5950, 9.9600),
    LatLng(57.8000, 7.0000),
    LatLng(58.4500, 5.3500),
    LatLng(59.5000, 4.8500), // westlich der Schären
    LatLng(60.3000, 4.5500),
    LatLng(60.7300, 4.7000),
    LatLng(60.7236, 4.7670), // nördlich Sulo
    LatLng(60.7000, 4.8450), // Einfahrt Hjeltefjord
    LatLng(60.6350, 4.9000),
    LatLng(60.5610, 4.9250), // Hjeltefjord
    LatLng(60.5050, 4.9980),
    LatLng(60.4640, 5.0500),
    LatLng(60.4434, 5.0558), // westlich Hanøy
    LatLng(60.4280, 5.0660),
    LatLng(60.4280, 5.1100),
    LatLng(60.4210, 5.1374), // östlich Skorpo
    LatLng(60.4014, 5.1525), // zwischen Askøy und Sotra
    LatLng(60.3903, 5.1551),
    LatLng(60.3865, 5.1800), // südlich Askøy
    LatLng(60.3912, 5.2015),
    LatLng(60.3955, 5.2200), // unter der Askøybrücke
    LatLng(60.4010, 5.2350),
    LatLng(60.3980, 5.2680), // Byfjord
    LatLng(60.4020, 5.3000), // Bergen, vor Skoltegrunnskaien
  ]),
];

String _norm(String name) => name
    .toLowerCase()
    .replaceAll('ü', 'u')
    .replaceAll('ö', 'o')
    .replaceAll('ś', 's')
    .replaceAll('venice', 'venedig')
    .replaceAll('venezia', 'venedig')
    .trim();

/// Seeweg von [from] nach [to] (Hafennamen wie in den Fahrplänen), auf
/// höchstens [stepMeters] verdichtet; null, wenn das Paar unbekannt ist.
List<LatLng>? seaRouteBetween(String from, String to, {double stepMeters = 2000}) {
  final f = _norm(from), t = _norm(to);
  for (final r in ferrySeaRoutes) {
    final a = _norm(r.portA), b = _norm(r.portB);
    if (a == f && b == t) return densifySeaRoute(r.points, stepMeters);
    if (a == t && b == f) return densifySeaRoute(r.points.reversed.toList(), stepMeters);
  }
  return null;
}

/// Zwischenpunkte entlang gerader Stücke (linear in Länge/Breite – genau so
/// interpoliert auch die Animation), damit Karte, Fahrt und Prüfung
/// dieselbe Linie sehen.
List<LatLng> densifySeaRoute(List<LatLng> pts, double stepMeters) {
  const d = Distance(calculator: Haversine());
  final out = <LatLng>[pts.first];
  for (var i = 1; i < pts.length; i++) {
    final a = pts[i - 1], b = pts[i];
    final n = (d(a, b) / stepMeters).ceil();
    for (var k = 1; k <= n; k++) {
      out.add(LatLng(a.latitude + (b.latitude - a.latitude) * k / n,
          a.longitude + (b.longitude - a.longitude) * k / n));
    }
  }
  return out;
}

/// Seestrecke für Karte und Animation: Abfahrtshafen → lokaler Seeweg →
/// Ankunftshafen. [from]/[to] sind die Hafenpunkte der Planung (Ende bzw.
/// Anfang der Landwege). Ohne bekannten Seeweg oder wenn ein Hafenpunkt
/// weiter als [maxGapMeters] vom Seeweg entfernt liegt (anderer Hafen),
/// bleibt es bei der bisherigen Geraden.
List<LatLng> ferryLinePoints(String fromName, String toName, LatLng from, LatLng to,
    {double maxGapMeters = 30000}) {
  final sea = seaRouteBetween(fromName, toName);
  if (sea == null) return [from, to];
  const d = Distance(calculator: Haversine());
  if (d(from, sea.first) > maxGapMeters || d(to, sea.last) > maxGapMeters) return [from, to];
  return [from, ...sea, to];
}
