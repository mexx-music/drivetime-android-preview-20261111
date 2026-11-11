import 'dart:math' as math;

import 'package:driverroute_eta/animation/articulation.dart';
import 'package:driverroute_eta/animation/daylight.dart';
import 'package:driverroute_eta/animation/tour_path.dart';
import 'package:driverroute_eta/logic/eta_calculator.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';

const _d = Distance(calculator: Haversine());

/// Punkt in [dist] m Richtung [bearing] – ohne Rundung (latlong2 rundet
/// `offset` auf 6 Stellen, das verrauscht kurze Abstände).
LatLng _dest(LatLng p, double dist, double bearing) {
  const r = 6371008.8;
  final d = dist / r, b = bearing * math.pi / 180;
  final la1 = p.latitude * math.pi / 180, lo1 = p.longitude * math.pi / 180;
  final la2 = math.asin(math.sin(la1) * math.cos(d) + math.cos(la1) * math.sin(d) * math.cos(b));
  final lo2 = lo1 + math.atan2(math.sin(b) * math.sin(d) * math.cos(la1), math.cos(d) - math.sin(la1) * math.sin(la2));
  return LatLng(la2 * 180 / math.pi, lo2 * 180 / math.pi);
}

/// Maßstab wie in der App: 1 Fahrzeugmeter = [_unit] Kartenmeter (das Symbol
/// ist überzeichnet). Strecken werden entsprechend skaliert gebaut.
const _unit = 20.0;

/// Strecke aus Kursen: [(Länge, Kurs °), …] in Fahrzeugmetern, Punkte alle 1 m.
TourPath _course(List<(double, double)> legs, {LatLng start = const LatLng(48, 14)}) {
  final pts = <LatLng>[start];
  for (final (len, bearing) in legs) {
    final n = (len / 1).ceil();
    for (var i = 0; i < n; i++) {
      pts.add(_dest(pts.last, len / n * _unit, bearing));
    }
  }
  return TourPath([TourLeg(points: pts)]);
}

/// Bogen mit Radius [r] über [angle]° (Vorzeichen = Richtung), ab Kurs [from].
List<(double, double)> _arc(double r, double from, double angle) {
  final n = (angle.abs() / 3).ceil();
  final step = angle / n;
  final seg = 2 * math.pi * r * (step.abs() / 360);
  return [for (var i = 0; i < n; i++) (seg, from + step * (i + 0.5))];
}

/// Knick und dessen Änderung je Bild über die ganze Strecke.
({double maxKnick, double maxStep, double endKnick}) _drive(TourPath p, {double unit = _unit, double step = 5}) {
  var maxKnick = 0.0, maxStep = 0.0;
  double? last;
  late ArticulatedPose pose;
  for (var m = 0.0; m <= p.totalMeters; m += step * _unit) {
    pose = articulate(p, m, metersPerUnit: unit);
    maxKnick = math.max(maxKnick, pose.knick.abs());
    if (last != null) maxStep = math.max(maxStep, (pose.knick - last).abs());
    last = pose.knick;
  }
  return (maxKnick: maxKnick, maxStep: maxStep, endKnick: pose.knick);
}

