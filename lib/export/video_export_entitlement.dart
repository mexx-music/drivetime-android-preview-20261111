// DriveTime Studio – Berechtigung für Exportprofile.
//
// Vorbereitung für den späteren Verkauf des Full-HD-Films, OHNE eine Zahlung
// zu integrieren oder zu simulieren:
// - Das Kontrollvideo ist immer erlaubt (Grundlage: eines je Filmversion,
//   [TourFilmSpec.filmId]; die Begrenzung setzt später der Exportdienst durch).
// - Full HD ist standardmäßig gesperrt.
// - Entwicklung/interne Tests: ausdrücklich benannte lokale Freischaltung per
//   Build-Schalter `--dart-define=DRIVETIME_DEV_UNLOCK_FULLHD=true`, die
//   zusätzlich der Exportdienst selbst erlauben muss (`--dev-unlock-fullhd`).
//
// Wichtig: Die Prüfung in der App ist nur Anzeige. Maßgeblich ist der Dienst,
// der den Film rendert – nur er kann eine Freischaltung später sicher (nach
// bezahlter Bestellung zur [filmId]) durchsetzen. Eine Sperre allein im
// Browser wäre manipulierbar und gilt deshalb NICHT als Sicherheitslösung.

import 'video_export_preset.dart';

/// Lokale Entwickler-Freischaltung für Full HD (nie im öffentlichen Build).
const bool kDevUnlockFullHd = bool.fromEnvironment('DRIVETIME_DEV_UNLOCK_FULLHD');

/// Wer darf welches Exportprofil für welche Filmversion erzeugen?
abstract class VideoExportEntitlements {
  bool allows(VideoExportPreset preset, String filmId);

  /// Kurzer Grund für die Oberfläche, wenn [allows] false ist.
  String? lockedReason(VideoExportPreset preset) => null;
}

/// Standard: Kontrollvideo frei, Full HD gesperrt (außer lokale Dev-Freischaltung).
class DefaultVideoExportEntitlements implements VideoExportEntitlements {
  const DefaultVideoExportEntitlements({this.devUnlockFullHd = kDevUnlockFullHd});

  final bool devUnlockFullHd;

  @override
  bool allows(VideoExportPreset preset, String filmId) => switch (preset) {
        VideoExportPreset.controlPreview => true,
        VideoExportPreset.fullHD => devUnlockFullHd,
      };

  @override
  String? lockedReason(VideoExportPreset preset) =>
      preset == VideoExportPreset.fullHD && !devUnlockFullHd ? 'Full HD ist noch nicht freigeschaltet.' : null;
}

/// Beides muss zustimmen: App-Regel und Exportdienst (der maßgeblich ist).
class CombinedVideoExportEntitlements implements VideoExportEntitlements {
  const CombinedVideoExportEntitlements(this.app, this.service);

  final VideoExportEntitlements app;

  /// Antwort des Exportdienstes je Profil (fehlt = nicht erlaubt).
  final Map<VideoExportPreset, bool> service;

  @override
  bool allows(VideoExportPreset preset, String filmId) => app.allows(preset, filmId) && (service[preset] ?? false);

  @override
  String? lockedReason(VideoExportPreset preset) =>
      app.lockedReason(preset) ?? ((service[preset] ?? false) ? null : 'Der Exportdienst erlaubt dieses Profil nicht.');
}
