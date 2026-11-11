import 'dart:typed_data';

/// Ohne Web: nichts zu tun.
void trackMapImages() {}

/// Ohne Web: nichts zu tun.
void removeMapImage(String name) {}

/// Ohne Web: nicht möglich – der Aufrufer nimmt den PNG-Weg des Plugins.
bool addRawMapImage(String name, int width, int height, Uint8List rgba, {required String sameMapAs}) => false;

/// Ohne Web: nichts zu tun.
void capMapPixelRatio(double max, {required String sameMapAs}) {}

/// Ohne Web: nichts gezeichnet.
String? renderedIcon(String layer, {required String sameMapAs}) => null;

/// Ohne Web: als sichtbar annehmen.
bool isOnScreen(double lat, double lng, {required String sameMapAs}) => true;

/// Ohne Web: keine Kennzahlen.
Map<String, num> mapRuntimeStats({required String sameMapAs}) => const {};

/// Ohne Web: kein Overlay.
bool vehicleOverlayAttach({required String sameMapAs}) => false;
void vehicleOverlayDetach() {}
void vehicleOverlaySet({
  ({String img, double lat, double lng, double size, double rot, double op})? truck,
  ({String img, double lat, double lng, double heading, double size, double op})? cone,
}) {}
