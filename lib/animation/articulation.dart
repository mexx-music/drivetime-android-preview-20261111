import 'dart:math' as math;

import 'package:latlong2/latlong.dart';

import 'tour_path.dart';

/// Gekoppelter Sattelzug entlang einer [TourPath] – reine Geometrie.
///
/// Ohne Fahrphysik: Vorder- und Hinterachse der Zugmaschine liegen auf der
/// Route (die Zugmaschine fährt exakt auf der Straße), die Aufliegerachse
/// liegt [trailerWheelbase] hinter dem Sattelpunkt ebenfalls auf der Route.
/// Aus den drei Punkten folgen Zugmaschinen-Richtung, Auflieger-Richtung und
/// der Knickwinkel. Eine Funktion der Streckenposition – Bild für Bild
/// reproduzierbar, auch für Videoexport.
///
/// Die Maße werden mit [metersPerUnit] in Kartenmeter umgerechnet: Das
/// Fahrzeugsymbol ist stark überzeichnet, damit sein Auflieger der
/// SICHTBAREN Route folgt, rechnen wir mit seiner sichtbaren Größe.
class ArticulatedPose {
  const ArticulatedPose({
    required this.frontAxle,
    required this.kingpin,
    required this.trailerAxle,
    required this.tractorHeading,
    required this.trailerHeading,
  });

  final LatLng frontAxle;
  final LatLng kingpin;
  final LatLng trailerAxle;

  /// Richtungen in Grad (0 = Norden, im Uhrzeigersinn).
  final double tractorHeading;
  final double trailerHeading;

  /// Knickwinkel Auflieger gegen Zugmaschine, −180..180 (positiv: Auflieger
  /// steht nach rechts gedreht, d. h. Linkskurve).
  double get knick {
    var d = (trailerHeading - tractorHeading) % 360;
    if (d > 180) d -= 360;
    return d;
  }
}

/// Fahrzeugmaße in Metern (Standard-Sattelzug).
class TruckDimensions {
  const TruckDimensions({
    this.tractorWheelbase = 3.8,
    this.kingpinBehindFront = 3.5,
    this.trailerWheelbase = 10.5,
    this.maxKnick = 70,
  });

  /// Vorderachse → Hinterachse der Zugmaschine.
  final double tractorWheelbase;

  /// Vorderachse → Sattelpunkt (Königszapfen), knapp vor der Hinterachse.
  final double kingpinBehindFront;

  /// Sattelpunkt → Aufliegerachse(n).
  final double trailerWheelbase;

  /// Grenze gegen Einknicken an Polyline-Ecken.
  final double maxKnick;
}

const _hav = Distance(calculator: Haversine());

double _bearing(LatLng from, LatLng to) => (_hav.bearing(from, to) + 360) % 360;

/// Punkt in [dist] m Richtung [bearing]° (beliebiger Winkel). Eigene Formel:
/// latlong2 rundet `offset` auf 6 Stellen und verlangt −180…180°.
LatLng destination(LatLng p, double dist, double bearing) {
  const r = 6371008.8;
  final d = dist / r, b = bearing * math.pi / 180;
  final la1 = p.latitude * math.pi / 180, lo1 = p.longitude * math.pi / 180;
  final la2 = math.asin(math.sin(la1) * math.cos(d) + math.cos(la1) * math.sin(d) * math.cos(b));
  final lo2 = lo1 +
      math.atan2(math.sin(b) * math.sin(d) * math.cos(la1), math.cos(d) - math.sin(la1) * math.sin(la2));
  return LatLng(la2 * 180 / math.pi, lo2 * 180 / math.pi);
}

/// Pose bei [meters] (Vorderachse). [metersPerUnit]: Kartenmeter je
/// Fahrzeugmeter (1 = maßstabsgetreu).
ArticulatedPose articulate(
  TourPath path,
  double meters, {
  double metersPerUnit = 1,
  TruckDimensions dims = const TruckDimensions(),
}) {
  final total = path.totalMeters;
  final m = meters.clamp(0.0, total);
  final k = metersPerUnit;
  // Am Start fehlt Strecke hinter dem Fahrzeug: dann gerade nach hinten
  // verlängern (Richtung des ersten Stücks).
  LatLng behind(double d) {
    if (m - d >= 0) return path.at(m - d).point;
    final start = path.at(0).point;
    final dir = _bearing(path.at(math.min(total, 200)).point, start);
    return destination(start, d - m, dir);
  }

  final front = path.at(m).point;
  final rear = behind(dims.tractorWheelbase * k);
  final kingpin = behind(dims.kingpinBehindFront * k);
  final trailerAxle = behind((dims.kingpinBehindFront + dims.trailerWheelbase) * k);

  final tractorHeading = rear == front ? path.at(m).bearing : _bearing(rear, front);
  var trailerHeading = trailerAxle == kingpin ? tractorHeading : _bearing(trailerAxle, kingpin);
  // Begrenzen: nie stärker als maxKnick einknicken.
  var knick = (trailerHeading - tractorHeading) % 360;
  if (knick > 180) knick -= 360;
  if (knick.abs() > dims.maxKnick) {
    trailerHeading = (tractorHeading + knick.sign * dims.maxKnick + 360) % 360;
  }
  return ArticulatedPose(
    frontAxle: front,
    kingpin: kingpin,
    trailerAxle: trailerAxle,
    tractorHeading: tractorHeading,
    trailerHeading: trailerHeading,
  );
}

