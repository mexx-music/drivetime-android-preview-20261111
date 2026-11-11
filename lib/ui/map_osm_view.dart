import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

/// Ein Abschnitt der Route auf der Karte.
///
/// Gefahrene Abschnitte werden durchgezogen gezeichnet, Fähr- oder
/// Lückenabschnitte gestrichelt – dort fährt das Fahrzeug keine Kilometer.
class MapSegment {
  const MapSegment({
    required this.points,
    this.label,
    this.isFerry = false,
    this.isGap = false,
  });

  final List<LatLng> points;
  final String? label;
  final bool isFerry;

  /// Teilstück, für das keine Geometrie geliefert wurde.
  final bool isGap;

  bool get isDashed => isFerry || isGap;
}

/// Kartenansicht der Route (OpenStreetMap).
class MapOsmView extends StatefulWidget {
  const MapOsmView({
    super.key,
    required this.start,
    required this.dest,
    required this.route,
    this.segments = const [],
    this.stops = const [],
    this.title = '🗺️ Route',
    this.subtitle,
    this.mapController,
  });

  final LatLng start;
  final LatLng dest;

  /// Gesamte Route am Stück (Rückwärtskompatibilität).
  final List<LatLng> route;

  /// Optional: Route in Abschnitte zerlegt (Fahrt, Fähre, Lücke).
  final List<MapSegment> segments;

  /// Zwischenstopps für eigene Marker.
  final List<LatLng> stops;
  final String title;
  final String? subtitle;

  /// Nur für Tests: eigener Controller, um die Kartenereignisse zu beobachten.
  @visibleForTesting
  final MapController? mapController;

  @override
  State<MapOsmView> createState() => _MapOsmViewState();
}

class _MapOsmViewState extends State<MapOsmView> {
  late final MapController _mapController = widget.mapController ?? MapController();

  List<MapSegment> get _segments {
    if (widget.segments.isNotEmpty) return widget.segments;
    if (widget.route.length >= 2) return [MapSegment(points: widget.route)];
    return const [];
  }

  /// Alle Punkte der Route – Grundlage für den Kartenausschnitt.
  List<LatLng> get _allPoints => [
        widget.start,
        for (final s in _segments) ...s.points,
        ...widget.stops,
        widget.dest,
      ];

  /// Zum Zeichnen ausdünnen.
  ///
  /// Step-Polylinien liefern alle paar Meter einen Punkt – auf einer
  /// Fährtour sind das schnell über 50.000. Für die Darstellung reicht ein
  /// Bruchteil; die Kilometerangabe rechnet weiterhin mit allen Punkten.
  static List<LatLng> _thin(List<LatLng> points, {int max = 3000}) {
    if (points.length <= max) return points;
    final step = (points.length / max).ceil();
    final out = <LatLng>[
      for (var i = 0; i < points.length; i += step) points[i],
    ];
    if (out.last != points.last) out.add(points.last);
    return out;
  }

  void _zoomBy(double delta) {
    final camera = _mapController.camera;
    final next = (camera.zoom + delta).clamp(2.0, 18.0);
    _mapController.move(camera.center, next);
  }

  double get _drivenKm {
    const distance = Distance();
    var meters = 0.0;
    for (final seg in _segments) {
      if (seg.isDashed) continue;
      for (var i = 1; i < seg.points.length; i++) {
        meters += distance(seg.points[i - 1], seg.points[i]);
      }
    }
    return meters / 1000.0;
  }

  /// Ausschnitt, der die ganze Route samt Start, Stopps und Ziel zeigt.
  CameraFit get _routeFit {
    final pts = _allPoints;
    final bounds = LatLngBounds(pts.first, pts.first);
    for (final p in pts) {
      bounds.extend(p);
    }
    return CameraFit.bounds(bounds: bounds, padding: const EdgeInsets.all(32));
  }

  /// "Auf Route zoomen" – nachdem der Nutzer die Karte bewegt hat.
  void _fit() => _mapController.fitCamera(_routeFit);

