import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:maplibre_gl/maplibre_gl.dart' as ml;

import '../animation/country_borders.dart';
import 'tour_animation_scene_maplibre.dart' show TourAnimationSceneMapLibre;

/// Vektorkarte (MapLibre) mit lateinischer Beschriftung verwenden. In
/// Widget-Tests nicht darstellbar – dort auf false; dann OSM-Rasterkarte.
@visibleForTesting
bool debugMapPickerUseMapLibre = true;

/// Ergebnis der Kartenauswahl: die Koordinate (maßgeblich) und – falls die
/// lokalen Grenzdaten es wissen – das Land.
class PickedMapPoint {
  const PickedMapPoint(this.point, {this.country});

  final LatLng point;
  final String? country;
}

/// „Auf Karte wählen“: Zwischenpunkt durch Tippen setzen.
///
/// Tippen setzt den Marker, erneutes Tippen versetzt ihn. Es gibt keine
/// Geocoding- oder Places-Anfrage – nur die OSM-Kacheln der Karte. Das Land
/// kommt aus den mitgelieferten Grenzdaten.
class MapPointPicker extends StatefulWidget {
  const MapPointPicker({
    super.key,
    this.initialCenter = const LatLng(48.5, 12.0),
    this.initialZoom = 5,
    this.start,
    this.dest,
    this.stops = const [],
    this.countries,
    this.showTiles = true,
    this.request = 0,
    this.onDone,
  });

  final LatLng initialCenter;
  final double initialZoom;

  /// Zur Orientierung: bereits bekannte Punkte der Tour.
  final LatLng? start;
  final LatLng? dest;
  final List<LatLng> stops;

  /// Lokale Grenzdaten für den Ländernamen; ohne sie bleibt er leer.
  final Future<CountryIndex>? countries;

  /// Nur für Tests abschaltbar.
  final bool showTiles;

  /// Wiederverwendeter Picker ([MapPickerHost]): Nummer der aktuellen
  /// Anfrage – ändert sie sich, beginnt die Auswahl neu (Punkt leer, Kamera
  /// und Tourpunkte der neuen Anfrage), die Karte bleibt dieselbe.
  final int request;

  /// Ergebnis an den Aufrufer statt über den Navigator (null = abgebrochen).
  final void Function(PickedMapPoint? result)? onDone;

  @override
  State<MapPointPicker> createState() => _MapPointPickerState();
}

class _MapPointPickerState extends State<MapPointPicker> {
  final MapController _map = MapController();

  /// Vektorkarte; fällt auf die OSM-Karte zurück, wenn der Stil nicht lädt.
  late bool _useMapLibre = debugMapPickerUseMapLibre;
  late final Future<String>? _style =
      _useMapLibre ? TourAnimationSceneMapLibre.loadStyle() : null;
  ml.MapLibreMapController? _ml;
  bool _mlReady = false;
  LatLng? _point;
  String? _country;
  int _lookup = 0;

  void _set(LatLng p) {
    setState(() {
      _point = p;
      _country = null;
    });
    _showPicked();
    final id = ++_lookup;
    widget.countries?.then((index) {
      final iso = index.countryAt(p);
      if (!mounted || id != _lookup) return;
      setState(() => _country = iso == null ? null : index.byIso(iso)?.name);
    }, onError: (Object _) {});
  }

  /// Übernehmen; ist das Land noch nicht bestimmt, kurz nachschlagen
  /// (lokal, ohne Dienst).
  Future<void> _accept(LatLng p) async {
    var country = _country;
    if (country == null && widget.countries != null) {
      try {
        final index = await widget.countries!;
        final iso = index.countryAt(p);
        country = iso == null ? null : index.byIso(iso)?.name;
      } catch (_) {
        // Ohne Grenzdaten eben ohne Land – die Koordinate genügt.
      }
    }
    if (!mounted) return;
    _finish(PickedMapPoint(p, country: country));
  }