/// Kartenmeter je Bildschirmpunkt bei [zoom] und Breite [lat] (MapLibre,
/// 512er-Kacheln).
double metersPerScreenPoint(double zoom, double lat) =>
    78271.517 * math.cos(lat * math.pi / 180) / math.pow(2, zoom);

/// Lichtkegel der Zugmaschine: Ansatz [ahead] Fahrzeugmeter vor der
/// Vorderachse (Front der Kabine), Richtung AUSSCHLIESSLICH die der
/// Zugmaschine – nicht Kamera, nicht Auflieger.
({LatLng apex, double heading}) headlightPlacement(ArticulatedPose pose,
        {required double metersPerUnit, double ahead = 0.9}) =>
    (apex: destination(pose.frontAxle, ahead * metersPerUnit, pose.tractorHeading), heading: pose.tractorHeading);

// ------------------------------------------------ Fahrspur mit Trägheit

/// Trägheit der Cinematic-Fahrt (siehe [ArticulatedTrack.inertia]).
const double cinematicTruckInertia = 3;

/// Sattelzug mit Trägheit entlang einer [TourPath] – Einspurmodell.
///
/// Die Vorderachse fährt exakt auf der Route. Hinterachse der Zugmaschine
/// und Achse des Aufliegers werden wie bei einem echten Gespann nachgezogen
/// (Schleppkurve): Jede folgt ihrem Zugpunkt im festen Abstand. Dadurch
///
/// - steht die Zugmaschine tangential zur gefahrenen Straße, folgt aber
///   kleinen Schlenkern unterhalb ihres Radstands nicht mehr zitternd,
/// - entsteht der Knick allmählich und baut sich nach der Kurve wieder ab,
/// - kann der Auflieger die Zugmaschine nie überholen oder wegschwingen.
///
/// Weiterhin nur eine Funktion der Streckenposition: Die Spur wird einmal
/// für die ganze Tour berechnet (Raster ≤ ¼ Radstand) und dann interpoliert.
class ArticulatedTrack {
  ArticulatedTrack(this.path,
      {required double Function(LatLng) unitAt, this.dims = const TruckDimensions(), this.inertia = 1}) {
    final total = path.totalMeters;
    if (total <= 0) return;
    final u0 = unitAt(path.start);
    _step = math.max(5.0, dims.tractorWheelbase * u0 / 4);
    // Ruhige Gesamtrichtung (Trägheit) …
    final calm = _run(unitAt, inertia).$1;
    // … und der Knick aus dem geometrischen Gespann (echte Kurvenwirkung).
    final (tractorGeo, trailerGeo) = _run(unitAt, 1);
    final half = math.max(1, (dims.tractorWheelbase * inertia * u0 / _step / 2).round());
    // Ruhig wie ein schweres Fahrzeug: über eine Zugmaschinenlänge mitteln
    // (Vektormittel, ohne Verzögerung) – Schlenker unterhalb der
    // Fahrzeuggröße verschwinden ganz.
    _smoothInPlace(calm, half);
    final knick = [
      for (var i = 0; i < calm.length; i++) () {
        var k = (trailerGeo[i] - tractorGeo[i]) % 360;
        if (k > 180) k -= 360;
        return k;
      }(),
    ];
    _smoothLinear(knick, half * 2);
    for (var i = 0; i < calm.length; i++) {
      final k = knick[i].clamp(-dims.maxKnick, dims.maxKnick);
      _tractor.add(calm[i]);
      _trailer.add((calm[i] + k + 360) % 360);
    }
  }

