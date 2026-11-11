import 'dart:math' as math;

import 'package:latlong2/latlong.dart';

import 'articulation.dart';
import 'cinematic_camera.dart';
import 'tour_camera.dart';
import 'camera_dramaturgy.dart';
import 'ferry_cinematic.dart';
import 'tour_path.dart';

/// Wie schnell der Sattelzug in der Cinematic-Animation sichtbar fährt –
/// reine Rechnung, ohne Uhr.
///
/// Bisher lief die Fahrt nach [tourEase] gleichmäßig über die Strecke: auf
/// einer langen Tour rund 1,4 km Kartenstrecke je Bild, in Kurven genauso
/// schnell wie auf der Geraden. Hier entsteht stattdessen ein ruhiges
/// Filmtempo:
///
/// - Der Zug fährt [slow]-mal langsamer als bisher.
/// - Die Kamerafahrten behalten ihre Dauer in Sekunden: [retimePlan] setzt
///   sie neu auf die langsamere Fahrt (gleicher Startort, gleiche Dauer).
/// - In Kurven begrenzt die Drehrate der Zugmaschine das Tempo: höchstens
///   [maxTurn] Grad je Sekunde. Davor wird weich gebremst, danach weich
///   beschleunigt (geglättete Zeitdichte, keine Sprünge).
/// - Anfahren und Ankommen bleiben sanft.
///
/// Ergebnis ist eine monotone Zuordnung Fahrzeit ↔ Streckenmeter. Gleiche
/// Tour, gleiche Zuordnung – bei jedem Wiedergabetempo.
class TourMotion {
  TourMotion({
    required this.path,
    required Duration oldDrive,
    required ArticulatedTrack track,
    this.slow = 1.6,
    this.maxTurn = 100,
    this.curveRef = 120,
    this.standHold = 0,
    this.startCreep = 0,
    int samples = 4000,
  }) {
    final total = path.totalMeters;
    final n = math.max(2, samples);
    final dm = total / n;
    final oldS = math.max(0.1, oldDrive.inMicroseconds / 1e6);
    // Reisetempo der bisherigen Fahrt (Mitte von tourEase).
    const r = 0.06;
    final v0 = total / oldS / (1 - r / 2);

    // Drehrate der Zugmaschine je Meter, vorausschauend als Maximum über
    // ±2 Radstände (früh bremsen, spät beschleunigen).
    final heading = [for (var i = 0; i <= n; i++) track.tractorHeadingAt(i * dm)];
    final rate = List<double>.filled(n + 1, 0);
    for (var i = 1; i <= n; i++) {
      rate[i] = angleDiff(heading[i - 1], heading[i]).abs() / math.max(1e-6, dm);
    }
    final look = math.max(1, (2 * track.dims.tractorWheelbase * _unitGuess(track) / dm).round());
    final rateMax = List<double>.filled(n + 1, 0);
    for (var i = 0; i <= n; i++) {
      var m = 0.0;
      for (var j = math.max(0, i - look); j <= math.min(n, i + look); j++) {
        m = math.max(m, rate[j]);
      }
      rateMax[i] = m;
    }

    // Zeitdichte (Sekunden je Meter) je Rasterpunkt.
    final rho = List<double>.filled(n + 1, 0);
    for (var i = 0; i <= n; i++) {
      // Kurven sichtbar ruhiger: je stärker die Zugmaschine bei Reisetempo
      // drehen würde, desto langsamer (weich), dazu die harte Grenze.
      final turnAtBase = v0 / slow * rateMax[i];
      final base = v0 / slow / (1 + turnAtBase / curveRef);
      final cap = rateMax[i] <= 0 ? double.infinity : maxTurn / rateMax[i];
      rho[i] = 1 / math.max(1e-9, math.min(base, cap));
    }
    // Weich: gleitender Mittelwert über ≈ 1,5 % der Strecke.
    final k = math.max(1, (n * 0.0075).round());
    final smooth = List<double>.filled(n + 1, 0);
    var acc = 0.0;
    final prefix = <double>[0];
    for (final v in rho) {
      acc += v;
      prefix.add(acc);
    }
    for (var i = 0; i <= n; i++) {
      final a = math.max(0, i - k), b = math.min(n, i + k);
      smooth[i] = (prefix[b + 1] - prefix[a]) / (b - a + 1);
    }
    // Sanftes Ankommen über ≈ 2,5 s der Normalfahrt; Anfahren nach
    // [startCreep]: am Start fast stehend, dann schwer und weich los.
    final ease = 2.5 * v0 / slow;
    final startEase = (startCreep > 0 ? 1.2 : 2.5) * v0 / slow;
    final minStart = startCreep > 0 ? startCreep : 0.25;
    for (var i = 0; i <= n; i++) {
      final m = i * dm;
      final eEnd = math.min(1.0, (total - m) / math.max(1, ease));
      final eStart = math.min(1.0, m / math.max(1, startEase));
      final rEnd = 0.25 + 0.75 * eEnd * eEnd * (3 - 2 * eEnd);
      final rStart = minStart + (1 - minStart) * eStart * eStart * (3 - 2 * eStart);
      smooth[i] /= math.min(rEnd, rStart);
    }
    // Kumulierte Zeit.
    _t.add(0);
    for (var i = 1; i <= n; i++) {
      _t.add(_t.last + dm * (smooth[i - 1] + smooth[i]) / 2);
    }
    _dm = dm;
  }