  void _finish(PickedMapPoint? result) {
    final done = widget.onDone;
    if (done != null) {
      done(result);
    } else if (result == null) {
      Navigator.of(context).maybePop();
    } else {
      Navigator.of(context).pop(result);
    }
  }

  @override
  void didUpdateWidget(MapPointPicker old) {
    super.didUpdateWidget(old);
    if (widget.request == old.request) return;
    // Neue Anfrage an denselben Picker: Auswahl zurücksetzen, Karte behalten.
    _lookup++;
    _point = null;
    _country = null;
    _showPicked();
    _showContext();
    _ml?.moveCamera(ml.CameraUpdate.newCameraPosition(
        ml.CameraPosition(target: _mlLatLng(widget.initialCenter), zoom: widget.initialZoom)));
    if (!_useMapLibre) _map.move(widget.initialCenter, widget.initialZoom);
  }

  void _zoomBy(double d) {
    if (_useMapLibre) {
      _ml?.animateCamera(ml.CameraUpdate.zoomBy(d));
      return;
    }
    final c = _map.camera;
    _map.move(c.center, (c.zoom + d).clamp(3.0, 18.0));
  }

  // ------------------------------------------------- Vektorkarte (MapLibre)

  static ml.LatLng _mlLatLng(LatLng p) => ml.LatLng(p.latitude, p.longitude);

  Map<String, dynamic> _features(List<(LatLng, String)> pts) => {
        'type': 'FeatureCollection',
        'features': [
          for (final (p, kind) in pts)
            {
              'type': 'Feature',
              'properties': {'kind': kind},
              'geometry': {'type': 'Point', 'coordinates': [p.longitude, p.latitude]},
            },
        ],
      };

  Map<String, dynamic> _contextFeatures() => _features([
        if (widget.start != null) (widget.start!, 'start'),
        for (final s in widget.stops) (s, 'stop'),
        if (widget.dest != null) (widget.dest!, 'dest'),
      ]);

  void _showContext() {
    final map = _ml;
    if (!_useMapLibre || !_mlReady || map == null) return;
    map.setGeoJsonSource('context', _contextFeatures());
  }

  Future<void> _onStyleLoaded() async {
    final map = _ml;
    if (map == null) return;
    await map.addGeoJsonSource('context', _contextFeatures());
    await map.addCircleLayer('context', 'context-points', const ml.CircleLayerProperties(
      circleRadius: ['match', ['get', 'kind'], 'stop', 5, 7],
      circleColor: ['match', ['get', 'kind'], 'start', '#2E7D32', 'dest', '#C62828', '#3949AB'],
      circleStrokeColor: '#FFFFFF',
      circleStrokeWidth: 2,
    ));
    await map.addGeoJsonSource('picked', _features(const []));
    // Gut sichtbarer Punkt: orange mit weißem Rand und Halo.
    await map.addCircleLayer('picked', 'picked-halo', const ml.CircleLayerProperties(
      circleRadius: 18,
      circleColor: '#E65100',
      circleOpacity: 0.2,
    ));
    await map.addCircleLayer('picked', 'picked-dot', const ml.CircleLayerProperties(
      circleRadius: 9,
      circleColor: '#E65100',
      circleStrokeColor: '#FFFFFF',
      circleStrokeWidth: 3,
    ));
    _mlReady = true;
    _showPicked();
  }

  void _showPicked() {
    final map = _ml;
    final p = _point;
    if (!_useMapLibre || !_mlReady || map == null) return;
    map.setGeoJsonSource('picked', _features([if (p != null) (p, 'picked')]));
  }