void main() {
  group('Gekoppelter Sattelzug', () {
    test('lange Gerade: Zugmaschine und Auflieger gleich ausgerichtet', () {
      final r = _drive(_course([(3000, 90)]));
      expect(r.maxKnick, lessThan(0.5));
    });

    test('Zugmaschine steht immer auf der Route (Vorder- und Hinterachse)', () {
      final p = _course([(500, 0), ..._arc(60, 0, 90), (500, 90)]);
      for (var m = 100.0 * _unit; m < p.totalMeters; m += 37 * _unit) {
        final pose = articulate(p, m, metersPerUnit: _unit);
        expect(_d(pose.frontAxle, p.at(m).point), lessThan(0.01));
        final rear = p.at(m - 3.8 * _unit).point;
        final dir = (_d.bearing(rear, pose.frontAxle) + 360) % 360;
        expect((dir - pose.tractorHeading).abs() % 360, lessThan(0.01));
      }
    });

    for (final (angle, radius) in [(30.0, 150.0), (45.0, 100.0), (90.0, 40.0)]) {
      test('$angle°-Kurve (R $radius m): natürlicher Knick, danach wieder gerade', () {
        final p = _course([(400, 0), ..._arc(radius, 0, angle), (400, angle)]);
        final r = _drive(p, step: 2);
        // Kinematischer Richtwert eines Sattelzugs: Knick ≈ asin(L / R).
        final expected = math.asin(math.min(1, 10.5 / radius)) * 180 / math.pi;
        expect(r.maxKnick, greaterThan(math.min(angle, expected) * 0.4));
        expect(r.maxKnick, lessThanOrEqualTo(math.min(angle, expected) * 1.25 + 1));
        expect(r.endKnick.abs(), lessThan(0.5)); // auf der Geraden wieder ausgerichtet
        expect(r.maxStep, lessThan(3)); // keine Sprünge (je 2 m Fahrt)
      });
    }

    test('Autobahnkreuz (270°-Schleife) und enger Kreisverkehr: begrenzt und ohne Sprung', () {
      final clover = _course([(300, 0), ..._arc(60, 0, -270), (300, 90)]);
      final c = _drive(clover, step: 2);
      expect(c.maxKnick, lessThanOrEqualTo(70));
      expect(c.maxStep, lessThan(3));
      final roundabout = _course([(200, 0), ..._arc(18, 0, 90), ..._arc(18, 90, -180), (200, -90)]);
      final rb = _drive(roundabout, step: 1);
      expect(rb.maxKnick, lessThanOrEqualTo(70)); // nie Einknicken über die Grenze
      expect(rb.maxStep, lessThan(6));
    });

    test('schnelle Folge links/rechts: Auflieger pendelt mit, ohne Ausschlag', () {
      final s = _course([
        (200, 0),
        for (var i = 0; i < 6; i++) ..._arc(50, i.isEven ? 0 : 30, i.isEven ? 30 : -30),
        (300, 0),
      ]);
      final r = _drive(s, step: 2);
      expect(r.maxKnick, lessThan(16)); // höchstens etwas über asin(10,5/50) ≈ 12°
      // Beim Wechsel der Kurvenrichtung drehen Zugmaschine und Auflieger
      // gegenläufig: je Meter höchstens ≈ 2/R (R = 50 m → 2,3°/m). In der
      // Animation fährt das Symbol ≈ 0,5 Fahrzeugmeter je Bild → ≤ ≈ 1°/Bild.
      expect(r.maxStep, lessThan(5)); // je 2 m
    });

    test('überzeichnetes Symbol: Knick folgt der sichtbaren Route (Maßstab)', () {
      // 90°-Ecke mit 5 km Radius: maßstabsgetreu kaum Knick, mit sichtbarer
      // Größe (1 Fahrzeugmeter = 2.000 Kartenmeter) deutlich.
      final p = _course([(3000, 0), ..._arc(250, 0, 90), (3000, 90)]);
      // Maßstabsgetreu nur die kleinen Ecken der Polyline (3° je Punkt).
      expect(_drive(p, unit: 1, step: 10).maxKnick, lessThan(4));
      expect(_drive(p, unit: 300, step: 10).maxKnick, greaterThan(20)); // Auflieger ≈ 3 km sichtbar
    });

    test('Start: Strecke hinter dem Fahrzeug wird gerade verlängert', () {
      final p = _course([(1000, 45)]);
      final pose = articulate(p, 0, metersPerUnit: _unit);
      expect(pose.knick.abs(), lessThan(0.5));
      expect((pose.tractorHeading - 45).abs(), lessThan(0.5));
    });

    test('Kartenmeter je Bildschirmpunkt', () {
      expect(metersPerScreenPoint(0, 0), closeTo(78271.5, 0.1));
      expect(metersPerScreenPoint(1, 60), closeTo(78271.5 / 4, 1));
    });
  });

  group('Tageslicht (lokal, ohne Dienst)', () {
    test('Sonnenhöhe: bekannte Werte', () {
      // Wien, Sommersonnenwende, Mittag (≈ 11:05 UTC): ≈ 65°.
      expect(sunElevation(48.21, 16.37, DateTime.utc(2026, 6, 21, 11, 5)), closeTo(65.2, 1.0));
      // Wien, Sonnenaufgang ≈ 02:54 UTC: um 0° (Refraktion nicht berücksichtigt).
      expect(sunElevation(48.21, 16.37, DateTime.utc(2026, 6, 21, 2, 54)), closeTo(-0.8, 1.2));
      // Mitternacht im Winter: tief unter dem Horizont.
      expect(sunElevation(48.21, 16.37, DateTime.utc(2026, 12, 21, 23, 0)), lessThan(-50));
      // Äquator, Tagundnachtgleiche, 12:07 UTC bei Länge 0: fast senkrecht.
      expect(sunElevation(0, 0, DateTime.utc(2026, 3, 20, 12, 7)), greaterThan(88));
    });

    test('Dunkelheit: Tag 0, Dämmerung dazwischen, Nacht 1, stetig', () {
      expect(nightLevel(30), 0);
      expect(nightLevel(6), 0);
      expect(nightLevel(-8), 1);
      expect(nightLevel(-1), closeTo(0.5, 0.01));
      var last = 0.0;
      for (var e = 10.0; e >= -12; e -= 0.1) {
        final n = nightLevel(e);
        expect(n, greaterThanOrEqualTo(last));
        expect(n - last, lessThan(0.02));
        last = n;
      }
    });

    test('Planzeit entlang der Strecke aus der ETA, Sprung an der Ruhezeit', () {
      final p = _course([(600000, 0)]);
      final t0 = DateTime(2026, 10, 5, 6);
      EtaStep drive(double km, DateTime a, DateTime b) =>
          EtaStep('', type: EtaEventType.drive, distanceKm: km, start: a, end: b);
      final eta = EtaResult([
        drive(300, t0, t0.add(const Duration(hours: 4))),
        EtaStep('', type: EtaEventType.dailyRest, start: t0.add(const Duration(hours: 4)), end: t0.add(const Duration(hours: 15))),
        drive(300, t0.add(const Duration(hours: 15)), t0.add(const Duration(hours: 19))),
      ], null);
      final clock = TourClock.fromEta(eta, p)!;
      final mid = p.totalMeters / 2;
      expect(clock.at(0), t0);
      expect(clock.at(mid / 2), t0.add(const Duration(hours: 2)));
      expect(clock.at(mid), t0.add(const Duration(hours: 4))); // Ankunft vor der Ruhe
      expect(clock.at(mid + 1).difference(t0).inHours, 15); // danach: nach der Ruhe
      expect(clock.at(p.totalMeters), t0.add(const Duration(hours: 19)));
    });

    test('ohne Zeiten in der Planung: keine Uhr (dann kein Tag/Nacht)', () {
      final p = _course([(1000, 0)]);
      const eta = EtaResult([EtaStep('', type: EtaEventType.drive, distanceKm: 1)], null);
      expect(TourClock.fromEta(eta, p), isNull);
    });

    test('Übergang weich, auch über den Zeitsprung einer Ruhezeit', () {
      final e = DaylightEaser();
      e.update(1, Duration.zero); // Nacht
      var last = 1.0, maxStep = 0.0;
      for (var i = 0; i < 300; i++) {
        final v = e.update(0, const Duration(milliseconds: 16)); // plötzlich Tag
        maxStep = math.max(maxStep, (v - last).abs());
        last = v;
      }
      expect(maxStep, lessThan(0.02)); // kein Umschalten
      expect(last, lessThan(0.05)); // nach ~5 s hell
    });
  });
}