  final TourPath path;

  /// Tempo-Faktor der normalen Fahrt gegenüber bisher.
  final double slow;

  /// Höchste sichtbare Drehrate der Zugmaschine in Grad je Sekunde.
  final double maxTurn;

  /// Weiche Kurvenbremse: bei dieser Drehrate (°/s, im Reisetempo) halbes Tempo.
  final double curveRef;

  /// So viele Sekunden steht der Lkw am Start, bevor er anfährt.
  final double standHold;

  /// Intro: Starttempo als Anteil des Reisetempos (0 = wie bisher 25 %).
  final double startCreep;

  final List<double> _t = [];
  double _dm = 1;

  static double _unitGuess(ArticulatedTrack track) =>
      track.path.totalMeters <= 0 ? 1 : 3.1 * metersPerScreenPoint(tourFollowZoom(track.path.totalMeters) + 0.6, track.path.start.latitude);

  Duration get duration => Duration(microseconds: ((_t.last + standHold) * 1e6).round());

  /// Fahrzeit (s), zu der das Fahrzeug [meters] erreicht.
  double secondsAt(double meters) => standHold + _secondsAt(meters);

  double _secondsAt(double meters) {
    final x = meters.clamp(0.0, path.totalMeters) / _dm;
    final i = x.floor().clamp(0, _t.length - 1);
    final j = math.min(i + 1, _t.length - 1);
    return _t[i] + (_t[j] - _t[i]) * (x - i);
  }

  /// Streckenmeter nach [seconds] Fahrzeit.
  double metersAt(double seconds) => _metersAt(seconds - standHold);

  double _metersAt(double seconds) {
    if (seconds <= 0) return 0;
    if (seconds >= _t.last) return path.totalMeters;
    var lo = 0, hi = _t.length - 1;
    while (hi - lo > 1) {
      final mid = (lo + hi) >> 1;
      if (_t[mid] <= seconds) {
        lo = mid;
      } else {
        hi = mid;
      }
    }
    final f = (_t[hi] - _t[lo]) <= 0 ? 0.0 : (seconds - _t[lo]) / (_t[hi] - _t[lo]);
    return math.min(path.totalMeters, (lo + f) * _dm);
  }
}

