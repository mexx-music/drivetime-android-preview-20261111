import 'dart:math' as math;

import 'package:latlong2/latlong.dart';

import 'articulation.dart';
import 'cinematic_camera.dart';
import 'tour_camera.dart';
import 'tour_path.dart';

/// EXPERIMENT – Cinematic-Outro v1: das Finale nach Erreichen des Ziels.
///
/// Reine Rechnung ohne Flutter und ohne Uhr: Jeder Zustand (Kamera, Licht,
/// Einblendungen) ist eine Funktion der Outro-Zeit [t] in Sekunden ab
/// Ankunft. 1×/2×/4× ändern nur, wie schnell [t] läuft – nie Ablauf oder
/// Gestaltung. Gleiche Tour + gleiche Zeit = gleiches Bild (Videoexport).

/// Ein Land der Reise in Fahrtreihenfolge.
class OutroCountry {
  const OutroCountry(this.iso, this.name);
  final String iso;
  final String name;
}

/// Was das Finale zeigt – ausschließlich aus der fertigen Tour.
class OutroData {
  const OutroData({
    required this.from,
    required this.to,
    required this.km,
    required this.countries,
    this.days,
    this.ferries = 0,
  });

  final String from;
  final String to;
  final double km;

  /// Durchfahrene Länder in tatsächlicher Reihenfolge (nicht dedupliziert).
  final List<OutroCountry> countries;

  /// Fahrtage laut Planung; null = unbekannt (dann nicht gezeigt).
  final int? days;

  /// Fährüberfahrten der Tour (Fährabschnitte der Linie).
  final int ferries;

  /// Anzahl verschiedener Länder (für „8 LÄNDER“).
  int get distinctCountries => countries.map((c) => c.iso).toSet().length;
}

/// Fährüberfahrten einer Tour = Fährabschnitte der Linie.
int ferryCount(TourPath path) =>
    path.legs.where((l) => l.kind == TourLegKind.ferry && l.points.length >= 2).length;

double _smooth(double x) {
  final t = x.clamp(0.0, 1.0);
  return t * t * (3 - 2 * t);
}

/// Weicher als smoothstep (ruhiger Anfang und Auslauf).
double _smoother(double x) {
  final t = x.clamp(0.0, 1.0);
  return t * t * t * (t * (t * 6 - 15) + 10);
}

double _ramp(double t, double a, double b) => b <= a ? (t >= a ? 1 : 0) : _smooth((t - a) / (b - a));

/// Zeitplan des Outros (Sekunden ab Ankunft) mit Markern für die spätere
/// Musik-Synchronisierung.
class OutroTimeline {
  OutroTimeline({required this.countryCount, this.overview = 0}) {
    // Länder: 0,18–0,42 s Abstand, zusammen höchstens ≈ 3,6 s.
    countryStep = countryCount <= 0 ? 0 : (3.6 / countryCount).clamp(0.18, 0.42);
    countriesComplete = countriesStart + countryCount * countryStep + entryFade;
    statsReveal = math.max(overview + 5.6, countriesComplete - 0.4);
    finalLogo = statsReveal + 1.8;
    end = finalLogo + 2.0;
  }

  final int countryCount;

  /// Dauer der Reise-Übersicht nach der Ankunft (Sekunden; 0 = ohne): die
  /// Kamera steigt auf, die ganze Route passt ins Bild, die gefahrene
  /// Strecke leuchtet einmal auf – dann erst der Hero-Truck.
  final double overview;

  static const double arrival = 0;
  double get heroReveal => overview + 1.2;
  double get lightsOn => overview + 3.0;
  double get countriesStart => overview + 3.6;

  /// Aufleuchten der gefahrenen Strecke in der Übersicht 0..1..0.
  double routeGlow(double t) {
    if (overview <= 0) return 0;
    final a = 1.6, b = overview - 0.6;
    if (t <= a || t >= b) return 0;
    return math.sin(math.pi * (t - a) / (b - a));
  }

  /// Dauer, in der ein Eintrag hereinkommt.
  static const double entryFade = 0.5;

  late final double countryStep;
  late final double countriesComplete;
  late final double statsReveal;
  late final double finalLogo;

  /// Ende; die letzten ≥ 2 s steht das fertige Bild ruhig.
  late final double end;

  Duration get duration => Duration(microseconds: (end * 1e6).round());

  /// Musikmarker in Reihenfolge.
  Map<String, double> get markers => {
        'arrival': arrival,
        if (overview > 0) 'routeOverview': 0.4,
        if (overview > 0) 'routeGlow': 1.6,
        'heroReveal': heroReveal,
        'lightsOn': lightsOn,
        'countriesStart': countriesStart,
        'countriesComplete': countriesComplete,
        'statsReveal': statsReveal,
        'finalLogo': finalLogo,
        'end': end,
      };