  Widget _vectorMap() => FutureBuilder<String>(
        future: _style,
        builder: (context, snap) {
          if (snap.hasError) {
            // Stil nicht erreichbar: OSM-Karte als Rückfall.
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (mounted && _useMapLibre) setState(() => _useMapLibre = false);
            });
            return const SizedBox.shrink();
          }
          if (!snap.hasData) return const Center(child: CircularProgressIndicator());
          return ml.MapLibreMap(
            key: const Key('picker-maplibre'),
            styleString: snap.data!,
            initialCameraPosition:
                ml.CameraPosition(target: _mlLatLng(widget.initialCenter), zoom: widget.initialZoom),
            minMaxZoomPreference: const ml.MinMaxZoomPreference(3, 18),
            onMapCreated: (c) => _ml = c,
            onStyleLoadedCallback: _onStyleLoaded,
            onMapClick: (_, latLng) => _set(LatLng(latLng.latitude, latLng.longitude)),
            rotateGesturesEnabled: false,
            tiltGesturesEnabled: false,
            compassEnabled: false,
            attributionButtonPosition: ml.AttributionButtonPosition.bottomLeft,
          );
        },
      );

  /// Fallback: bisherige OSM-Rasterkarte (Beschriftung in Landessprache).
  Widget _osmMap(LatLng? p) {
    return FlutterMap(
            mapController: _map,
            options: MapOptions(
              initialCenter: widget.initialCenter,
              initialZoom: widget.initialZoom,
              minZoom: 3,
              maxZoom: 18,
              interactionOptions: const InteractionOptions(
                flags: InteractiveFlag.all & ~InteractiveFlag.rotate,
              ),
              onTap: (_, latLng) => _set(latLng),
            ),
            children: [
              if (widget.showTiles)
                TileLayer(
                  urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                  userAgentPackageName: 'com.mexx.driverroute.eta',
                ),
              MarkerLayer(markers: [
                if (widget.start != null)
                  Marker(
                    point: widget.start!,
                    width: 30,
                    height: 30,
                    child: const Icon(Icons.trip_origin, size: 20, color: Colors.green),
                  ),
                for (final s in widget.stops)
                  Marker(
                    point: s,
                    width: 24,
                    height: 24,
                    child: const Icon(Icons.circle, size: 12, color: Colors.indigo),
                  ),
                if (widget.dest != null)
                  Marker(
                    point: widget.dest!,
                    width: 34,
                    height: 34,
                    child: const Icon(Icons.location_pin, size: 26, color: Colors.red),
                  ),
                if (p != null)
                  // Spitze der Nadel genau auf dem Punkt.
                  Marker(
                    key: const Key('picked-marker'),
                    point: p,
                    width: 56,
                    height: 56,
                    alignment: Alignment.topCenter,
                    child: const Icon(Icons.location_on, size: 56, color: Color(0xFFE65100)),
                  ),
              ]),
              const RichAttributionWidget(
                attributions: [TextSourceAttribution('OpenStreetMap-Mitwirkende')],
              ),
            ],
          );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final p = _point;
    return Scaffold(
      appBar: AppBar(
        title: Text(MediaQuery.sizeOf(context).width < 520
            ? 'Zwischenpunkt wählen'
            : 'Zwischenpunkt auf Karte wählen'),
        leading: IconButton(
          tooltip: 'Abbrechen',
          icon: const Icon(Icons.close),
          onPressed: () => _finish(null),
        ),
      ),
      body: Stack(
        children: [
          if (_useMapLibre) _vectorMap() else _osmMap(p),
          Positioned(
            left: 12,
            right: 12,
            top: 12,
            child: Align(
              alignment: Alignment.topCenter,
              child: Card(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                  child: Text(
                    p == null
                        ? 'Auf die Karte tippen, um den Zwischenpunkt zu setzen.'
                        : 'Erneut tippen verschiebt den Punkt.',
                    style: theme.textTheme.bodyMedium,
                  ),
                ),
              ),
            ),
          ),
          Positioned(
            right: 12,
            top: 0,
            bottom: 0,
            child: Center(
              child: Material(
                elevation: 3,
                borderRadius: BorderRadius.circular(12),
                color: theme.colorScheme.surface,
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                  IconButton(
                    tooltip: 'Näher heran',
                    constraints: BoxConstraints.tight(const Size(48, 48)),
                    icon: const Icon(Icons.add),
                    onPressed: () => _zoomBy(1),
                  ),
                  IconButton(
                    tooltip: 'Weiter weg',
                    constraints: BoxConstraints.tight(const Size(48, 48)),
                    icon: const Icon(Icons.remove),
                    onPressed: () => _zoomBy(-1),
                  ),
                ]),
              ),
            ),
          ),
        ],
      ),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
          // Schmal (Smartphone): Angabe über dem Knopf, sonst nebeneinander.
          child: Flex(
              direction: MediaQuery.sizeOf(context).width < 520 ? Axis.vertical : Axis.horizontal,
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: MediaQuery.sizeOf(context).width < 520
                  ? CrossAxisAlignment.stretch
                  : CrossAxisAlignment.center,
              children: [
            Flexible(
              fit: MediaQuery.sizeOf(context).width < 520 ? FlexFit.loose : FlexFit.tight,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    p == null
                        ? 'Noch kein Punkt gewählt'
                        : '📍 Kartenpunkt${_country == null ? '' : ' · $_country'}',
                    key: const Key('picked-label'),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.titleSmall,
                  ),
                  if (p != null)
                    Text(
                      '${p.latitude.toStringAsFixed(4)}, ${p.longitude.toStringAsFixed(4)}',
                      key: const Key('picked-coordinates'),
                      style: theme.textTheme.bodySmall,
                    ),
                ],
              ),
            ),
            const SizedBox(width: 12, height: 8),
            FilledButton.icon(
              icon: const Icon(Icons.check),
              label: const Text('Als Zwischenpunkt übernehmen'),
              onPressed: p == null ? null : () => _accept(p),
            ),
          ]),
        ),
      ),
    );
  }
}