/// Streckenbereiche (Anteil 0..1), in denen die Kamera eine Fahrt macht –
/// vom letzten FOLLOW-Stützpunkt davor bis zum ersten danach.
List<(double, double)> cameraWindows(CinematicPlan plan) {
  // Stützpunkte des Kamera-Rhythmus zählen wie FOLLOW (keine Kamerafahrt).
  final keys = [
    for (final k in plan.keys)
      isDramaturgyShot(k.shot) ? ShotKey(k.p, 'FOLLOW', orbit: k.orbit, pitch: k.pitch, zoom: k.zoom, ahead: k.ahead) : k,
  ];
  final out = <(double, double)>[];
  var i = 0;
  while (i < keys.length) {
    if (keys[i].shot != 'FOLLOW') {
      final a = i > 0 ? keys[i - 1].p : keys[i].p;
      var j = i;
      while (j < keys.length && keys[j].shot != 'FOLLOW') {
        j++;
      }
      final b = j < keys.length ? keys[j].p : 1.0;
      if (out.isNotEmpty && a <= out.last.$2) {
        out[out.length - 1] = (out.last.$1, math.max(out.last.$2, b));
      } else {
        out.add((a, b));
      }
      i = j;
    } else {
      i++;
    }
  }
  return out;
}

/// Bisherige Fahrzeit (s, nach [tourEase]) bis zum Streckenanteil [p].
double legacyDriveSeconds(double p, Duration drive) {
  final target = p.clamp(0.0, 1.0);
  var lo = 0.0, hi = 1.0;
  for (var i = 0; i < 40; i++) {
    final mid = (lo + hi) / 2;
    if (tourEase(mid) < target) {
      lo = mid;
    } else {
      hi = mid;
    }
  }
  return hi * drive.inMicroseconds / 1e6;
}

/// Kameraregie auf die neue Fahrt umsetzen: Jede Kamerafahrt beginnt am
/// selben Ort und dauert so viele Sekunden wie bisher; nur die ruhige
/// FOLLOW-Fahrt dazwischen wird länger. Fahrten, die an eine Fähre gebunden
/// sind (Häfen, Seestrecke), bleiben an ihrem Ort.
CinematicPlan retimePlan(CinematicPlan plan, TourMotion motion, Duration oldDrive,
    {Set<String> fixed = const {'TO PORT', 'FERRY FOLLOW', 'FERRY SIDE 3/4', 'HIGH DRONE', 'TO DEST PORT'}}) {
  final total = motion.path.totalMeters;
  if (total <= 0) return plan;
  final keys = plan.keys;
  final out = <ShotKey>[];
  var i = 0;
  while (i < keys.length) {
    final k = keys[i];
    if (k.shot == 'FOLLOW' || i == 0) {
      out.add(k);
      i++;
      continue;
    }
    // Fahrt: vom FOLLOW-Stützpunkt davor bis zum ersten FOLLOW danach.
    var j = i;
    while (j < keys.length && keys[j].shot != 'FOLLOW') {
      j++;
    }
    final end = j < keys.length ? j : keys.length - 1;
    final group = keys.sublist(i, end + 1);
    if (group.any((g) => fixed.contains(g.shot))) {
      out.addAll(group);
    } else {
      final anchor = keys[i - 1].p;
      final t0Old = legacyDriveSeconds(anchor, oldDrive);
      final t0New = motion.secondsAt(anchor * total);
      for (final g in group) {
        final t = t0New + legacyDriveSeconds(g.p, oldDrive) - t0Old;
        final p = motion.metersAt(t) / total;
        out.add(ShotKey(math.max(p, out.last.p + 1e-6), g.shot,
            orbit: g.orbit, pitch: g.pitch, zoom: g.zoom, ahead: g.ahead));
      }
    }
    i = end + 1;
  }
  return CinematicPlan(out);
}