  // --------------------------------------------------------- Einblendungen

  /// Abdunklung der Umgebung 0..1 (Ziel bleibt erkennbar).
  double dim(double t) => _ramp(t, overview + 0.8, overview + 3.2);

  /// Titel „Tour abgeschlossen“ / Ankunftsort.
  double title(double t) => _ramp(t, heroReveal + 0.3, heroReveal + 1.2);

  /// Eintrag [i] der Länderliste 0..1.
  double country(int i, double t) {
    final s = countriesStart + i * countryStep;
    return _ramp(t, s, s + entryFade);
  }

  double stats(double t) => _ramp(t, statsReveal, statsReveal + 0.8);

  /// Echtes Foto des Lkw: nach dem Lichtlauf weich über das Modell.
  double get photoReveal => lightsOn + 2.0;
  double photo(double t) => _ramp(t, photoReveal, photoReveal + 1.4);
  double logo(double t) => _ramp(t, finalLogo, finalLogo + 0.9);

  // ---------------------------------------------------------------- Licht

  /// Rück- und Begrenzungslichter.
  double tailLights(double t) => _ramp(t, lightsOn, lightsOn + 0.4);

  /// Scheinwerfer (und Lichtkegel), weich nach den Rücklichtern.
  double headLights(double t) => _ramp(t, lightsOn + 0.4, lightsOn + 1.0);

  /// Lichtlauf über Kabine und Auflieger: Position 0 (Front) … 1 (Heck),
  /// null außerhalb des Laufs.
  double? sweep(double t) {
    final a = lightsOn + 1.0, b = lightsOn + 2.0;
    if (t < a || t > b) return null;
    return _smoother((t - a) / (b - a));
  }
}

/// Licht-Zustand für ein Fahrzeugbild – quantisiert, damit nur wenige Bilder
/// entstehen und jeder Schritt klein bleibt.
class OutroLights {
  const OutroLights({required this.tail, required this.head, this.sweep});

  final double tail;
  final double head;
  final double? sweep;

  /// [sweepSteps]: Stufen des Lichtkegel-Schwenks (Qualitätsprofil).
  factory OutroLights.at(OutroTimeline tl, double t, {int sweepSteps = 8}) {
    double q4(double v) => (v.clamp(0.0, 1.0) * 4).round() / 4;
    final s = tl.sweep(t);
    return OutroLights(
      tail: q4(tl.tailLights(t)),
      head: q4(tl.headLights(t)),
      sweep: s == null ? null : (s * sweepSteps).round() / sweepSteps,
    );
  }

  String get key => 't${(tail * 4).round()}h${(head * 4).round()}s${sweep == null ? '-' : (sweep! * 8).round()}';
}

// ---------------------------------------------------------------- Kamera

/// Wo der Truck im Bild stehen soll (Anteil der Breite/Höhe ab oben links)
/// und wie groß (Länge als Anteil der Breite).
({double x, double y, double length}) outroComposition({required bool portrait}) =>
    portrait ? (x: 0.6, y: 0.56, length: 0.48) : (x: 0.66, y: 0.52, length: 0.36);

/// Hero-Kamera des Outros. Startet exakt im letzten Zustand der Fahrt
/// ([from]) und fährt in eine 3/4-Ansicht schräg von vorn links, näher heran
/// (Zoom – der Truck wird nicht vergrößert), steiler, Truck rechts der Mitte.
class OutroCamera {
  OutroCamera({
    required this.from,
    required this.truck,
    required this.heading,
    required this.followZoom,
    required this.truckPointsPerMeter,
    required this.width,
    required this.height,
    required this.timeline,
    this.routeSouthWest,
    this.routeNorthEast,
  });

  final CameraState from;

  /// Ausdehnung der ganzen Route (für die Übersicht); null = ohne.
  final LatLng? routeSouthWest;
  final LatLng? routeNorthEast;

  bool get _hasOverview => timeline.overview > 0 && routeSouthWest != null && routeNorthEast != null;

  /// Kamera der Übersicht: ganze Route im Bild, genordet, flach geneigt.
  CameraState get overviewState {
    final sw = routeSouthWest!, ne = routeNorthEast!;
    final c = LatLng((sw.latitude + ne.latitude) / 2, (sw.longitude + ne.longitude) / 2);
    const d = Distance(calculator: Haversine());
    final wm = d(LatLng(c.latitude, sw.longitude), LatLng(c.latitude, ne.longitude));
    final hm = d(LatLng(sw.latitude, c.longitude), LatLng(ne.latitude, c.longitude));
    final mpp = math.max(wm / (0.8 * width), hm / ((portrait ? 0.62 : 0.72) * height));
    final zoom = math.log(78271.517 * math.cos(c.latitude * math.pi / 180) / math.max(1e-6, mpp)) / math.ln2;
    return CameraState(target: c, bearing: 0, pitch: 18, zoom: zoom, shot: 'OVERVIEW', orbit: 0);
  }

