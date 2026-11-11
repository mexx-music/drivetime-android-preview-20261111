// lib/services/map_launcher.dart
import 'package:latlong2/latlong.dart';

import '../logic/ferry_leg_plan.dart';
import '../logic/ferry_sea_routes.dart';
import '../ui/map_osm_view.dart';
import '../utils/polyline.dart' as poly;

// Re-Export: der Decoder liegt jetzt in utils/polyline.dart, damit ihn auch
// Modelle ohne Flutter-/UI-Abhängigkeit benutzen können.
List<LatLng> decodePolyline(String encoded) => poly.decodePolyline(encoded);

/// Was die Karte zeigen soll – oder warum es keine Karte gibt.
class RouteMapPlan {
  const RouteMapPlan._({
    this.start,
    this.dest,
    this.route = const [],
    this.segments = const [],
    this.stops = const [],
    this.subtitle,
    this.message,
  });

  /// Keine Karte möglich; [message] sagt dem Nutzer, warum.
  const RouteMapPlan.unavailable(String message) : this._(message: message);

  /// Unverändert wiederhergestellter Plan (Filmspezifikation des
  /// Videoexports) – ohne neue Berechnung, ohne Provider-Aufruf.
  const RouteMapPlan.restored({
    required LatLng start,
    required LatLng dest,
    List<LatLng> route = const [],
    List<MapSegment> segments = const [],
    List<LatLng> stops = const [],
    String? subtitle,
  }) : this._(start: start, dest: dest, route: route, segments: segments, stops: stops, subtitle: subtitle);

  final LatLng? start;
  final LatLng? dest;
  final List<LatLng> route;
  final List<MapSegment> segments;
  final List<LatLng> stops;
  final String? subtitle;
  final String? message;

  bool get available => start != null && dest != null;

  /// true = keine Streckenführung, nur Start, Stopps und Ziel.
  bool get markersOnly => available && route.isEmpty && segments.isEmpty;
}

const String mapNeedsCalculation =
    'Die Karte zeigt die berechnete Route. Bitte zuerst die Route berechnen.';
const String mapNoGeometry =
    'Für diese Berechnung liegt keine Streckenführung vor.';
const String mapMarkersOnlyNote =
    'Streckenführung nicht verfügbar – die Karte zeigt nur Start, Stopps und Ziel.';

/// Bestimmt die Karte ausschließlich aus den Daten der letzten Berechnung.
///
/// Fragt bewusst NICHTS bei Google an. Die Karte kostet damit keinen
/// Provider-Aufruf, braucht keine eigene Tour und kann bei späterer
/// Tour-Pflicht nicht an ihr vorbei rechnen. Reihenfolge wie bisher:
///   1. Fährroute: die beiden geplanten Landwege plus Seestrecke,
///   2. sonst die Geometrie genau der berechneten Route (inkl. Stopps),
///   3. sonst – etwa Dänemark-Variante, gescheiterte Landwege oder manuelle
///      Kilometer – nur Start, Stopps und Ziel aus bereits bekannten
///      Koordinaten, ohne Linie.
RouteMapPlan planRouteMap({
  required bool hasResult,
  FerryLegPlan? ferryLegs,
  String? encodedPolyline,
  LatLng? startCoord,
  LatLng? destCoord,
  List<LatLng?> stopCoords = const [],
  String? routeNote,
}) {
  if (!hasResult) return const RouteMapPlan.unavailable(mapNeedsCalculation);
  final stops = [for (final c in stopCoords) if (c != null) c];

  final legs = ferryLegs;
  if (legs != null && legs.legA.points.isNotEmpty && legs.legB.points.isNotEmpty) {
    final from = legs.portFrom;
    final to = legs.portTo;
    return RouteMapPlan._(
      start: legs.legA.points.first,
      dest: legs.legB.points.last,
      segments: [
        MapSegment(points: legs.legA.points, label: 'Anfahrt → ${legs.ferry.from}'),
        if (from != null && to != null)
          // Seestrecke über Wasser: lokal hinterlegter Seeweg der bekannten
          // Verbindung (kein Dienst), sonst wie bisher die Gerade.
          MapSegment(
              points: ferryLinePoints(legs.ferry.from, legs.ferry.to, from, to),
              label: legs.ferry.name,
              isFerry: true),
        MapSegment(points: legs.legB.points, label: '${legs.ferry.to} → Ziel'),
      ],
      stops: stops,
      subtitle: routeNote,
    );
  }

  if (encodedPolyline != null && encodedPolyline.isNotEmpty) {
    final points = decodePolyline(encodedPolyline);
    if (points.length >= 2) {
      return RouteMapPlan._(
        start: points.first,
        dest: points.last,
        route: points,
        stops: stops,
        subtitle: routeNote ?? 'Berechnete Route',
      );
    }
  }

  if (startCoord != null && destCoord != null) {
    return RouteMapPlan._(
      start: startCoord,
      dest: destCoord,
      stops: stops,
      subtitle: routeNote == null ? mapMarkersOnlyNote : '$routeNote\n$mapMarkersOnlyNote',
    );
  }
  return const RouteMapPlan.unavailable(mapNoGeometry);
}