/// Filmische Richtungsstabilisierung des überzeichneten Sattelzugs.
///
/// Das Symbol ist auf der Karte Kilometer lang; schon kleine Drehungen
/// schwenken Front und Heck sichtbar seitlich. Deshalb wird die Richtung
/// über die FAHRZEIT (nicht nur über die Strecke) stabilisiert:
/// - kleine, kurze Schlenker werden über ±[smoothSeconds] geglättet,
/// - die Drehgeschwindigkeit ist auf [maxTurn] °/s begrenzt – vorausschauend
///   (vorwärts und rückwärts begrenzt), damit der Zug vor der Kurve weich
///   einlenkt statt hinterherzuhängen,
/// - der Auflieger folgt noch träger: Knick gedämpft ([knickScale]), auf
///   ±[maxKnick] begrenzt und mit [knickTurn] °/s.
/// Vorberechnet mit 60 Werten je Sekunde – deterministisch, 1×/2×/4× gleich.
class CinematicHeading {
  CinematicHeading(this.motion, this.track,
      {required this.maxTurn,
      this.smoothSeconds = 0.8,
      this.knickScale = 0.6,
      this.maxKnick = 30,
      double? knickTurn,
      this.routeGuided = false,
      this.rearAnchor = false,
      this.unitAt,
      DisplayPath? displayPath})
      : _display = displayPath
        ,knickTurn = knickTurn ?? maxTurn * 0.6 {
    final end = motion.duration.inMicroseconds / 1e6;
    final n = math.max(2, (end * _hz).ceil());
    final raw = <double>[];
    final knick = <double>[];
    final dims = track.dims;
    for (var k = 0; k <= n; k++) {
      final m = motion.metersAt(k / _hz);
      if (rearAnchor) {
        final u = unitAt!(motion.path.at(m).point);
        final front = motion.path.at(m).point;
        // Sattelpunkt 3,5 m hinter der Vorderachse, Heck 12,4 m hinter dem
        // Sattelpunkt; das Heck sitzt auf der Route im Abstand der Gesamtlänge.
        final a = dims.kingpinBehindFront * u, b = 12.4 * u;
        final rear = _behind(m, a + b);
        final king = _kingpinBetween(m, front, rear, a, b);
        final tr = _brg(king, front), tl = _brg(rear, king);
        raw.add(tr);
        knick.add(angleDiff(tr, tl) * knickScale);
      } else if (routeGuided) {
        // Zugmaschine und Auflieger-Achsgruppe an der gefahrenen Route:
        // Route vorne → Zugmaschine → Sattelpunkt → Achsgruppe → Route hinten.
        final md = _dm(m);
        final front = this.displayPath.at(md).point;
        final u = unitAt!(front);
        final rear = _behind(md, (_display == null ? 2 : 1) * dims.tractorWheelbase * u);
        final king = _behind(md, dims.kingpinBehindFront * u);
        final axle = _behind(md, (dims.kingpinBehindFront + dims.trailerWheelbase) * u);
        final tr = _brg(rear, front), tl = _brg(axle, king);
        raw.add(tr);
        knick.add(angleDiff(tr, tl) * knickScale);
      } else {
        raw.add(track.tractorHeadingAt(m));
        final pose = track.pose(m, metersPerUnit: 1);
        knick.add(pose.knick * knickScale);
      }
    }
    final h = _unwrap(raw);
    final w = (smoothSeconds * _hz).round();
    _tractor = _limit(_average(h, w), maxTurn / _hz);
    _tractor = _average(_tractor, (0.25 * _hz).round());
    final kk = [for (final v in _average(knick, w)) v.clamp(-maxKnick, maxKnick).toDouble()];
    _knick = _average(_limit(kk, this.knickTurn / _hz), (0.25 * _hz).round());
  }

  static const _hz = 60;

  /// Variante: Auflieger-Achsgruppe an der Route geführt statt geschleppt.
  final bool routeGuided;

  /// Variante: hinteres Aufliegerende an der gefahrenen Route verankert,
  /// Vorderachse auf der Route vorne, Sattelpunkt dazwischen (Knick).
  final bool rearAnchor;

  /// Sattelpunkt K mit |F−K| = a und |K−R| = b; auf der Seite, auf der die
  /// Route zwischen R und F verläuft (außen am Bogen).
  LatLng _kingpinBetween(double m, LatLng f, LatLng r, double a, double b) {
    const d = Distance(calculator: Haversine());
    final c = d(f, r);
    final base = _brg(f, r);
    if (c < 1e-6) return destination(f, a, (motion.path.at(m).bearing + 180) % 360);
    // Dreieck F–K–R: Winkel bei F.
    final cosF = ((a * a + c * c - b * b) / (2 * a * c)).clamp(-1.0, 1.0);
    final ang = math.acos(cosF) * 180 / math.pi;
    final k1 = destination(f, a, (base + ang) % 360), k2 = destination(f, a, (base - ang + 360) % 360);
    // Stetig: die Lösung, die am vorigen Bild anschließt (sonst die nahe
    // der Route).
    final ref = _lastKing ?? _behind(m, a);
    final k = d(k1, ref) <= d(k2, ref) ? k1 : k2;
    _lastKing = k;
    return k;
  }

