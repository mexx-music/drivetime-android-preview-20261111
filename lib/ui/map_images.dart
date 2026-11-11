// Fahrzeugbilder wieder aus der Karte nehmen: Das Kartenplugin kennt nur
// addImage, MapLibre selbst aber removeImage. Ohne Entfernen wachsen die
// Bilder einer Tour unbegrenzt (gemessen 157 MB nach 50 s) – Safari auf
// dem iPad beendet die Seite dann. Auf anderen Plattformen ohne Wirkung.
export 'map_images_stub.dart' if (dart.library.js_interop) 'map_images_web.dart';
