import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:flutter/foundation.dart';

import 'package:driverroute_eta/secrets.dart';
import 'maps_proxy.dart';

/// Kleiner Service, der Straßenentfernungen via Google Directions API holt.
class DistanceService {
  const DistanceService();

  /// Gibt die Gesamtstrecke in Kilometern (1 Dezimalstelle) oder null bei Fehler.
  /// [avoidFerries] ist für Landwege zu einem Hafen wichtig: ohne das
  /// schmuggelt Google in die vermeintliche Straßenstrecke eigene Fähren
  /// (z. B. quer durch Dänemark) und die Kilometer stimmen nicht mehr.
  Future<double?> fetchKmDistance({
    required String origin,
    required String destination,
    List<String>? waypoints,
    bool avoidFerries = false,
  }) async {
    // If running on web and a proxy is configured, use it
    if (!mapsDirectCallsAllowed()) {
      if (mapsProxyConfigured()) {
        try {
          final data = await proxyDirections(
              origin: origin,
              destination: destination,
              waypoints: waypoints,
              avoidFerries: avoidFerries);
          final status = (data['status'] ?? 'UNKNOWN').toString();
          if (status != 'OK') {
            if (kDebugMode) {
              debugPrint('[DistanceService] Proxy directions status $status');
              if (data.containsKey('error_message')) debugPrint('[DistanceService] proxy error_message: ${data['error_message']}');
            }
            return null;
          }
          final route = (data['routes'] as List).first as Map<String, dynamic>;
          final legs = (route['legs'] as List).cast<Map<String, dynamic>>();
          double meters = 0;
          for (final l in legs) {
            meters += (l['distance']['value'] as num).toDouble();
          }
          final km = meters / 1000.0;
          final rounded = (km * 10).round() / 10.0;
          if (kDebugMode) debugPrint('[DistanceService] Proxy Distance $origin -> $destination: ${rounded} km');
          return rounded;
        } catch (e, st) {
          if (kDebugMode) {
            debugPrint('[DistanceService] Exception from proxy: $e');
            debugPrint(st.toString());
          }
          return null;
        }
      }

      // no proxy -> web blocked
      if (kDebugMode) debugPrint('[DistanceService] Web direct Directions request blocked');
      return null;
    }
    if (GOOGLE_MAPS_API_KEY.isEmpty) {
      if (kDebugMode) debugPrint('[DistanceService] No Google Maps API key configured');
      return null;
    }

    String wp = '';
    if (waypoints != null && waypoints.isNotEmpty) {
      final parts = waypoints.map((w) => Uri.encodeComponent(w)).join('|');
      wp = '&waypoints=$parts';
    }

    final params = [
          'origin=${Uri.encodeComponent(origin)}',
          'destination=${Uri.encodeComponent(destination)}',
          'mode=driving',
          'units=metric',
          'language=en',
          'departure_time=now',
          'alternatives=false',
          if (avoidFerries) 'avoid=ferries',
          'key=$GOOGLE_MAPS_API_KEY',
        ].join('&') +
        wp;

    final uri = Uri.parse(
        'https://maps.googleapis.com/maps/api/directions/json?$params');

    try {
      if (kDebugMode) {
        // Mask API key in logs
        final s = uri.toString().replaceAll(RegExp(r'key=[^&]+'), 'key=***');
        debugPrint('[DistanceService] GET $s');
      }
      final res = await http.get(uri).timeout(proxyRequestTimeout);
      if (res.statusCode != 200) {
        if (kDebugMode) {
          final s = uri.toString().replaceAll(RegExp(r'key=[^&]+'), 'key=***');
          debugPrint('[DistanceService] HTTP ${res.statusCode} for $s');
          debugPrint('[DistanceService] Response body: ${res.body}');
        }
        return null;
      }
      final data = jsonDecode(res.body) as Map<String, dynamic>;
      final status = (data['status'] ?? 'UNKNOWN').toString();
      if (status != 'OK') {
        if (kDebugMode) {
          final s = uri.toString().replaceAll(RegExp(r'key=[^&]+'), 'key=***');
          debugPrint('[DistanceService] Directions status $status for $s — body: ${res.body}');
          if (data.containsKey('error_message')) debugPrint('[DistanceService] error_message: ${data['error_message']}');
        }
        return null;
      }

      final route = (data['routes'] as List).first as Map<String, dynamic>;
      final legs = (route['legs'] as List).cast<Map<String, dynamic>>();
      double meters = 0;
      for (final l in legs) {
        meters += (l['distance']['value'] as num).toDouble();
      }
      final km = meters / 1000.0;
      // runde auf 1 Dezimalstelle
      final rounded = (km * 10).round() / 10.0;
      if (kDebugMode) debugPrint('[DistanceService] Distance $origin -> $destination: ${rounded} km');
      return rounded;
    } catch (e, st) {
      if (kDebugMode) {
        debugPrint('[DistanceService] Exception fetching directions: $e');
        debugPrint(st.toString());
      }
      return null;
    }
  }
}
