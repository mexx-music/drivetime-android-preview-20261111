
import 'package:latlong2/latlong.dart';

import 'tour_camera.dart';
import 'tour_path.dart';

/// Kameramodus der 2.5D-Animation.
enum CameraMode {
  /// Bisherige ruhige Folgekamera – Standard.
  follow,

  /// Folgekamera mit wenigen, festgelegten „Drohnen“-Fahrten um den LKW.
  cinematic,
}

/// Ein Stützpunkt der Kameraregie, gesetzt nach Streckenanteil [p] (0..1).
///
/// Kamera RELATIV zum Fahrzeug:
/// - [orbit]: Bahnwinkel um den LKW in Grad – 0 dahinter, +90 rechts daneben,
///   −90 links daneben, ±180 davor. Werte dürfen über ±180 hinaus laufen
///   (stetige Drehung); die Kamerarichtung ist Fahrtrichtung − orbit.
/// - [pitch]: Neigung (0 = senkrecht von oben).
/// - [zoom]: Zuschlag auf den Folge-Zoom (näher > 0).
/// - [ahead]: Zielpunkt vor dem LKW in Vielfachen des Folge-Abstands
///   (1 = wie Folgekamera, 0 = auf dem LKW, < 0 = dahinter).
class ShotKey {
  const ShotKey(this.p, this.shot, {this.orbit = 0, this.pitch = 42, this.zoom = 0, this.ahead = 1});

  final double p;
  final String shot;
  final double orbit;
  final double pitch;
  final double zoom;
  final double ahead;
}

/// Kamerawerte an einer Stelle der Regie.
class ShotSample {
  const ShotSample(this.shot, this.orbit, this.pitch, this.zoom, this.ahead);
  final String shot;
  final double orbit;
  final double pitch;
  final double zoom;
  final double ahead;
}

/// Die Regie: Stützpunkte nach Streckenanteil, weich verbunden.
class CinematicPlan {
  const CinematicPlan(this.keys);

  final List<ShotKey> keys;

  /// Nur Folgekamera.
  static const followOnly = CinematicPlan([ShotKey(0, 'FOLLOW'), ShotKey(1, 'FOLLOW')]);

  static const _f = 'FOLLOW';

  /// Zoom-Zuschläge: In der Normalfahrt ist der LKW klein (viel Umgebung);
/// für Seite und Front kommt die KAMERA näher (+0,85 … +1,25 Stufen), statt
/// das Fahrzeug zu vergrößern.
///
/// Zwei Manöver für lange Touren: links vorbei → schräg von vorn →
  /// über die Front auf die rechte Seite zurück; später rechts vorbei.
  /// Kein Manöver in den letzten ≈ 9 % (ruhiger Zielanflug).
  static const _two = [
    ShotKey(0.00, _f),
    ShotKey(0.17, _f),
    ShotKey(0.29, 'PASS', orbit: -95, pitch: 52, zoom: 1.25, ahead: 0),
    ShotKey(0.35, 'FRONT 3/4', orbit: -155, pitch: 50, zoom: 1.15, ahead: -0.25),
    ShotKey(0.39, 'FRONT 3/4', orbit: -165, pitch: 50, zoom: 1.15, ahead: -0.25),
    ShotKey(0.49, 'RETURN', orbit: -255, pitch: 58, zoom: 0.85, ahead: 0.2),
    ShotKey(0.58, _f, orbit: -360),
    ShotKey(0.70, _f, orbit: -360),
    ShotKey(0.79, 'PASS', orbit: -265, pitch: 52, zoom: 1.25, ahead: 0),
    ShotKey(0.84, 'SIDE 3/4', orbit: -250, pitch: 50, zoom: 1.15, ahead: -0.1),
    ShotKey(0.91, _f, orbit: -360),
    ShotKey(1.00, _f, orbit: -360),
  ];

  /// Ein Manöver (mittlere Touren).
  static const _one = [
    ShotKey(0.00, _f),
    ShotKey(0.25, _f),
    ShotKey(0.38, 'PASS', orbit: -95, pitch: 52, zoom: 1.25, ahead: 0),
    ShotKey(0.45, 'FRONT 3/4', orbit: -155, pitch: 50, zoom: 1.15, ahead: -0.25),
    ShotKey(0.49, 'FRONT 3/4', orbit: -165, pitch: 50, zoom: 1.15, ahead: -0.25),
    ShotKey(0.60, 'RETURN', orbit: -255, pitch: 58, zoom: 0.85, ahead: 0.2),
    ShotKey(0.70, _f, orbit: -360),
    ShotKey(1.00, _f, orbit: -360),
  ];

  /// Standard je nach Fahrtdauer bei 1×: kurz nur Folgen, mittel ein
  /// Manöver, lang zwei. Deterministisch – gleiche Route, gleiche Regie.
  static CinematicPlan standard(Duration drive) {
    final s = drive.inMilliseconds / 1000;
    if (s < 15) return followOnly;
    if (s < 25) return const CinematicPlan(_one);
    return const CinematicPlan(_two);
  }

