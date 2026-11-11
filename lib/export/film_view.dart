// DriveTime Studio – die eine Filmregie.
//
// „Tour animieren“ in der App, das kostenlose Kontrollvideo und der Full-HD-
// Export entstehen alle hier aus derselben [TourFilmSpec]. Es gibt keine
// zweite Regie für die Kontrollversion: Exportprofile unterscheiden sich nur
// beim Aufnehmen (Pixeldichte, Bildrate, Kompression, Wasserzeichen).

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/widgets.dart';

import '../animation/cinematic_camera.dart' show CameraMode;
import '../animation/country_borders.dart';
import '../animation/daylight.dart' show DayNightMode;
import '../animation/tour_path.dart';
import '../ui/tour_animation_view.dart';
import '../ui/truck_sprites.dart' show TruckBranding, TruckModel, TruckView;
import 'film_spec.dart';

/// Lackierung zur Kennung aus der Filmspezifikation. Unbekannt → Blau.
TruckBranding truckBrandingById(String id) => switch (id) {
      'gartner-test' => TruckBranding.gartnerTest,
      'neutral-green' => TruckBranding.neutralGreen,
      _ => TruckBranding.neutral,
    };

/// Streckenpfad des Films oder null, wenn die Berechnung keine
/// Streckenführung enthält (dann gibt es nichts zu animieren).
TourPath? filmPathFor(TourFilmSpec spec) => TourPath.fromMapPlan(spec.plan);

/// Der Tourfilm zu [spec]. [videoExport] schaltet den Aufnahmemodus ein:
/// ohne Bedienelemente, Bild für Bild über `window.drivetimeExport`,
/// immer [CinematicQuality.exportFullHD].
Widget filmViewFor(
  TourFilmSpec spec, {
  required TourPath path,
  required bool videoExport,
  String? heroPhoto,
  String? heroCutout,
  bool cleanRecording = false,
  VoidCallback? onPlaybackStarted,
  VoidCallback? onPlaybackFinished,
  ValueListenable<bool>? closeRequest,
}) =>
    TourAnimationView(
      path: path,
      title: spec.title,
      stops: spec.plan.stops,
      // Story nur aus vorhandenen Daten: Planung der Berechnung und die
      // mitgelieferten Ländergrenzen – kein Aufruf bei Google.
      eta: spec.eta,
      countries: CountryIndex.load(),
      fromName: spec.fromName,
      toName: spec.toName,
      // 2.5D-Cinematic (MapLibre): gekoppelter Sattelzug, Kamera-Regie,
      // Tag/Nacht aus der Planzeit, Fähre. Reine Darstellung der fertigen
      // Berechnung. 2D bleibt per Umschalter – und automatisch, wenn die
      // Vektorkarte nicht lädt – als Rückfall.
      startIn25D: true,
      cameraMode: CameraMode.cinematic,
      truckView: TruckView.articulated,
      truckModel: TruckModel(branding: truckBrandingById(spec.truckBranding)),
      dayNight: DayNightMode.plan,
      videoExport: videoExport,
      heroPhoto: videoExport ? heroPhoto : null,
      heroCutout: videoExport ? heroCutout : null,
      // Live-Aufnahme im Browser: dieselbe Regie, nur ohne Bedienelemente.
      cleanRecording: cleanRecording,
      onPlaybackStarted: onPlaybackStarted,
      onPlaybackFinished: onPlaybackFinished,
      closeRequest: closeRequest,
      // Persönlicher Titel aus der Filmspezifikation – überall derselbe.
      personalTitle: spec.personalTitle,
    );
