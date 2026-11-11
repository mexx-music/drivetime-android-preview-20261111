import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:flutter/foundation.dart';
import 'package:driverroute_eta/secrets.dart';
import 'maps_proxy.dart';

class GeocodingResult {
  final double lat;
  final double lng;
  final String description;
  GeocodingResult(this.lat, this.lng, this.description);
}

class GeocodingService {
  static Future<GeocodingResult> reverse(
    double latitude,
    double longitude,
  ) async {
    if (!mapsDirectCallsAllowed()) {
      if (!mapsProxyConfigured()) throw Exception(webBlockedMessage);
      return _parseResponse(
        await proxyReverseGeocode(latitude, longitude),
        '$latitude,$longitude',
      );
    }
    if (GOOGLE_MAPS_API_KEY.isEmpty) {
      throw Exception('No Google Maps API key configured');
    }
    final uri = Uri.parse(
      'https://maps.googleapis.com/maps/api/geocode/json?latlng=$latitude,$longitude&key=$GOOGLE_MAPS_API_KEY',
    );
    final res = await http.get(uri);
    if (res.statusCode != 200) throw Exception('HTTP ${res.statusCode}');
    return _parseResponse(
      jsonDecode(res.body) as Map<String, dynamic>,
      '$latitude,$longitude',
    );
  }

  static GeocodingResult _parseResponse(
    Map<String, dynamic> data,
    String fallback,
  ) {
    if (data['status'] != 'OK') {
      throw Exception('Geocoding status ${data['status']}');
    }
    final results =
        (data['results'] as List? ?? const []).cast<Map<String, dynamic>>();
    if (results.isEmpty) throw Exception('No results');
    final first = results.first;
    final location = (first['geometry'] as Map<String, dynamic>?)?['location']
        as Map<String, dynamic>?;
    if (location == null) throw Exception('No location in response');
    return GeocodingResult(
      (location['lat'] as num).toDouble(),
      (location['lng'] as num).toDouble(),
      (first['formatted_address'] ?? fallback).toString(),
    );
  }

  /// Resolve freeform address/place text to lat/lng using Google Geocoding API.
  /// Throws an Exception on error.
  static Future<GeocodingResult> resolve(String input) async {
    // If we are on web and a proxy is configured, use it instead of direct Google REST calls
    if (!mapsDirectCallsAllowed()) {
      if (mapsProxyConfigured()) {
        // Use proxy and parse the standard Google Geocoding response
        final data = await proxyGeocode(input);
        // reuse the same parsing logic as the direct flow below
        try {
          if (data['status'] != 'OK') {
            if (kDebugMode) {
              debugPrint(
                  '[GeocodingService] Proxy geocode status: ${data['status']}');
              if (data.containsKey('error_message'))
                debugPrint(
                    '[GeocodingService] proxy error_message: ${data['error_message']}');
            }
            throw Exception(
                'Geocoding status ${data['status']}${data['error_message'] != null ? ': ${data['error_message']}' : ''}');
          }
          final results =
              (data['results'] as List).cast<Map<String, dynamic>>();
          if (results.isEmpty) {
            if (kDebugMode)
              debugPrint('[GeocodingService] No results from proxy');
            throw Exception('No results');
          }
          final first = results.first;
          final geom = first['geometry'] as Map<String, dynamic>?;
          final loc = geom?['location'] as Map<String, dynamic>?;
          if (loc == null) {
            if (kDebugMode)
              debugPrint('[GeocodingService] No location in proxy response');
            throw Exception('No location in response');
          }
          final lat = (loc['lat'] as num).toDouble();
          final lng = (loc['lng'] as num).toDouble();
          final formatted = (first['formatted_address'] ?? input) as String;
          if (kDebugMode)
            debugPrint(
                '[GeocodingService] Resolved via proxy "$input" -> $lat,$lng ("$formatted")');
          return GeocodingResult(lat, lng, formatted);
        } catch (e) {
          if (kDebugMode)
            debugPrint('[GeocodingService] Proxy parsing exception: $e');
          rethrow;
        }
      }

      // No proxy configured -> block on web
      if (kDebugMode) debugPrint('[GeocodingService] Web geocoding blocked');
      throw Exception(webBlockedMessage);
    }

    // Non-web direct call path (unchanged)
    if (GOOGLE_MAPS_API_KEY.isEmpty ||
        GOOGLE_MAPS_API_KEY == 'DEIN_API_KEY_HIER') {
      if (kDebugMode)
        debugPrint('[GeocodingService] No Google Maps API key configured');
      throw Exception('No Google Maps API key configured');
    }
    final uri = Uri.parse(
      'https://maps.googleapis.com/maps/api/geocode/json?address=${Uri.encodeComponent(input)}&key=$GOOGLE_MAPS_API_KEY',
    );
    try {
      if (kDebugMode) {
        final s = uri.toString().replaceAll(RegExp(r'key=[^&]+'), 'key=***');
        debugPrint('[GeocodingService] GET $s');
      }
      final res = await http.get(uri);
      if (res.statusCode != 200) {
        if (kDebugMode) {
          final s = uri.toString().replaceAll(RegExp(r'key=[^&]+'), 'key=***');
          debugPrint('[GeocodingService] HTTP ${res.statusCode} for $s');
          debugPrint('[GeocodingService] Response body: ${res.body}');
        }
        throw Exception('HTTP ${res.statusCode}');
      }
      final data = jsonDecode(res.body) as Map<String, dynamic>;
      if (data['status'] != 'OK') {
        if (kDebugMode) {
          final s = uri.toString().replaceAll(RegExp(r'key=[^&]+'), 'key=***');
          debugPrint(
              '[GeocodingService] Geocoding status ${data['status']} for $s — body: ${res.body}');
          if (data.containsKey('error_message'))
            debugPrint(
                '[GeocodingService] error_message: ${data['error_message']}');
        }
        throw Exception(
            'Geocoding status ${data['status']}${data['error_message'] != null ? ': ${data['error_message']}' : ''}');
      }
      final results = (data['results'] as List).cast<Map<String, dynamic>>();
      if (results.isEmpty) {
        if (kDebugMode)
          debugPrint('[GeocodingService] No results — body: ${res.body}');
        throw Exception('No results');
      }
      final first = results.first;
      final geom = first['geometry'] as Map<String, dynamic>?;
      final loc = geom?['location'] as Map<String, dynamic>?;
      if (loc == null) {
        if (kDebugMode)
          debugPrint(
              '[GeocodingService] No location in response — body: ${res.body}');
        throw Exception('No location in response');
      }
      final lat = (loc['lat'] as num).toDouble();
      final lng = (loc['lng'] as num).toDouble();
      final formatted = (first['formatted_address'] ?? input) as String;
      if (kDebugMode)
        debugPrint(
            '[GeocodingService] Resolved "$input" -> $lat,$lng ("$formatted")');
      return GeocodingResult(lat, lng, formatted);
    } catch (e, st) {
      if (kDebugMode) {
        debugPrint('[GeocodingService] Exception: $e');
        debugPrint(st.toString());
      }
      rethrow;
    }
  }
}