  /// Gespann einmal über die ganze Tour ziehen: (Zugmaschine, Auflieger).
  (List<double>, List<double>) _run(double Function(LatLng) unitAt, double lag) {
    final total = path.totalMeters;
    final u0 = unitAt(path.start);
    final n = (total / _step).ceil();
    final dir0 = path.at(0).bearing;
    var rear = destination(path.start, dims.tractorWheelbase * lag * u0, (dir0 + 180) % 360);
    var tractor = dir0;
    var kingpin = destination(path.start, dims.kingpinBehindFront * u0, (dir0 + 180) % 360);
    var axle = destination(kingpin, dims.trailerWheelbase * u0, (dir0 + 180) % 360);
    final tr = <double>[], tl = <double>[];
    for (var i = 0; i <= n; i++) {
      final m = math.min(total, i * _step);
      final front = path.at(m).point;
      final u = unitAt(front);
      // Hinterachse folgt der Vorderachse im (Trägheits-)Radstand.
      if (_dist(rear, front) > 1e-3) tractor = _bearing(rear, front);
      rear = destination(front, dims.tractorWheelbase * lag * u, (tractor + 180) % 360);
      kingpin = destination(front, dims.kingpinBehindFront * u, (tractor + 180) % 360);
      // Aufliegerachse folgt dem Sattelpunkt.
      var trailer = _dist(axle, kingpin) > 1e-3 ? _bearing(axle, kingpin) : tractor;
      var knick = (trailer - tractor) % 360;
      if (knick > 180) knick -= 360;
      if (knick.abs() > dims.maxKnick) trailer = (tractor + knick.sign * dims.maxKnick + 360) % 360;
      axle = destination(kingpin, dims.trailerWheelbase * u, (trailer + 180) % 360);
      tr.add(tractor);
      tl.add(trailer);
    }
    return (tr, tl);
  }

  static void _smoothLinear(List<double> a, int half) {
    final n = a.length;
    final c = List<double>.filled(n + 1, 0);
    for (var i = 0; i < n; i++) {
      c[i + 1] = c[i] + a[i];
    }
    final out = [
      for (var i = 0; i < n; i++)
        (c[math.min(n - 1, i + half) + 1] - c[math.max(0, i - half)]) / (math.min(n - 1, i + half) - math.max(0, i - half) + 1),
    ];
    a.setAll(0, out);
  }

  static void _smoothInPlace(List<double> a, int half) {
    final n = a.length;
    final cx = List<double>.filled(n + 1, 0), cy = List<double>.filled(n + 1, 0);
    for (var i = 0; i < n; i++) {
      final r = a[i] * math.pi / 180;
      cx[i + 1] = cx[i] + math.sin(r);
      cy[i + 1] = cy[i] + math.cos(r);
    }
    for (var i = 0; i < n; i++) {
      final lo = math.max(0, i - half), hi = math.min(n - 1, i + half);
      final x = cx[hi + 1] - cx[lo], y = cy[hi + 1] - cy[lo];
      if (x.abs() + y.abs() > 1e-9) a[i] = (math.atan2(x, y) * 180 / math.pi + 360) % 360;
    }
  }

  final TourPath path;
  final TruckDimensions dims;

  /// Trägheit der Lenkung: Die Richtung der Zugmaschine folgt der Straße
  /// über [inertia] Radstände (1 = Geometrie). Größer = schwerer, ruhiger –
  /// das stark vergrößerte Symbol folgt so keinen Schlenkern, die kleiner
  /// sind als es selbst. Die Vorderachse bleibt exakt auf der Route.
  final double inertia;
  double _step = 1;
  final List<double> _tractor = [];
  final List<double> _trailer = [];

  static double _dist(LatLng a, LatLng b) => _hav(a, b);

  static double _lerpAngle(double a, double b, double t) {
    var d = (b - a) % 360;
    if (d > 180) d -= 360;
    return (a + d * t + 360) % 360;
  }

  /// Richtung der Zugmaschine bei [meters] (0 = Norden).
  double tractorHeadingAt(double meters) => _sample(_tractor, meters);

  double _sample(List<double> list, double meters) {
    if (list.isEmpty) return path.at(meters).bearing;
    final x = (meters.clamp(0.0, path.totalMeters)) / _step;
    final i = x.floor().clamp(0, list.length - 1);
    final j = math.min(i + 1, list.length - 1);
    return _lerpAngle(list[i], list[j], x - i);
  }

  /// Pose bei [meters]: Vorderachse exakt auf der Route, Richtungen aus der
  /// Schleppkurve, [metersPerUnit] wie bei [articulate].
  ArticulatedPose pose(double meters, {required double metersPerUnit}) {
    final m = meters.clamp(0.0, path.totalMeters);
    final front = path.at(m).point;
    final tractor = _sample(_tractor, m);
    final trailer = _sample(_trailer, m);
    final kingpin = destination(front, dims.kingpinBehindFront * metersPerUnit, (tractor + 180) % 360);
    return ArticulatedPose(
      frontAxle: front,
      kingpin: kingpin,
      trailerAxle: destination(kingpin, dims.trailerWheelbase * metersPerUnit, (trailer + 180) % 360),
      tractorHeading: tractor,
      trailerHeading: trailer,
    );
  }
}