/// Wiederverwendeter Kartenpicker (Web, Vektorkarte).
///
/// Jedes Öffnen von [MapPointPicker] als eigene Seite legte eine neue
/// MapLibre-Karte samt WebGL-Kontext und Plattformansicht an. Geschlossene
/// Karten gibt die Seite nie frei: Flutter behält die View-Fabrik jeder
/// Plattformansicht (gemessen je Öffnen +8 MB JS-Speicher, dazu je Öffnen
/// eine neue Kachelaufbereitung mit kurzzeitig +200 MB Prozessspeicher).
/// Der Host hält deshalb EINEN Picker mit EINER Karte über der App: beim
/// ersten Öffnen erzeugt, danach nur ausgeblendet und mit neuer Anfrage
/// wieder gezeigt. Eine unsichtbare Seite im Navigator hält die gewohnte
/// Zurück-Navigation (Browser/Android) bei.
class MapPickerHost extends StatefulWidget {
  const MapPickerHost({super.key});

  static final ValueNotifier<_PickerRequest?> _request = ValueNotifier(null);
  static int _seq = 0;
  static bool _mounted = false;
  static _MapPickerHostState? _state;

  /// Picker-Karte vollständig freigeben (ausgeblendet, nicht offen) – vor
  /// einer zweiten großen Karte wie der Tour-Animation, damit nie zwei
  /// WebGL-Karten gleichzeitig Speicher halten. Kehrt erst zurück, wenn die
  /// Karte entfernt ist (MapLibre `remove()`, Kontext verloren); das nächste
  /// Öffnen legt sie neu an.
  static Future<void> release() async {
    final s = _state;
    if (s == null || _request.value != null || !s._drop()) return;
    await WidgetsBinding.instance.endOfFrame;
  }

  /// Ist ein Host eingebaut (Web) und die Vektorkarte vorgesehen?
  static bool get available => _mounted && debugMapPickerUseMapLibre;

  /// App unter dem Host: solange der Picker offen ist, für Bedienungshilfen
  /// ausgeblendet – sonst liegen ihre Semantik-Elemente im Browser über der
  /// Karte und fangen Tippen und Ziehen ab.
  static Widget behind(Widget app) => ValueListenableBuilder<_PickerRequest?>(
        valueListenable: _request,
        builder: (_, req, child) => ExcludeSemantics(excluding: req != null, child: child),
        child: app,
      );