  LatLng? _lastKing;
  final double Function(LatLng)? unitAt;

  /// Punkt [d] Meter hinter [m] auf der Darstellungslinie ([m] in deren
  /// Metern); vor dem Start gerade verlängert.
  LatLng _behind(double m, double d) => _onDisplay(m - d);

  LatLng _onDisplay(double s) => s >= 0
      ? displayPath.at(s).point
      : destination(displayPath.start, -s, (displayPath.at(0).bearing + 180) % 360);

  final DisplayPath? _display;

  /// Linie, auf der der Lkw gezeichnet wird: die Route, für die Cinematic-
  /// Fahrt auf Lkw-Maßstab geglättet ([smoothDisplayPath]).
  TourPath get displayPath => _display?.path ?? motion.path;

  /// Streckenmeter der Route → Meter der Darstellungslinie (gleicher Ort).
  double _dm(double m) => _display?.map(m) ?? m;

  /// Meter der Darstellungslinie zu Streckenmetern der Route.
  double displayMetersAt(double meters) => _dm(meters);

  /// Zugmaschine geometrisch auf der Darstellungslinie: Vorderachse vorn,
  /// Hinterachse einen Radstand dahinter.
  double _tractorOnDisplay(double md, double u) {
    // Tangente über ±1 Radstand – unabhängig von den Stützpunkten der Linie.
    final b = track.dims.tractorWheelbase * u;
    final ahead = math.min(displayPath.totalMeters, md + b);
    return _brg(_behind(md, b), displayPath.at(ahead).point);
  }

  static double _brg(LatLng a, LatLng b) =>
      a == b ? 0 : (const Distance(calculator: Haversine()).bearing(a, b) + 360) % 360;

  final TourMotion motion;
  final ArticulatedTrack track;
  final double maxTurn;
  final double smoothSeconds;
  final double knickScale;
  final double maxKnick;
  final double knickTurn;
  late List<double> _tractor;
  late List<double> _knick;

  static List<double> _unwrap(List<double> a) {
    final out = <double>[a.first];
    for (var i = 1; i < a.length; i++) {
      out.add(out.last + angleDiff(a[i - 1], a[i]));
    }
    return out;
  }

  static List<double> _average(List<double> a, int half) {
    if (half <= 0) return a;
    final n = a.length;
    final c = List<double>.filled(n + 1, 0);
    for (var i = 0; i < n; i++) {
      c[i + 1] = c[i] + a[i];
    }
    return [
      for (var i = 0; i < n; i++)
        (c[math.min(n - 1, i + half) + 1] - c[math.max(0, i - half)]) /
            (math.min(n - 1, i + half) - math.max(0, i - half) + 1),
    ];
  }

  /// Drehrate begrenzen, vorwärts und rückwärts (lenkt vorausschauend ein).
  static List<double> _limit(List<double> a, double step) {
    final f = [...a];
    for (var i = 1; i < f.length; i++) {
      f[i] = f[i - 1] + (a[i] - f[i - 1]).clamp(-step, step);
    }
    for (var i = f.length - 2; i >= 0; i--) {
      f[i] = f[i + 1] + (f[i] - f[i + 1]).clamp(-step, step);
    }
    return f;
  }

  double _at(List<double> a, double meters) {
    final x = motion.secondsAt(meters) * _hz;
    final i = x.floor().clamp(0, a.length - 1);
    final j = math.min(i + 1, a.length - 1);
    return a[i] + (a[j] - a[i]) * (x - i);
  }

  /// Variante: Heckende des Aufliegers exakt auf der gefahrenen Route.
  bool rearOnRoute = false;

  /// Heckende des Aufliegers hinter dem Sattelpunkt (Fahrzeugmeter).
  static const double trailerRearBehindKingpin = 12.4;

