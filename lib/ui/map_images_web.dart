import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'dart:typed_data';

/// Merkt sich jede MapLibre-Karte, sobald sie ein Bild bekommt (über
/// `maplibregl.Map.prototype.addImage`). Einmal je Seite; vor dem ersten
/// eigenen addImage aufrufen.
void trackMapImages() {
  final lib = globalContext['maplibregl'];
  if (lib == null) return;
  // Map ist eine Klasse, also eine JS-Funktion (kein reines Objekt).
  final mapClass = (lib as JSObject)['Map'];
  if (mapClass == null) return;
  final proto = (mapClass as JSObject)['prototype'];
  if (proto == null) return;
  _patch(proto as JSObject);
}

void _patch(JSObject proto) {
  if (proto['__dtTracked'] != null) return;
  final original = proto['addImage'] as JSFunction;
  proto['addImage'] = ((JSObject self, JSAny? id, JSAny? image, JSAny? options) {
    _maps.add(self);
    return original.callAsFunction(self, id, image, options);
  }).toJSCaptureThis;
  proto['__dtTracked'] = true.toJS;
}

final Set<JSObject> _maps = {};

/// Bild [name] aus allen bekannten Karten entfernen, wo vorhanden.
void removeMapImage(String name) {
  final id = name.toJS;
  // Entsorgte Karten (Container nicht mehr im Dokument) vergessen.
  _maps.removeWhere((m) {
    try {
      final c = m.callMethod<JSObject>('getContainer'.toJS);
      return !(c['isConnected'] as JSBoolean).toDart;
    } catch (_) {
      return true;
    }
  });
  for (final m in _maps) {
    try {
      if ((m.callMethod<JSBoolean>('hasImage'.toJS, id)).toDart) {
        m.callMethod<JSAny?>('removeImage'.toJS, id);
      }
    } catch (_) {
      // Karte schon entsorgt – ignorieren.
    }
  }
}

/// Die Karte, die schon das Bild [probe] hat (die eigene Tourkarte).
JSObject? _mapWith(String probe) {
  final id = probe.toJS;
  for (final m in _maps.toList().reversed) {
    try {
      final c = m.callMethod<JSObject>('getContainer'.toJS);
      if (!(c['isConnected'] as JSBoolean).toDart) continue;
      if ((m.callMethod<JSBoolean>('hasImage'.toJS, id)).toDart) return m;
    } catch (_) {}
  }
  return null;
}

/// Rohe RGBA-Pixel direkt an MapLibre geben – ohne das PNG-Dekodieren des
/// Plugins (reines Dart, Pixel für Pixel). Liefert false, wenn die Karte
/// nicht gefunden wird; dann nimmt der Aufrufer den bisherigen Weg.
bool addRawMapImage(String name, int width, int height, Uint8List rgba, {required String sameMapAs}) {
  final m = _mapWith(sameMapAs);
  if (m == null) return false;
  try {
    if ((m.callMethod<JSBoolean>('hasImage'.toJS, name.toJS)).toDart) return true;
    final image = JSObject()
      ..['width'] = width.toJS
      ..['height'] = height.toJS
      ..['data'] = rgba.toJS;
    final options = JSObject()..['pixelRatio'] = 1.toJS;
    m.callMethod<JSAny?>('addImage'.toJS, name.toJS, image, options);
    return true;
  } catch (_) {
    return false;
  }
}

/// Pixeldichte der Kartenfläche höchstens [max] (z. B. 1,5 statt 2 auf dem
/// iPad: 44 % weniger Bildpunkte zu zeichnen). Die Flutter-Ebenen (HUD,
/// Texte) bleiben in voller Schärfe.
void capMapPixelRatio(double max, {required String sameMapAs}) {
  final m = _mapWith(sameMapAs);
  if (m == null) return;
  try {
    final current = (m.callMethod<JSNumber>('getPixelRatio'.toJS)).toDartDouble;
    if (current > max) m.callMethod<JSAny?>('setPixelRatio'.toJS, max.toJS);
  } catch (_) {}
}

/// Icon des ersten gezeichneten Symbols der Ebene [layer] (Videoexport:
/// Nachweis, dass das gewünschte Fahrzeugbild wirklich gezeichnet ist).
String? renderedIcon(String layer, {required String sameMapAs}) {
  final m = _mapWith(sameMapAs);
  if (m == null) return null;
  try {
    final options = JSObject()..['layers'] = [layer.toJS].toJS;
    final list = m.callMethod<JSArray<JSObject>>('queryRenderedFeatures'.toJS, options).toDart;
    if (list.isEmpty) return null;
    final props = list.first['properties'] as JSObject?;
    final icon = props?['icon'];
    return icon == null ? null : (icon as JSString).toDart;
  } catch (_) {
    return null;
  }
}

/// Liegt der Kartenpunkt im sichtbaren Bereich der Karte? (Videoexport:
/// ein Fahrzeug außerhalb des Bildes kann nicht gezeichnet sein.)
bool isOnScreen(double lat, double lng, {required String sameMapAs}) {
  final m = _mapWith(sameMapAs);
  if (m == null) return true;
  try {
    final p = m.callMethod<JSObject>('project'.toJS, [lng.toJS, lat.toJS].toJS);
    final x = (p['x'] as JSNumber).toDartDouble, y = (p['y'] as JSNumber).toDartDouble;
    final c = m.callMethod<JSObject>('getContainer'.toJS);
    final w = (c['clientWidth'] as JSNumber).toDartDouble, h = (c['clientHeight'] as JSNumber).toDartDouble;
    return x >= 0 && y >= 0 && x <= w && y <= h;
  } catch (_) {
    return true;
  }
}