  /// Picker zeigen; liefert den Punkt oder null (abgebrochen).
  static Future<PickedMapPoint?> pick(
    BuildContext context, {
    required LatLng initialCenter,
    double initialZoom = 5,
    LatLng? start,
    LatLng? dest,
    List<LatLng> stops = const [],
    Future<CountryIndex>? countries,
  }) async {
    final nav = Navigator.of(context);
    final route = PageRouteBuilder<PickedMapPoint>(
      opaque: false,
      transitionDuration: Duration.zero,
      reverseTransitionDuration: Duration.zero,
      pageBuilder: (_, __, ___) => const SizedBox.shrink(),
    );
    final req = _PickerRequest(
      id: ++_seq,
      initialCenter: initialCenter,
      initialZoom: initialZoom,
      start: start,
      dest: dest,
      stops: stops,
      countries: countries,
      finish: (result) {
        if (route.isCurrent) {
          nav.pop(result);
        } else if (route.isActive) {
          nav.removeRoute(route);
        }
      },
    );
    _request.value = req;
    try {
      return await nav.push(route);
    } finally {
      if (_request.value == req) _request.value = null;
    }
  }

  @override
  State<MapPickerHost> createState() => _MapPickerHostState();
}

class _PickerRequest {
  _PickerRequest({
    required this.id,
    required this.initialCenter,
    required this.initialZoom,
    required this.start,
    required this.dest,
    required this.stops,
    required this.countries,
    required this.finish,
  });

  final int id;
  final LatLng initialCenter;
  final double initialZoom;
  final LatLng? start;
  final LatLng? dest;
  final List<LatLng> stops;
  final Future<CountryIndex>? countries;
  final void Function(PickedMapPoint? result) finish;
}

class _MapPickerHostState extends State<MapPickerHost> {
  _PickerRequest? _last;

  /// Picker samt Karte; nach [MapPickerHost.release] neu (eigenes Overlay).
  OverlayEntry? _entry;
  int _generation = 0;
  GlobalKey _pickerKey = GlobalKey();

  @override
  void initState() {
    super.initState();
    MapPickerHost._mounted = true;
    MapPickerHost._state = this;
    MapPickerHost._request.addListener(_changed);
  }

  @override
  void dispose() {
    MapPickerHost._request.removeListener(_changed);
    MapPickerHost._mounted = false;
    if (MapPickerHost._state == this) MapPickerHost._state = null;
    super.dispose();
  }

  void _changed() {
    final req = MapPickerHost._request.value;
    setState(() {
      if (req != null) {
        _last = req;
        _entry ??= OverlayEntry(maintainState: true, builder: (_) => _picker());
      }
    });
    _entry?.markNeedsBuild();
  }

  /// Picker (und damit die Karte) aus dem Baum nehmen; true, wenn es einen
  /// gab.
  bool _drop() {
    if (_entry == null) return false;
    setState(() {
      _entry = null;
      _last = null;
      _generation++;
      _pickerKey = GlobalKey();
    });
    return true;
  }

  Widget _picker() {
    final r = _last!;
    return MapPointPicker(
      key: _pickerKey,
      request: r.id,
      initialCenter: r.initialCenter,
      initialZoom: r.initialZoom,
      start: r.start,
      dest: r.dest,
      stops: r.stops,
      countries: r.countries,
      onDone: r.finish,
    );
  }

  @override
  Widget build(BuildContext context) {
    // Vor dem ersten Öffnen bzw. nach dem Freigeben: keine Karte.
    final entry = _entry;
    if (_last == null || entry == null) return const SizedBox.shrink();
    final open = MapPickerHost._request.value != null;
    return Offstage(
      offstage: !open,
      child: TickerMode(
        enabled: open,
        // Eigenes Overlay: Tooltips & Co. liegen über dem App-Navigator.
        child: Overlay(key: ValueKey(_generation), initialEntries: [entry]),
      ),
    );
  }
}