  /// Höchste Schwenkgeschwindigkeit des Aufliegers (°/s Fahrzeit).
  static const double trailerMaxTurn = 400;

  /// Heckpunkt auf der Route je Bild (Streckenmeter) und Aufliegerrichtung,
  /// einmal für die ganze Fahrt verfolgt (60 Werte je Sekunde):
  /// - das Heck wandert auf der Route nur vorwärts (kein Springen zwischen
  ///   zwei Routenstellen, wo die Straße eng kurvt oder zurückläuft),
  /// - gesucht wird vom Sattelpunkt aus rückwärts entlang der Route,
  /// - der Auflieger schwenkt höchstens [trailerMaxTurn] °/s.
  /// Vor dem Start: Route gerade nach hinten verlängert.
  late final (List<double>, List<double>) _rearTrack = () {
    final unit = unitAt!;
    final dims = track.dims;
    final n = _tractor.length;
    final rearS = <double>[];
    final trailer = <double>[];
    var prevS = double.negativeInfinity;
    const d = Distance(calculator: Haversine());
    for (var k = 0; k < n; k++) {
      final m = _dm(motion.metersAt(k / _hz));
      final front = displayPath.at(m).point;
      final u = unit(front);
      final tractor = _display != null ? _tractorOnDisplay(m, u) : (_tractor[k] % 360 + 360) % 360;
      final kp = destination(front, dims.kingpinBehindFront * u, (tractor + 180) % 360);
      final len = trailerRearBehindKingpin * u;
      // Rückwärts in kleinen Schritten bis zum ersten Punkt im Abstand len.
      final step = len / 12;
      var sOut = m - dims.kingpinBehindFront * u - len; // Fallback: gerade
      for (var s = m - dims.kingpinBehindFront * u; s >= m - 4 * len; s -= step) {
        final q = _onDisplay(s);
        if (d(q, kp) >= len) {
          // fein zwischen s und s + step
          var lo = s, hi = s + step;
          for (var r = 0; r < 20; r++) {
            final mid = (lo + hi) / 2;
            final qm = _onDisplay(mid);
            if (d(qm, kp) >= len) {
              lo = mid;
            } else {
              hi = mid;
            }
          }
          sOut = lo;
          break;
        }
      }
      sOut = math.max(sOut, prevS); // nur vorwärts
      prevS = sOut;
      final rear = _onDisplay(sOut);
      var h = rear == kp ? tractor : _brg(rear, kp);
      // Als Knick relativ zur Zugmaschine sammeln (glatt, ohne Umbruch).
      final knick = angleDiff(tractor, h);
      rearS.add(sOut);
      trailer.add(knick);
    }
    // Auf der geglätteten Darstellungslinie sitzt das Heck exakt; nur ganz
    // leicht glätten, Grenzen als Sicherheit.
    var k = [for (final v in trailer) v.clamp(-dims.maxKnick, dims.maxKnick).toDouble()];
    k = _limit(k, trailerMaxTurn / _hz);
    k = _average(k, (0.05 * _hz).round());
    return (rearS, k);
  }();

  /// Meter der Darstellungslinie, auf denen das Heck liegt (für die Spur).
  double rearMetersAt(double meters, LatLng kingpin, double metersPerUnit) =>
      math.max(0.0, _at(_rearTrack.$1, meters.clamp(0.0, motion.path.totalMeters)));

  /// Pose bei [meters]: Vorderachse exakt auf der Route, Richtungen stabilisiert.
  ArticulatedPose pose(double meters, {required double metersPerUnit}) {
    final m = meters.clamp(0.0, motion.path.totalMeters);
    final md = _dm(m);
    final front = displayPath.at(md).point;
    final tractor = _display != null && rearOnRoute
        ? _tractorOnDisplay(md, metersPerUnit)
        : (_at(_tractor, m) % 360 + 360) % 360;
    var trailer = (tractor + _at(_knick, m) + 360) % 360;
    if (rearOnRoute) trailer = (tractor + _at(_rearTrack.$2, m) + 360) % 360;
    final dims = track.dims;
    // An der Route geführt: Sattelpunkt auf der gefahrenen Linie.
    final kingpin = rearAnchor || rearOnRoute
        ? destination(front, dims.kingpinBehindFront * metersPerUnit, (tractor + 180) % 360)
        : routeGuided
        ? _behind(m, dims.kingpinBehindFront * metersPerUnit)
        : destination(front, dims.kingpinBehindFront * metersPerUnit, (tractor + 180) % 360);
    return ArticulatedPose(
      frontAxle: front,
      kingpin: kingpin,
      trailerAxle: destination(kingpin, dims.trailerWheelbase * metersPerUnit, (trailer + 180) % 360),
      tractorHeading: tractor,
      trailerHeading: trailer,
    );
  }
}

