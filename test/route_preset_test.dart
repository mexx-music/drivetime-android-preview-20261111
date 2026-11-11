import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:driverroute_eta/models/route_preset.dart';
import 'package:driverroute_eta/services/route_preset_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const gr2at = RoutePreset(
    id: 'x1',
    name: 'GR → AT · östlich um Ex-Jugoslawien',
    stops: [
      'Kulata, Bulgarien',
      'Botevgrad, Bulgarien',
      'Calafat, Rumänien',
      'Nadlac, Rumänien',
    ],
  );

  test('Vorschau kürzt auf den Ortsnamen', () {
    expect(gr2at.preview, 'Kulata → Botevgrad → Calafat → Nadlac');
  });

  test('Umgekehrt dreht die Reihenfolge, nicht die Punkte', () {
    final back = gr2at.reversed;
    expect(back.stops.first, 'Nadlac, Rumänien');
    expect(back.stops.last, 'Kulata, Bulgarien');
    expect(back.stops.length, gr2at.stops.length);
    expect(back.reversed.stops, gr2at.stops);
  });

  test('speichert und liest verlustfrei', () {
    final raw = RoutePreset.encodeList([gr2at]);
    final back = RoutePreset.decodeList(raw);
    expect(back, hasLength(1));
    expect(back.first.name, gr2at.name);
    expect(back.first.stops, gr2at.stops);
  });

  test('kaputte Daten führen nicht zum Absturz', () {
    expect(RoutePreset.decodeList(null), isEmpty);
    expect(RoutePreset.decodeList('kein json'), isEmpty);
    expect(RoutePreset.decodeList('[{"id":"a"}]'), isEmpty);
    expect(RoutePreset.decodeList('[{"id":"a","name":"n","stops":[]}]'), isEmpty);
  });

  test('beim ersten Start ist die Starter-Vorlage da', () async {
    SharedPreferences.setMockInitialValues({});
    final first = await RoutePresetStore.load();
    expect(first, hasLength(1));
    expect(first.first.stops, contains('Botevgrad, Bulgarien'));
  });

  test('gelöschte Vorlagen kommen nicht zurück', () async {
    SharedPreferences.setMockInitialValues({});
    await RoutePresetStore.load(); // sät die Starter-Vorlage
    await RoutePresetStore.save(const []);
    expect(await RoutePresetStore.load(), isEmpty);
  });

  test('eigene Vorlagen überleben einen Neustart', () async {
    SharedPreferences.setMockInitialValues({});
    await RoutePresetStore.load();
    await RoutePresetStore.save([gr2at]);
    final again = await RoutePresetStore.load();
    expect(again, hasLength(1));
    expect(again.first.id, 'x1');
  });
}
