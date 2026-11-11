import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart' show StringCharacters;
import 'package:shared_preferences/shared_preferences.dart';

/// Höchstlänge des persönlichen Tourtitels in sichtbaren Zeichen
/// (Graphem-Clustern: „ä“, „ğ“ oder ein Emoji zählen je einmal).
const int kPersonalTitleMaxLength = 40;

/// Steuer- und Formatzeichen, die im Titel nichts verloren haben:
/// C0/C1-Steuerzeichen (inkl. Zeilenumbrüche, Tab), Zeilen-/Absatztrenner
/// und Bidi-Steuerzeichen (könnten die Anzeige umdrehen).
final RegExp _control = RegExp(r'[\x00-\x1F\x7F-\x9F\u2028\u2029\u202A-\u202E\u2066-\u2069\uFEFF]');

/// Bereinigt einen persönlichen Tourtitel: einzeilig, ohne Steuerzeichen,
/// Leerraum zusammengefasst, getrimmt, höchstens [kPersonalTitleMaxLength]
/// sichtbare Zeichen. Leer → null („kein Titel“). Reiner Text – nichts wird
/// als HTML oder Formatierung ausgewertet.
String? sanitizePersonalTitle(String? input) {
  if (input == null) return null;
  var s = input.replaceAll(_control, ' ').replaceAll(RegExp(r'\s+'), ' ').trim();
  if (s.isEmpty) return null;
  final chars = s.characters;
  if (chars.length > kPersonalTitleMaxLength) s = chars.take(kPersonalTitleMaxLength).toString().trimRight();
  return s.isEmpty ? null : s;
}

/// Merkt sich den persönlichen Tourtitel nur auf diesem Gerät.
class PersonalTitleStore {
  static const key = 'personal_tour_title_v1';

  static Future<String?> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return sanitizePersonalTitle(prefs.getString(key));
    } catch (e) {
      if (kDebugMode) debugPrint('[PersonalTitleStore] laden fehlgeschlagen: $e');
      return null;
    }
  }

  /// Speichert den bereinigten Titel; leer entfernt ihn.
  static Future<void> save(String? title) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final clean = sanitizePersonalTitle(title);
      if (clean == null) {
        await prefs.remove(key);
      } else {
        await prefs.setString(key, clean);
      }
    } catch (e) {
      if (kDebugMode) debugPrint('[PersonalTitleStore] speichern fehlgeschlagen: $e');
    }
  }
}