/// Technische Kennzahlen der Tourkarte für den Diagnosepuffer: Bilder,
/// Kacheln (sichtbar/zwischengespeichert), Zeichenfläche, Pixeldichte und –
/// wo der Browser es meldet – JS-Speicher. Nichts davon enthält Orte.
Map<String, num> mapRuntimeStats({required String sameMapAs}) {
  final out = <String, num>{};
  final m = _mapWith(sameMapAs);
  try {
    final perf = globalContext['performance'] as JSObject?;
    final mem = perf?['memory'] as JSObject?;
    final used = mem?['usedJSHeapSize'];
    if (used != null) out['jsHeapMB'] = ((used as JSNumber).toDartDouble / 1e6).round();
  } catch (_) {}
  if (m == null) return out;
  try {
    out['images'] = m.callMethod<JSArray<JSAny?>>('listImages'.toJS).length;
    final canvas = m.callMethod<JSObject>('getCanvas'.toJS);
    out['canvasW'] = (canvas['width'] as JSNumber).toDartInt;
    out['canvasH'] = (canvas['height'] as JSNumber).toDartInt;
    out['pixelRatio'] = (m.callMethod<JSNumber>('getPixelRatio'.toJS)).toDartDouble;
    // Hinkt die Karte hinterher? 1 = Szene vollständig geladen/gezeichnet.
    out['mapLoaded'] = (m.callMethod<JSBoolean>('loaded'.toJS)).toDart ? 1 : 0;
    out['tilesLoaded'] = (m.callMethod<JSBoolean>('areTilesLoaded'.toJS)).toDart ? 1 : 0;
    final style = m['style'] as JSObject;
    final managers = style['tileManagers'] as JSObject?;
    if (managers != null) {
      var inView = 0, cached = 0;
      final keys = (globalContext['Object'] as JSObject).callMethod<JSArray<JSString>>('keys'.toJS, managers).toDart;
      int count(JSAny? v) {
        if (v == null) return 0;
        final o = v as JSObject;
        if (o['size'] != null) return (o['size'] as JSNumber).toDartInt;
        if (o['order'] != null) return (o['order'] as JSArray<JSAny?>).length;
        return (globalContext['Object'] as JSObject).callMethod<JSArray<JSAny?>>('keys'.toJS, o).length;
      }
      for (final k in keys) {
        final mgr = managers[k.toDart] as JSObject;
        // Sichtbare Kacheln über MapLibres eigene Abfrage (gezeichnete IDs).
        if (mgr['getRenderableIds'] != null) {
          inView += mgr.callMethod<JSArray<JSAny?>>('getRenderableIds'.toJS).length;
        } else if (mgr['getIds'] != null) {
          inView += mgr.callMethod<JSArray<JSAny?>>('getIds'.toJS).length;
        }
        cached += count(mgr['_outOfViewCache']);
      }
      out['tilesInView'] = inView;
      out['tilesCached'] = cached;
    }
  } catch (_) {}
  return out;
}

// ------------------------------------------------ Fahrzeug-Overlay

JSObject? get _overlay {
  final o = globalContext['dtVehicleOverlay'];
  return o == null ? null : o as JSObject;
}

/// Fahrzeug-Overlay (web/vehicle_overlay.js) an die Tourkarte hängen.
bool vehicleOverlayAttach({required String sameMapAs}) {
  final o = _overlay, m = _mapWith(sameMapAs);
  if (o == null || m == null) return false;
  try {
    return (o.callMethod<JSBoolean>('attach'.toJS, m)).toDart;
  } catch (_) {
    return false;
  }
}

void vehicleOverlayDetach() {
  try {
    _overlay?.callMethod<JSAny?>('detach'.toJS);
  } catch (_) {}
}

/// Zustand für das nächste Kartenbild: Lkw (Bildname, Ort, Größe, Drehung,
/// Deckkraft) und Licht (Ort, Kurs, Größe, Deckkraft); null = nicht zeigen.
void vehicleOverlaySet({
  ({String img, double lat, double lng, double size, double rot, double op})? truck,
  ({String img, double lat, double lng, double heading, double size, double op})? cone,
}) {
  final o = _overlay;
  if (o == null) return;
  final st = JSObject();
  if (truck != null) {
    st['truck'] = JSObject()
      ..['img'] = truck.img.toJS
      ..['lat'] = truck.lat.toJS
      ..['lng'] = truck.lng.toJS
      ..['size'] = truck.size.toJS
      ..['rot'] = truck.rot.toJS
      ..['op'] = truck.op.toJS;
  }
  if (cone != null) {
    st['cone'] = JSObject()
      ..['img'] = cone.img.toJS
      ..['lat'] = cone.lat.toJS
      ..['lng'] = cone.lng.toJS
      ..['heading'] = cone.heading.toJS
      ..['size'] = cone.size.toJS
      ..['op'] = cone.op.toJS;
  }
  try {
    o.callMethod<JSAny?>('set'.toJS, st);
  } catch (_) {}
}
