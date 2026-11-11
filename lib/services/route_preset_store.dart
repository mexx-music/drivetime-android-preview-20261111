import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/route_preset.dart';

/// Speichert Routen-Vorlagen auf dem Gerät.
class RoutePresetStore {
  static const _key = 'route_presets_v1';
  static const _seededKey = 'route_presets_seeded_v1';
  static const int maxPresets = 30;

  /// Beim ersten Start mitgelieferte Vorlage. Sie ist ganz normal
  /// bearbeit- und löschbar – nichts daran ist fest verdrahtet.
  static const List<RoutePreset> starterPresets = [
    RoutePreset(
      id: 'starter-gr-at-ost',
      name: 'GR → AT · östlich um Ex-Jugoslawien',
      stops: [
        'Kulata, Bulgarien',
        'Botevgrad, Bulgarien',
        'Calafat, Rumänien',
        'Nadlac, Rumänien',
      ],
    ),
  ];

  static Future<List<RoutePreset>> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (!(prefs.getBool(_seededKey) ?? false)) {
        await prefs.setBool(_seededKey, true);
        if (prefs.getString(_key) == null) {
          await prefs.setString(_key, RoutePreset.encodeList(starterPresets));
          return List.of(starterPresets);
        }
      }
      return RoutePreset.decodeList(prefs.getString(_key));
    } catch (e) {
      if (kDebugMode) debugPrint('[RoutePresetStore] laden fehlgeschlagen: $e');
      return const [];
    }
  }

  static Future<void> save(List<RoutePreset> presets) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_key, RoutePreset.encodeList(presets));
    } catch (e) {
      if (kDebugMode) debugPrint('[RoutePresetStore] speichern fehlgeschlagen: $e');
    }
  }
}
