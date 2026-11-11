import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/tour_draft.dart';

/// Absicherung der 2.5D-Tour gegen unerwartetes Neuladen.
///
/// - [saveDraft]: die Eingaben der zuletzt erfolgreich berechneten Tour.
/// - [begin]/[end]: Markierung „2.5D-Tour läuft“. Bleibt sie nach einem
///   Neuladen stehen, endete die Sitzung nicht normal (Safari hat die Seite
///   beendet, Absturz, Neuladen von Hand).
/// - [sample]: kleiner Diagnose-Ringpuffer – nur technische Werte der
///   letzten [maxSamples] Messungen (alle 2 s ≈ 60 s), keine Adressen.
///
/// Alles im lokalen Speicher dieses Geräts; nichts wird versendet.
class CinematicSession {
  static const draftKey = 'tour_draft_v1';
  static const sessionKey = 'cinematic_session_v1';
  static const samplesKey = 'cinematic_diag_v1';
  static const lastReportKey = 'cinematic_last_interrupted_v1';
  static const int maxSamples = 30;

  static final List<Map<String, Object?>> _samples = [];
  static bool _active = false;

  static Future<void> saveDraft(TourDraft draft) async {
    try {
      final p = await SharedPreferences.getInstance();
      await p.setString(draftKey, draft.encode());
    } catch (_) {}
  }

  static Future<TourDraft?> loadDraft() async {
    try {
      final p = await SharedPreferences.getInstance();
      return TourDraft.decode(p.getString(draftKey));
    } catch (_) {
      return null;
    }
  }

  /// 2.5D-Tour beginnt. [info]: technische Eckdaten (km, Etappen, Profil).
  static Future<void> begin(Map<String, Object?> info) async {
    _samples.clear();
    _active = true;
    try {
      final p = await SharedPreferences.getInstance();
      await p.setString(sessionKey, jsonEncode({...info, 'startedAt': DateTime.now().toIso8601String()}));
      await p.remove(samplesKey);
    } catch (_) {}
  }

  /// Ein Messpunkt; die ältesten fallen heraus. Schreibt den Puffer sofort,
  /// damit er einen Absturz übersteht.
  static Future<void> sample(Map<String, Object?> values) async {
    if (!_active) return;
    _samples.add({'at': DateTime.now().toIso8601String(), ...values});
    while (_samples.length > maxSamples) {
      _samples.removeAt(0);
    }
    try {
      final p = await SharedPreferences.getInstance();
      await p.setString(samplesKey, jsonEncode(_samples));
    } catch (_) {}
  }

  /// Normales Ende (Ansicht geschlossen): Markierung und Puffer entfernen.
  static Future<void> end() async {
    _active = false;
    _samples.clear();
    try {
      final p = await SharedPreferences.getInstance();
      await p.remove(sessionKey);
      await p.remove(samplesKey);
    } catch (_) {}
  }

  /// Beim App-Start: endete die letzte 2.5D-Sitzung nicht normal? Dann den
  /// Bericht (Sitzung + letzte Messpunkte) liefern und als „letzter
  /// Abbruch“ aufheben; die Markierung wird entfernt.
  static Future<Map<String, Object?>?> takeInterrupted() async {
    try {
      final p = await SharedPreferences.getInstance();
      final session = p.getString(sessionKey);
      if (session == null) return null;
      final samples = p.getString(samplesKey);
      final report = <String, Object?>{
        'session': jsonDecode(session),
        'samples': samples == null ? const [] : jsonDecode(samples),
        'detectedAt': DateTime.now().toIso8601String(),
      };
      await p.setString(lastReportKey, jsonEncode(report));
      await p.remove(sessionKey);
      await p.remove(samplesKey);
      return report;
    } catch (_) {
      return null;
    }
  }

  /// Letzter gespeicherter Abbruchbericht (Diagnose), sonst null.
  static Future<String?> lastReport() async {
    try {
      final p = await SharedPreferences.getInstance();
      return p.getString(lastReportKey);
    } catch (_) {
      return null;
    }
  }
}
