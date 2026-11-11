import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../ui/truck_sprites.dart' show TruckBranding;

/// Wählbare Truckfarbe für Touranimation, Live-Aufnahme und Studio-Export.
/// Nur die Kabine ändert sich; der Auflieger bleibt weiß und ohne Schrift.
enum TruckColor {
  blue(TruckBranding.neutral, 'Blau'),
  green(TruckBranding.neutralGreen, 'Grün');

  const TruckColor(this.branding, this.label);
  final TruckBranding branding;
  final String label;

  /// Gespeicherter Wert → Farbe; unbekannt oder fehlend → Blau.
  static TruckColor parse(String? name) =>
      TruckColor.values.firstWhere((c) => c.name == name, orElse: () => TruckColor.blue);
}

/// Branding-Kennung für die Filmspezifikation. Der Film-Build behält
/// unverändert die GARTNER-Testlackierung; die Auswahl wirkt dort nicht.
String filmTruckBrandingId({required bool filmBuild, required TruckColor color}) =>
    filmBuild ? TruckBranding.gartnerTest.id : color.branding.id;

/// Merkt sich die gewählte Truckfarbe auf dem Gerät.
class TruckColorStore {
  static const key = 'truck_color_v1';

  static Future<TruckColor> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return TruckColor.parse(prefs.getString(key));
    } catch (e) {
      if (kDebugMode) debugPrint('[TruckColorStore] laden fehlgeschlagen: $e');
      return TruckColor.blue;
    }
  }

  static Future<void> save(TruckColor color) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(key, color.name);
    } catch (e) {
      if (kDebugMode) debugPrint('[TruckColorStore] speichern fehlgeschlagen: $e');
    }
  }
}
