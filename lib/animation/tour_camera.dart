import 'dart:math' as math;

import 'package:latlong2/latlong.dart';

import 'tour_path.dart';

/// Ruhige 2.5D-Kameraführung entlang einer [TourPath] – reine Rechnung.
///
/// Experiment (MapLibre): Die Kamera blickt in Fahrtrichtung, aber geglättet:
/// Die Richtung wird über ein langes Stück Strecke gemittelt und dann mit
/// begrenzter Drehgeschwindigkeit nachgeführt. Kleine Kurven drehen die Karte
/// nicht. Der Blickpunkt liegt etwas vor dem LKW, damit Strecke voraus
/// sichtbar ist. Zeit kommt von außen ([step]) – reproduzierbar, auch für
/// einen späteren Videoexport.
class TourCameraRig {
  TourCameraRig(this.path, {this.pitch = 42});

  final TourPath path;

  /// Neigung in Grad.
  final double pitch;

  double? _bearing;

  /// Gemittelte Fahrtrichtung über ein langes Fenster (1 % der Tour,
  /// mindestens 3 km, höchstens 30 km vor und zurück).
  double headingAt(double meters) {
    final w = (path.totalMeters * 0.01).clamp(3000.0, 30000.0);
    final a = path.at(math.max(0, meters - w)).point;
    final b = path.at(math.min(path.totalMeters, meters + w)).point;
    if (a == b) return _bearing ?? 0;
    return (const Distance(calculator: Haversine()).bearing(a, b) + 360) % 360;
  }

  /// Blickpunkt: ein Stück vor dem Fahrzeug (0,6 % der Tour, 1,5–15 km).
  LatLng targetAt(double meters) {
    final ahead = (path.totalMeters * 0.006).clamp(1500.0, 15000.0);
    return path.at(math.min(path.totalMeters, meters + ahead)).point;
  }

  /// Zoom für die geneigte Ansicht: etwas näher als in 2D, weil die Neigung
  /// ohnehin mehr Strecke voraus zeigt.
  double get zoom => (tourFollowZoom(path.totalMeters) + 0.6).clamp(tourMinZoom, tourMaxZoom);

  /// Nächste Kamerarichtung nach [dt]; [maxDegPerSecond] begrenzt die
  /// Drehgeschwindigkeit, [smoothing] (Sekunden) dämpft zusätzlich.
  double step(double meters, Duration dt,
      {double maxDegPerSecond = 22, double smoothing = 1.2}) {
    final target = headingAt(meters);
    final current = _bearing;
    if (current == null) return _bearing = target;
    final s = dt.inMicroseconds / 1e6;
    if (s <= 0) return current;
    final diff = angleDiff(current, target);
    final eased = diff * (1 - math.exp(-s / smoothing));
    final limit = maxDegPerSecond * s;
    final turn = eased.clamp(-limit, limit);
    return _bearing = (current + turn + 360) % 360;
  }

  /// Zurück auf Anfang (Neustart).
  void reset() => _bearing = null;

  double? get bearing => _bearing;
}

/// Kürzeste Drehung von [from] nach [to] in Grad, im Bereich -180..180.
double angleDiff(double from, double to) {
  var d = (to - from) % 360;
  if (d > 180) d -= 360;
  if (d < -180) d += 360;
  return d;
}
