import 'dart:convert';

import 'package:driverroute_eta/models/tour_draft.dart';
import 'package:driverroute_eta/services/cinematic_session.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

TourDraft _draft() => TourDraft(
      start: 'Tuzla/Istanbul, Türkei',
      dest: 'Odense, Dänemark',
      startLat: 40.82,
      startLng: 29.30,
      destLat: 55.40,
      destLng: 10.40,
      stops: const ['Sofia, Bulgarien', 'Timișoara, Rumänien'],
      stopCoords: const [
        [42.70, 23.32],
        null,
      ],
      settings: const {'remainingDrivingMin': 540, 'ten1': false, 'speedProfile': 'mixedRoads70'},
      savedAt: DateTime.utc(2026, 10, 4, 8),
    );

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('TourDraft', () {
    test('hin und zurück verlustfrei', () {
      final d = TourDraft.decode(_draft().encode())!;
      expect(d.start, 'Tuzla/Istanbul, Türkei');
      expect(d.dest, 'Odense, Dänemark');
      expect((d.startLat, d.startLng, d.destLat, d.destLng), (40.82, 29.30, 55.40, 10.40));
      expect(d.stops, ['Sofia, Bulgarien', 'Timișoara, Rumänien']);
      expect(d.stopCoords, [
        [42.70, 23.32],
        null,
      ]);
      expect(d.settings['remainingDrivingMin'], 540);
      expect(d.settings['ten1'], false);
      expect(d.savedAt, DateTime.utc(2026, 10, 4, 8));
      expect(d.usable, isTrue);
    });

    test('kaputte oder fremde Daten: null statt Absturz', () {
      expect(TourDraft.decode(null), isNull);
      expect(TourDraft.decode('{kaputt'), isNull);
      expect(TourDraft.decode(jsonEncode({'v': 99, 'start': 'a', 'dest': 'b'})), isNull);
    });
  });

  group('CinematicSession', () {
    test('Tour wird gesichert und wieder geladen', () async {
      await CinematicSession.saveDraft(_draft());
      expect((await CinematicSession.loadDraft())!.dest, 'Odense, Dänemark');
    });

    test('normales Ende: kein Abbruch gemeldet', () async {
      await CinematicSession.begin({'km': 3175});
      await CinematicSession.sample({'progress': 0.1});
      await CinematicSession.end();
      expect(await CinematicSession.takeInterrupted(), isNull);
    });

    test('Abbruch: Bericht mit den letzten 30 Messpunkten, danach erledigt', () async {
      await CinematicSession.begin({'km': 3175, 'legs': 11});
      for (var i = 0; i < 40; i++) {
        await CinematicSession.sample({'progress': i / 40, 'zoom': 8.2});
      }
      // Seite stirbt: kein end(). Neuer Start liest den Bericht.
      final report = (await CinematicSession.takeInterrupted())!;
      expect((report['session'] as Map)['km'], 3175);
      final samples = report['samples'] as List;
      expect(samples, hasLength(CinematicSession.maxSamples));
      expect((samples.first as Map)['progress'], 10 / 40); // die ältesten fielen heraus
      expect((samples.last as Map)['progress'], 39 / 40);
      expect(await CinematicSession.lastReport(), isNotNull);
      expect(await CinematicSession.takeInterrupted(), isNull); // nur einmal angeboten
    });

    test('Diagnose enthält keine Tour-Adressen', () async {
      await CinematicSession.saveDraft(_draft());
      await CinematicSession.begin({'km': 3175});
      await CinematicSession.sample({'progress': 0.5, 'shot': 'WIDE', 'zoom': 7.4});
      final text = jsonEncode(await CinematicSession.takeInterrupted());
      for (final word in ['Tuzla', 'Odense', 'Sofia', 'Timișoara']) {
        expect(text.contains(word), isFalse, reason: word);
      }
    });
  });
}