  /// Beschleunigt zum Ansehen: dieselben zwei Manöver, gedrängt in
  /// 3–62 % der Fahrt.
  static CinematicPlan demo() => CinematicPlan([
        for (final k in _two)
          ShotKey(k.p <= 0.17 ? k.p * 0.03 / 0.17 : (k.p >= 0.91 ? 0.62 + (k.p - 0.91) / 0.09 * 0.38 : 0.03 + (k.p - 0.17) / 0.74 * 0.59),
              k.shot,
              orbit: k.orbit, pitch: k.pitch, zoom: k.zoom, ahead: k.ahead),
      ]);

  static double _smooth(double t) => t * t * (3 - 2 * t);

  /// Werte bei Streckenanteil [p] – stetig, ohne Sprung an Stützpunkten.
  ShotSample at(double p) {
    final x = p.clamp(0.0, 1.0);
    for (var i = 1; i < keys.length; i++) {
      final a = keys[i - 1], b = keys[i];
      if (x > b.p && i < keys.length - 1) continue;
      final t = b.p <= a.p ? 1.0 : _smooth(((x - a.p) / (b.p - a.p)).clamp(0.0, 1.0));
      double lerp(double u, double v) => u + (v - u) * t;
      // Shot-Name: der des Ziels, solange die Kamera unterwegs ist.
      final name = (a.shot == b.shot || t >= 0.5) ? b.shot : (b.shot == _f ? a.shot : b.shot);
      return ShotSample(name, lerp(a.orbit, b.orbit), lerp(a.pitch, b.pitch), lerp(a.zoom, b.zoom),
          lerp(a.ahead, b.ahead));
    }
    final k = keys.last;
    return ShotSample(k.shot, k.orbit, k.pitch, k.zoom, k.ahead);
  }

  /// Anzahl der Manöver (für Tests und Anzeige).
  int get manoeuvres => keys.where((k) => k.shot == 'PASS').length;
}

/// Kamerazustand für MapLibre (center/bearing/pitch/zoom = Bahn um [target]).
class CameraState {
  const CameraState({
    required this.target,
    required this.bearing,
    required this.pitch,
    required this.zoom,
    required this.shot,
    required this.orbit,
  });

  final LatLng target;
  final double bearing;
  final double pitch;
  final double zoom;
  final String shot;
  final double orbit;
}

/// Cinematic-Kamera um den LKW – reine Rechnung, Bild für Bild.
///
/// Liest nur [TourPath], Fahrzeugposition (Streckenmeter) und Zeit; sie
/// beeinflusst das Fahrzeug nie. Die Fahrtrichtung kommt aus derselben
/// geglätteten Folgekamera ([TourCameraRig]); darauf wird der Bahnwinkel
/// der Regie gelegt und die Drehung auf [maxTurn] Grad/s begrenzt.
class CinematicCamera {
  CinematicCamera(
    this.path, {
    this.plan = CinematicPlan.followOnly,
    this.aspect = 1.6,
    this.maxTurn = 45,
    this.zoomOffset = 0,
  }) : rig = TourCameraRig(path);

  /// Zusätzliche Nähe der ganzen Regie (Zoomstufen, im Hochformat nicht
  /// gedämpft) – gleicht einen kleiner gezeichneten Lkw aus, ohne ihn auf
  /// der Karte länger zu machen.
  final double zoomOffset;

  final TourPath path;
  final CinematicPlan plan;

  /// Breite / Höhe des Bildes: im Hochformat etwas weiter weg.
  final double aspect;

  /// Höchste Drehgeschwindigkeit der Kamera in Grad pro Sekunde.
  final double maxTurn;

  final TourCameraRig rig;
  double? _bearing;

  /// Hochformat (< 0,75): etwas weiter heraus und nähere Shots dämpfen.
  double get _portrait => aspect < 0.75 ? 1 : 0;

  /// Folge-Zoom (Bezug auch für die Fahrzeuggröße).
  double get followZoom => rig.zoom - 0.45 * _portrait;

  CameraState step(double meters, Duration dt, {double? manualZoom}) {
    final total = path.totalMeters;
    final p = total <= 0 ? 0.0 : meters / total;
    final heading = rig.step(meters, dt);
    // Manueller Zoom: Regie aus, bisherige Folgekamera mit Nutzer-Zoom.
    final s = manualZoom != null ? const ShotSample('FOLLOW', 0, 42, 0, 1) : plan.at(p);
    final desired = (heading - s.orbit) % 360;
    final cur = _bearing;
    final secs = dt.inMicroseconds / 1e6;
    final double bearing;
    if (cur == null) {
      bearing = desired;
    } else {
      final limit = maxTurn * secs;
      bearing = (cur + angleDiff(cur, desired).clamp(-limit, limit) + 360) % 360;
    }
    _bearing = bearing;

    final ahead = (total * 0.006).clamp(1500.0, 15000.0) * s.ahead;
    final target = path.at((meters + ahead).clamp(0.0, total)).point;
    final zoomBoost = s.zoom > 0 ? s.zoom * (1 - 0.5 * _portrait) : s.zoom;
    return CameraState(
      target: target,
      bearing: bearing,
      pitch: s.pitch,
      zoom: manualZoom ?? (followZoom + zoomOffset + zoomBoost).clamp(tourMinZoom, tourMaxZoom),
      shot: s.shot,
      orbit: s.orbit,
    );
  }

  void reset() {
    rig.reset();
    _bearing = null;
  }
}
