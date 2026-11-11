import 'package:latlong2/latlong.dart';

import '../models/ferry_route.dart';
import '../models/route_candidate.dart';
import 'ferry_auto.dart';

/// Die beiden Landstrecken um eine Fähre herum.
///
/// Bisher wurde für eine Fährtour nur eine Gesamtdistanz geführt. Damit fehlte
/// der Karte die Geometrie der tatsächlich geplanten Route – sie fragte Google
/// erneut von Start nach Ziel und zeichnete dann Googles eigene, kürzeste
/// Fähre statt der geplanten.
///
/// Hier werden beide Landwege getrennt abgerufen, jeweils **ohne** Fähre:
/// sonst schmuggelt Google in die Anfahrt eine eigene Überfahrt.
class FerryLegPlan {
  final FerryRoute ferry;

  /// Start → Abfahrtshafen.
  final RouteCandidate legA;

  /// Ankunftshafen → Ziel.
  final RouteCandidate legB;

  /// Zwischenstopps vor bzw. nach der Fähre.
  final List<String> stopsBefore;
  final List<String> stopsAfter;

  const FerryLegPlan({
    required this.ferry,
    required this.legA,
    required this.legB,
    this.stopsBefore = const [],
    this.stopsAfter = const [],
  });

  /// Alle Wegpunkte in Fahrtreihenfolge – für ETA und Anzeige.
  List<String> get routedStops => [...stopsBefore, ...stopsAfter];

  /// Reine Straßenkilometer, ohne die Seestrecke.
  double get roadKm => legA.km + legB.km;

  /// Alle Etappen beider Landwege – Grundlage der LKW-Fahrzeit.
  List<Map<String, dynamic>> get steps => [...legA.steps, ...legB.steps];

  /// Abfahrtshafen = Ende des ersten Landwegs.
  /// Eigene Hafenkoordinaten braucht es nicht, Google geocodiert die
  /// Hafennamen selbst.
  LatLng? get portFrom =>
      legA.points.isEmpty ? null : legA.points.last;

  /// Ankunftshafen = Anfang des zweiten Landwegs.
  LatLng? get portTo => legB.points.isEmpty ? null : legB.points.first;

  static Future<FerryLegPlan?> plan({
    required String origin,
    required String destination,
    required FerryRoute ferry,
    required FerryAutoDetect det,
    /// Zwischenstopps des Fahrers in Fahrtreihenfolge.
    List<String> stops = const [],
    /// Koordinaten dazu (gleiche Reihenfolge, Einträge dürfen null sein).
    List<LatLng?> stopCoords = const [],
  }) async {
    // Erst beide Landwege ohne Stopps – daraus ergeben sich die Häfen.
    final a0 = await det.fetchDirections(
      origin: origin,
      destination: ferry.from,
      avoidFerries: true,
    );
    final b0 = await det.fetchDirections(
      origin: ferry.to,
      destination: destination,
      avoidFerries: true,
    );
    if (!a0.ok || !b0.ok || a0.candidates.isEmpty || b0.candidates.isEmpty) {
      return null;
    }
    var legA = a0.candidates.first;
    var legB = b0.candidates.first;

    if (stops.isEmpty) {
      return FerryLegPlan(ferry: ferry, legA: legA, legB: legB);
    }

    final split = splitStops(
      stops: stops,
      stopCoords: stopCoords,
      portFrom: legA.points.isEmpty ? null : legA.points.last,
      portTo: legB.points.isEmpty ? null : legB.points.first,
    );

    // Nur den Abschnitt neu abrufen, der wirklich Stopps bekommen hat.
    if (split.before.isNotEmpty) {
      final a = await det.fetchDirections(
        origin: origin,
        destination: ferry.from,
        waypoints: split.before,
        avoidFerries: true,
      );
      if (!a.ok || a.candidates.isEmpty) return null;
      legA = a.candidates.first;
    }
    if (split.after.isNotEmpty) {
      final b = await det.fetchDirections(
        origin: ferry.to,
        destination: destination,
        waypoints: split.after,
        avoidFerries: true,
      );
      if (!b.ok || b.candidates.isEmpty) return null;
      legB = b.candidates.first;
    }

    return FerryLegPlan(
      ferry: ferry,
      legA: legA,
      legB: legB,
      stopsBefore: split.before,
      stopsAfter: split.after,
    );
  }

  /// Teilt die Zwischenstopps auf die beiden Landwege auf.
  ///
  /// Die Reihenfolge des Fahrers bleibt erhalten: gesucht wird die Stelle, ab
  /// der die Stopps näher am Ankunftshafen liegen als am Abfahrtshafen. Fehlt
  /// zu einem Stopp die Koordinate, bleibt er bei der bisherigen Seite.
  static ({List<String> before, List<String> after}) splitStops({
    required List<String> stops,
    required List<LatLng?> stopCoords,
    required LatLng? portFrom,
    required LatLng? portTo,
  }) {
    if (portFrom == null || portTo == null) {
      return (before: List<String>.of(stops), after: const <String>[]);
    }
    const distance = Distance();
    var cut = stops.length; // ab hier gehört alles hinter die Fähre
    for (var i = 0; i < stops.length; i++) {
      final c = i < stopCoords.length ? stopCoords[i] : null;
      if (c == null) continue;
      if (distance(c, portTo) < distance(c, portFrom)) {
        cut = i;
        break;
      }
    }
    return (
      before: stops.sublist(0, cut),
      after: stops.sublist(cut),
    );
  }
}
