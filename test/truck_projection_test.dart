import 'package:driverroute_eta/animation/truck_projection.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const pitch = 42.0; // wie die Karte (TourCameraRig)

  Set<FaceSide> visibleTrailerSides(double yaw) => {
        for (final f in TruckProjection(pitchDeg: pitch, yawDeg: yaw).visibleFaces(standardTruck))
          if (f.box.name == 'trailer') f.side,
      };

  group('Sichtbare Flächen', () {
    test('fährt vom Betrachter weg: Heck und Dach, keine Seite', () {
      expect(visibleTrailerSides(0), {FaceSide.back, FaceSide.top});
    });

    test('nach rechts gedreht: rechte Seite sichtbar; nach links: linke', () {
      expect(visibleTrailerSides(25), containsAll([FaceSide.right, FaceSide.top, FaceSide.back]));
      expect(visibleTrailerSides(25), isNot(contains(FaceSide.left)));
      expect(visibleTrailerSides(-25), containsAll([FaceSide.left, FaceSide.top]));
      expect(visibleTrailerSides(-25), isNot(contains(FaceSide.right)));
      expect(biasFor(TruckSide.right, 22), 22);
      expect(biasFor(TruckSide.left, 22), -22);
    });

    test('Boden ist nie sichtbar (Fahrzeug steht, schwebt nicht)', () {
      for (var y = -180; y < 180; y += 5) {
        expect(visibleTrailerSides(y.toDouble()), isNot(contains(FaceSide.bottom)));
      }
    });
  });

  group('Schriftzug', () {
    test('auf jeder sichtbaren Seitenfläche lesbar, nie gespiegelt', () {
      for (var y = -179; y < 180; y += 3) {
        final faces = TruckProjection(pitchDeg: pitch, yawDeg: y.toDouble()).visibleFaces(standardTruck);
        for (final f in faces) {
          if (f.side != FaceSide.left && f.side != FaceSide.right) continue;
          expect(TruckProjection.orientation(f.corners), greaterThan(0),
              reason: 'Gier $y°, ${f.side}');
        }
      }
    });

    test('bei 3/4-Ansicht ist die Seitenfläche ausreichend breit', () {
      final faces = TruckProjection(pitchDeg: pitch, yawDeg: 25).visibleFaces(standardTruck);
      final side = faces.firstWhere((f) => f.box.name == 'trailer' && f.side == FaceSide.right);
      final width = (side.corners[1].x - side.corners[0].x).abs();
      expect(width, greaterThan(13.6 * 0.4)); // > 40 % der Aufliegerlänge
    });
  });

  group('Seitenwahl mit Hysterese', () {
    test('wechselt erst bei deutlichem Winkel', () {
      var side = TruckSide.left;
      for (final rel in [3.0, -3.0, 7.0, -7.9, 0.0]) {
        side = chooseSide(rel, side);
        expect(side, TruckSide.left, reason: '$rel°');
      }
      side = chooseSide(8.5, side); // deutlich nach rechts gedreht
      expect(side, TruckSide.right);
      side = chooseSide(-5, side); // zurück ins Band: bleibt rechts
      expect(side, TruckSide.right);
    });

    test('kein Hin- und Herschalten bei Pendeln im Band', () {
      var side = TruckSide.right;
      var switches = 0;
      for (var i = 0; i < 500; i++) {
        final rel = 6.0 * (i.isEven ? 1 : -1); // ±6° Pendeln
        final next = chooseSide(rel, side);
        if (next != side) switches++;
        side = next;
      }
      expect(switches, 0);
    });

    test('Seitenwinkel ändert sich weich, ohne Sprung', () {
      var bias = 22.0;
      var maxStep = 0.0;
      for (var i = 0; i < 120; i++) {
        final next = easeBias(bias, -22, const Duration(milliseconds: 16));
        maxStep = (next - bias).abs() > maxStep ? (next - bias).abs() : maxStep;
        bias = next;
      }
      expect(maxStep, lessThan(1.0)); // < 1° pro Bild
      expect(bias, lessThan(-15)); // nach ~2 s fast drüben
    });

    test('Mindesthaltezeit: nach einem Wechsel bleibt die Seite stehen', () {
      final c = SideChooser(threshold: 15, minHold: const Duration(seconds: 8), side: TruckSide.left);
      const dt = Duration(milliseconds: 100);
      expect(c.update(20, dt), TruckSide.right); // erster Wechsel sofort
      for (var i = 0; i < 70; i++) {
        expect(c.update(-30, dt), TruckSide.right, reason: 'nach ${i * 100} ms'); // < 8 s
      }
      for (var i = 0; i < 20; i++) {
        c.update(-30, dt);
      }
      expect(c.side, TruckSide.left); // nach 8 s darf gewechselt werden
      expect(c.switches, 2);
    });

    test('Bildwahl: Hysterese gegen Flackern an der Grenze', () {
      var frame = 0;
      for (final yaw in [1.9, 2.1, 1.95, 2.05, 2.2]) {
        frame = frameFor(yaw, frame);
      }
      expect(frame, 0); // knapp über der Grenze bleibt das Bild
      frame = frameFor(4.5, frame);
      expect(frame, 1);
      expect(frameFor(-179, 0), -45); // Umlauf über ±180°
    });
  });
}