/// Vergleichsschalter (nur Entwicklung, per --dart-define): maximale
/// Drehrate der Zugmaschine in °/s (0 = ohne Stabilisierung, bisheriger
/// Stand) und sichtbare Fahrzeuggröße in Prozent.
const int cinematicMaxTurnDefine = int.fromEnvironment('CINEMATIC_MAX_TURN');
const int cinematicTruckScaleDefine = int.fromEnvironment('CINEMATIC_TRUCK_SCALE', defaultValue: 100);

/// Gezeichnete Größe des Sattelzugs in der Cinematic-Fahrt gegenüber dem
/// bisherigen Symbol. Nähe entsteht über den Kamerazoom.
const double cinematicDriveScale = 0.6;

/// Die Kamera rückt dafür insgesamt näher (Zoomstufen): ≈ 85 % des
/// Ausgleichs – der Lkw wirkt etwas kleiner als früher, liegt auf der Karte
/// aber deutlich kürzer.
final double cinematicCameraZoomOffset = 0.85 * math.log(1 / cinematicDriveScale) / math.ln2;

/// Vergleichsschalter: Auflieger geschleppt (0), Achsgruppe an der Route (1)
/// oder Heck an der gefahrenen Route verankert (2).
const int cinematicGuideDefine = int.fromEnvironment('CINEMATIC_GUIDE', defaultValue: 3);

/// Gefahrene Spur endet an der Achsgruppe des Aufliegers (true) statt an
/// der Kabine – der Auflieger „zeichnet“ die Route.
const bool cinematicTrailRearDefine = bool.fromEnvironment('CINEMATIC_TRAIL_REAR', defaultValue: true);

/// Ruhiges Filmtempo und dazu passende Kameraregie für eine Tour – rein aus
/// der Linie berechnet; [truckScale] wie in der Szene. [heading]: filmische
/// Richtungsstabilisierung, wenn [maxTurn] > 0.
({TourMotion motion, CinematicPlan plan, CinematicHeading? heading}) cinematicMotionFor(TourPath path,
    {bool demo = false,
    double truckScale = 1,
    double? motionTruckScale,
    double Function(double meters)? nightAt,
    bool dramaturgy = true,
    int maxTurn = cinematicMaxTurnDefine,
    int guide = cinematicGuideDefine}) {
  final oldDrive = tourAnimationDuration(path.totalMeters);
  final zoom = (tourFollowZoom(path.totalMeters) + 0.6).clamp(tourMinZoom, tourMaxZoom);
  double unitAt(LatLng p) => 5 * truckScale * 0.62 * metersPerScreenPoint(zoom, p.latitude);
  final track = ArticulatedTrack(path, unitAt: unitAt, inertia: cinematicTruckInertia);
  // Tempo nach der Bezugsgröße – ein kleiner gezeichneter Lkw fährt die
  // Tour nicht länger.
  final ms = motionTruckScale ?? truckScale;
  final motionTrack = ms == truckScale
      ? track
      : ArticulatedTrack(path,
          unitAt: (p) => 5 * ms * 0.62 * metersPerScreenPoint(zoom, p.latitude), inertia: cinematicTruckInertia);
  final motion = TourMotion(path: path, oldDrive: oldDrive, track: motionTrack, startCreep: dramaturgy ? 0.03 : 0);
  final plan = retimePlan(cinematicPlanFor(path, demo: demo), motion, oldDrive);
  return (
    motion: motion,
    plan: dramaturgy ? dramatizePlan(plan, motion, nightAt: nightAt) : plan,
    heading: guide > 0
        ? (CinematicHeading(motion, track,
            maxTurn: maxTurn > 0 ? maxTurn.toDouble() : 60,
            smoothSeconds: 0.4,
            knickScale: 1,
            maxKnick: 45,
            routeGuided: guide == 1 || guide == 3,
            rearAnchor: guide == 2,
            unitAt: unitAt,
            displayPath: guide == 3 ? smoothDisplayPath(path, 16.8 * unitAt(path.start)) : null)
          ..rearOnRoute = guide == 3)
        : (maxTurn > 0 ? CinematicHeading(motion, track, maxTurn: maxTurn.toDouble()) : null),
  );
}