  @override
  Widget build(BuildContext context) {
    final segments = _segments;
    final hasRoute = segments.any((s) => s.points.length >= 2);

    return Scaffold(
      appBar: AppBar(
        title: Text(widget.title),
        actions: [
          IconButton(
            tooltip: 'Auf Route zoomen',
            icon: const Icon(Icons.fit_screen),
            onPressed: hasRoute ? _fit : null,
          ),
        ],
        bottom: widget.subtitle == null
            ? null
            : PreferredSize(
                preferredSize: const Size.fromHeight(24),
                child: Padding(
                  padding: const EdgeInsets.only(left: 16, right: 16, bottom: 6),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: Text(widget.subtitle!,
                        style: Theme.of(context).textTheme.bodySmall),
                  ),
                ),
              ),
      ),
      body: Column(
        children: [
          if (!hasRoute)
            const MaterialBanner(
              content: Text(
                'Für diese Route liegt keine Streckenführung vor. '
                'Angezeigt werden nur Start und Ziel.',
              ),
              actions: [SizedBox.shrink()],
            ),
          if (segments.any((s) => s.isGap))
            const MaterialBanner(
              content: Text(
                'Ein Teilstück konnte nicht abgerufen werden – '
                'es ist gestrichelt dargestellt.',
              ),
              actions: [SizedBox.shrink()],
            ),
          Expanded(
            child: Stack(
              children: [
    FlutterMap(
                  mapController: _mapController,
                  options: MapOptions(
                    initialCenter: widget.start,
                    initialZoom: 5,
                    // Den Routen-Ausschnitt setzt flutter_map selbst, sobald
                    // die Kartengröße feststeht – NACH seiner eigenen
                    // Größenmeldung. Früher passte onMapReady die Kamera an;
                    // die danach eintreffende Größenmeldung trug noch die alte
                    // Kamera (Zoom 5), und die Kachelebene lud und verwarf
                    // Kacheln für diesen veralteten Ausschnitt: grau, bis man
                    // die Karte bewegte.
                    initialCameraFit: _routeFit,
                    // Norden bleibt oben: Auf einer Streckenkarte nützt Drehen
                    // nichts, und die Drehgeste konkurriert mit dem Zoomen –
                    // das fühlt sich an, als ginge Zoomen nicht.
                    interactionOptions: const InteractionOptions(
                      flags: InteractiveFlag.all & ~InteractiveFlag.rotate,
                    ),
                    onMapReady: () {
                      if (kDebugMode) {
                        debugPrint('[MapOsmView] Abschnitte: ${segments.length}, '
                            'Punkte: ${_allPoints.length}');
                      }
                    },
                  ),
                  children: [
                    TileLayer(
                      urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                      userAgentPackageName: 'com.mexx.driverroute.eta',
                    ),
                    PolylineLayer(
                      polylines: [
                        for (final seg in segments)
                          if (seg.points.length >= 2)
                            Polyline(
                              points: _thin(seg.points),
                              strokeWidth: seg.isDashed ? 3 : 5,
                              color: seg.isFerry
                                  ? Colors.teal
                                  : (seg.isGap ? Colors.orange : Colors.indigo),
                              pattern: seg.isDashed
                                  ? StrokePattern.dashed(segments: const [12, 10])
                                  : const StrokePattern.solid(),
                            ),
                      ],
                    ),
                    MarkerLayer(
                      markers: [
                        Marker(
                          point: widget.start,
                          width: 40,
                          height: 40,
                          child: const Icon(Icons.trip_origin,
                              size: 26, color: Colors.green),
                        ),
                        for (final stop in widget.stops)
                          Marker(
                            point: stop,
                            width: 34,
                            height: 34,
                            child: const Icon(Icons.circle,
                                size: 16, color: Colors.indigo),
                          ),
                        Marker(
                          point: widget.dest,
                          width: 44,
                          height: 44,
                          child: const Icon(Icons.location_pin,
                              size: 34, color: Colors.red),
                        ),
                      ],
                    ),
                    const RichAttributionWidget(
                      attributions: [
                        TextSourceAttribution('OpenStreetMap-Mitwirkende'),
                      ],
                    ),
                  ],
                ),
                // Zoom auch ohne Geste und ohne Mausrad bedienbar.
                Positioned(
                  right: 12,
                  bottom: 12,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      FloatingActionButton.small(
                        heroTag: 'zoomIn',
                        tooltip: 'Näher heran',
                        onPressed: () => _zoomBy(1),
                        child: const Icon(Icons.add),
                      ),
                      const SizedBox(height: 8),
                      FloatingActionButton.small(
                        heroTag: 'zoomOut',
                        tooltip: 'Weiter weg',
                        onPressed: () => _zoomBy(-1),
                        child: const Icon(Icons.remove),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
      bottomNavigationBar: hasRoute
          ? SafeArea(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                child: Row(
                  children: [
                    const Icon(Icons.straighten, size: 18),
                    const SizedBox(width: 8),
                    Text('Strecke auf der Karte: '
                        '${_drivenKm.toStringAsFixed(0)} km'),
                    if (segments.any((s) => s.isFerry)) ...[
                      const SizedBox(width: 16),
                      const Icon(Icons.directions_boat, size: 18),
                      const SizedBox(width: 6),
                      const Text('Fähre gestrichelt'),
                    ],
                  ],
                ),
              ),
            )
          : null,
    );
  }
}