  static double _lerpAngle(double a, double b, double t) => (a + angleDiff(a, b) * t + 360) % 360;

  static CameraState _blend(CameraState a, CameraState b, double t, String shot) => CameraState(
        target: LatLng(a.target.latitude + (b.target.latitude - a.target.latitude) * t,
            a.target.longitude + (b.target.longitude - a.target.longitude) * t),
        bearing: _lerpAngle(a.bearing, b.bearing, t),
        pitch: a.pitch + (b.pitch - a.pitch) * t,
        zoom: a.zoom + (b.zoom - a.zoom) * t,
        shot: shot,
        orbit: a.orbit + (b.orbit - a.orbit) * t,
      );

  /// Fahrzeug am Ziel (Sattelpunkt) und Richtung der Zugmaschine.
  final LatLng truck;
  final double heading;
  final double followZoom;

  /// Bildschirmpunkte je Fahrzeugmeter beim Folge-Zoom.
  final double truckPointsPerMeter;
  final double width;
  final double height;
  final OutroTimeline timeline;

  static const double heroOrbit = -152; // Kamera vorn links: Front + linke Seite
  static const double heroPitch = 56;

  bool get portrait => width < height;

  /// Zoom, bei dem der Sattelzug (16,8 m) die gewünschte Bildlänge hat.
  double get heroZoom {
    final c = outroComposition(portrait: portrait);
    final want = math.min(c.length * width, 0.5 * height);
    final now = 16.8 * truckPointsPerMeter;
    return followZoom + math.log(want / now) / math.ln2;
  }

  double get heroBearing => (heading - heroOrbit) % 360;

  /// Blickpunkt so, dass der Truck an der Kompositionsstelle steht.
  LatLng heroTarget(double bearing, double zoom, double pitch) {
    final c = outroComposition(portrait: portrait);
    final mpp = metersPerScreenPoint(zoom, truck.latitude);
    final dx = (c.x - 0.5) * width * mpp; // Truck rechts der Mitte
    final dy = (c.y - 0.5) * height * mpp / math.cos(pitch * math.pi / 180);
    // Mitte = Truck − dx nach rechts − dy nach unten.
    final p = destination(truck, dx, (bearing - 90 + 360) % 360);
    return destination(p, dy, bearing);
  }

  CameraState at(double t) {
    if (!_hasOverview) return _heroAt(t, from, 0);
    // Übersicht: in ≈ 2,2 s hinauf, bis die ganze Route im Bild ist, halten
    // (Strecke leuchtet auf), dann hinunter in den Hero-Shot.
    final ov = overviewState;
    final heroStart = timeline.overview - 1.2;
    if (t < heroStart) return _blend(from, ov, _smoother(t / 2.2), 'OVERVIEW');
    return _heroAt(t - heroStart, ov, heroStart);
  }

  /// Hero-Fahrt ab [base] ([t] relativ zum Beginn, [offset] = Beginn absolut).
  CameraState _heroAt(double t, CameraState from, double offset) {
    // Phase 1 (0–1,2 s): ruhig weiter, minimal näher und steiler.
    // Phase 2 (0,4–3,4 s): Drohne schwenkt in die 3/4-Ansicht.
    // Danach: sehr langsamer Nachlauf, der vor dem Schluss stillsteht.
    final move = _smoother((t - 0.4) / 3.0);
    final settle = _smoother((t - 3.4) / math.max(0.1, timeline.end - offset - 2.0 - 3.4));
    final bearingTarget = (heroBearing + 6 * settle) % 360;
    final bearing = (from.bearing + angleDiff(from.bearing, bearingTarget) * move + 360) % 360;
    final arrive = offset > 0 ? 0.0 : _smooth(t / 1.2);
    final zoom = from.zoom + 0.25 * arrive * (1 - move) + (heroZoom - 0.12 + 0.12 * settle - from.zoom) * move;
    final pitch = from.pitch + 3 * arrive * (1 - move) + (heroPitch - from.pitch) * move;
    final hero = heroTarget(bearing, zoom, pitch);
    final lat = from.target.latitude + (hero.latitude - from.target.latitude) * _smoother((t - 0.1) / 3.2);
    final lon = from.target.longitude + (hero.longitude - from.target.longitude) * _smoother((t - 0.1) / 3.2);
    return CameraState(
      target: LatLng(lat, lon),
      bearing: bearing,
      pitch: pitch,
      zoom: zoom,
      shot: t + offset < timeline.heroReveal ? 'ARRIVAL' : 'HERO',
      orbit: heroOrbit * move,
    );
  }
}
