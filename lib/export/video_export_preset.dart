// DriveTime Studio – Exportprofile für den Tourfilm.
//
// Getrennt von der Live-Vorschau ([CinematicQuality.previewPerformance] /
// [CinematicQuality.previewHigh]): Beide Exportprofile rendern den Film mit
// [CinematicQuality.exportFullHD], im selben CSS-Bildausschnitt und mit
// derselben Filmzeitleiste (30 Bilder je Sekunde, `drivetimeExport.step()`).
// Unterschiedlich sind ausschließlich Pixeldichte, aufgenommene Bildrate,
// Kompression und das Vorschau-Wasserzeichen. Die Zahlen stehen identisch in
// `tool/studio_export/presets.json` (lokaler Exportdienst).

import '../ui/tour_animation_view.dart' show TourAnimationView;

/// Seitenverhältnis des Films.
enum FilmFormat {
  landscape16x9,
  portrait9x16;

  /// Bildausschnitt in CSS-Pixeln, in dem die App den Film rendert. Gleich
  /// für alle Exportprofile – sonst würden Kamera, Beschriftung und Layout
  /// abweichen.
  ({int width, int height}) get viewport => switch (this) {
        FilmFormat.landscape16x9 => (width: 960, height: 540),
        FilmFormat.portrait9x16 => (width: 540, height: 960),
      };

  String get label => switch (this) {
        FilmFormat.landscape16x9 => '16:9',
        FilmFormat.portrait9x16 => '9:16',
      };
}

/// Exportprofil (technische Qualität). Nicht mit der Live-Vorschau verwechseln.
enum VideoExportPreset {
  /// Kostenloses Kontrollvideo: kleiner, 10 fps, stark komprimiert, mit
  /// sichtbarem `DRIVETIME PREVIEW`.
  controlPreview,

  /// Bezahlter Full-HD-Film: 1080p, 30 fps, volle Qualität, kein Wasserzeichen.
  fullHD,
}

/// Technische Werte eines Exports.
class VideoExportProfile {
  const VideoExportProfile._({
    required this.preset,
    required this.format,
    required this.deviceScaleFactor,
    required this.fps,
    required this.crf,
    required this.x264Preset,
    required this.audioKbps,
    required this.watermark,
  });

  /// Bildtakt der Filmzeitleiste – für jedes Profil gleich.
  static const int timelineFps = TourAnimationView.exportFrameRate;

  static const String previewWatermark = 'DRIVETIME PREVIEW';

  factory VideoExportProfile.of(VideoExportPreset preset, FilmFormat format) => switch (preset) {
        VideoExportPreset.controlPreview => VideoExportProfile._(
            preset: preset,
            format: format,
            deviceScaleFactor: 2 / 3,
            fps: 10,
            crf: 34,
            x264Preset: 'veryfast',
            audioKbps: 64,
            watermark: previewWatermark,
          ),
        VideoExportPreset.fullHD => VideoExportProfile._(
            preset: preset,
            format: format,
            deviceScaleFactor: 2,
            fps: 30,
            crf: 16,
            x264Preset: 'slow',
            audioKbps: 256,
            watermark: null,
          ),
      };

  final VideoExportPreset preset;
  final FilmFormat format;

  /// Pixeldichte beim Aufnehmen: Ausgabegröße = CSS-Ausschnitt × Faktor.
  final double deviceScaleFactor;

  /// Bildrate der Ausgabedatei; jedes [captureEvery]-te Filmbild wird aufgenommen.
  final int fps;

  /// x264-Qualität (höher = stärker komprimiert).
  final int crf;
  final String x264Preset;

  /// AAC-Bitrate, falls der Film eine Tonspur hat (der App-Film hat derzeit keine).
  final int audioKbps;

  /// Sichtbares Wasserzeichen oder null.
  final String? watermark;

  int get width => (format.viewport.width * deviceScaleFactor).round();
  int get height => (format.viewport.height * deviceScaleFactor).round();

  /// Abstand der aufgenommenen Bilder in Filmbildern (30 fps / [fps]).
  int get captureEvery => timelineFps ~/ fps;

  /// Anzahl aufgenommener Bilder für einen Film mit [timelineFrames] Bildern.
  int capturedFrames(int timelineFrames) => (timelineFrames + captureEvery - 1) ~/ captureEvery;

  Map<String, Object?> toJson() => {
        'preset': preset.name,
        'format': format.name,
        'width': width,
        'height': height,
        'fps': fps,
        'crf': crf,
      };
}