/// Darstellungslinie der Cinematic-Fahrt mit Zuordnung zur echten Route.
class DisplayPath {
  DisplayPath(this.path, this._orig, this._disp);
  final TourPath path;
  final List<double> _orig;
  final List<double> _disp;

  /// Meter der echten Route → Meter der Darstellungslinie (gleicher Ort).
  double map(double meters) {
    if (_orig.length < 2) return meters;
    var lo = 0, hi = _orig.length - 1;
    if (meters <= _orig.first) return _disp.first;
    if (meters >= _orig.last) return _disp.last;
    while (hi - lo > 1) {
      final mid = (lo + hi) >> 1;
      if (_orig[mid] <= meters) {
        lo = mid;
      } else {
        hi = mid;
      }
    }
    final f = (meters - _orig[lo]) / (_orig[hi] - _orig[lo]);
    return _disp[lo] + (_disp[hi] - _disp[lo]) * f;
  }
}

/// Darstellungslinie der Cinematic-Fahrt: die Route je Abschnitt in Schritten
/// von [window]/8 neu abgetastet und über ±[window]/2 gemittelt. Schlenker,
/// die kleiner sind als der (stark vergrößert gezeichnete) Lkw, verschwinden;
/// große Kurven bleiben. Start und Ende jedes Abschnitts bleiben exakt.
DisplayPath smoothDisplayPath(TourPath path, double window) {
  final legs = <TourLeg>[];
  final orig = <double>[];
  var legStart = 0.0;
  for (final leg in path.legs) {
    final lp = TourPath([TourLeg(points: leg.points)]);
    final len = lp.totalMeters;
    final step = window <= 0 ? len : window / 8;
    final n = math.max(1, (len / step).ceil());
    final pts = [for (var i = 0; i <= n; i++) lp.at(math.min(len, i * len / n)).point];
    const half = 4;
    // Zwei Durchgänge gleitender Mittelwert ≈ Gauß: weiche Bögen, keine Ecken.
    List<LatLng> pass(List<LatLng> src) => [
          for (var i = 0; i <= n; i++)
            () {
              final h = math.min(half, math.min(i, n - i)); // zu den Enden hin kleiner
              var la = 0.0, lo = 0.0;
              for (var j = i - h; j <= i + h; j++) {
                la += src[j].latitude;
                lo += src[j].longitude;
              }
              return LatLng(la / (2 * h + 1), lo / (2 * h + 1));
            }(),
        ];
    final out = pass(pass(pts));
    for (var i = 0; i <= n; i++) {
      orig.add(legStart + i * len / n);
    }
    legs.add(TourLeg(points: out, kind: leg.kind, label: leg.label));
    legStart += len;
  }
  final dp = TourPath(legs);
  // Meter der neuen Linie an jedem Stützpunkt (Abschnitte hintereinander).
  final disp = <double>[];
  var acc = 0.0;
  const d = Distance(calculator: Haversine());
  for (final leg in legs) {
    for (var i = 0; i < leg.points.length; i++) {
      if (i > 0) acc += d(leg.points[i - 1], leg.points[i]);
      disp.add(acc);
    }
  }
  // TourPath verbindet Abschnitte ohne Lücke (gleiche Endpunkte) – Längen passen.
  return DisplayPath(dp, orig, disp.length == orig.length ? disp : orig);
}
