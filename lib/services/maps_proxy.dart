import 'package:flutter/foundation.dart';
import 'dart:convert';
import 'package:http/http.dart' as http;

import 'catlab_trace.dart';
import '../tour/input_auth.dart';
import '../tour/tour_scope.dart';

/// Small abstraction for map REST calls. In browsers direct calls to Google
/// REST endpoints are blocked by CORS and should be proxied via a backend.
/// This file centralizes the guard so callers can be migrated later.

bool mapsDirectCallsAllowed() => debugMapsDirectCallsAllowed ?? !kIsWeb;

/// Nur für Tests: erzwingt den Web-Weg über den Proxy auch in der VM, damit
/// Tests die tatsächlichen Proxy-Aufrufe zählen können.
@visibleForTesting
bool? debugMapsDirectCallsAllowed;
@visibleForTesting
String? debugMapsProxyBase;
@visibleForTesting
http.Client? debugMapsProxyClient;

const String webBlockedMessage =
    'Web routing via direct Google REST request is blocked in browser';

// Optional proxy base for web builds. Provide via `--dart-define=MAPS_PROXY_BASE=https://...`
const String _mapsProxyBaseDefine =
    String.fromEnvironment('MAPS_PROXY_BASE', defaultValue: '');
String get mapsProxyBase => debugMapsProxyBase ?? _mapsProxyBaseDefine;
bool mapsProxyConfigured() => mapsProxyBase.isNotEmpty;

Future<http.Response> _post(Uri uri, String body,
    {Map<String, String> extraHeaders = const {}}) {
  final headers = {'Content-Type': 'application/json', ...extraHeaders};
  final client = debugMapsProxyClient;
  return client != null
      ? client.post(uri, headers: headers, body: body)
      : http.post(uri, headers: headers, body: body);
}

/// Obergrenze für eine einzelne Proxy-Anfrage. Ohne Timeout bleibt ein
/// hängender Request für immer offen und die App zeigt endlos
/// "Route wird berechnet". Großzügig gewählt, weil der Proxy nach Leerlauf
/// erst hochfahren muss.
const Duration proxyRequestTimeout = Duration(seconds: 45);

/// Debug helper - call this from a runtime location if you need to log the proxy config.
void _logMapsProxyConfig() {
  if (kDebugMode) {
    // ignore: avoid_print
    print(
        'MAPS_PROXY_BASE="${mapsProxyBase}" configured=${mapsProxyConfigured()}');
  }
}

/// Public wrapper to log proxy config in debug builds.
void logMapsProxyConfig() => _logMapsProxyConfig();

String _proxyBaseNoSlash() =>
    mapsProxyBase.replaceAll(RegExp(r'/+\u0000*\u0000*\u0000*\z'), '');

/// Proxy helper: POST /api/geocode with { address }
Future<Map<String, dynamic>> proxyGeocode(String address) async {
  if (!mapsProxyConfigured()) throw Exception(webBlockedMessage);
  final base = mapsProxyBase.endsWith('/')
      ? mapsProxyBase.substring(0, mapsProxyBase.length - 1)
      : mapsProxyBase;
  final uri = Uri.parse('$base/api/geocode');
  // Im Tour-Modus Pflicht; wirft, wenn die Tour nichts mehr erlaubt.
  final tour = TourScope.forCall();
  if (tour == null) {
    // Adresseingabe außerhalb einer Berechnung: Tagesbudget oder öffentlich.
    final res = await _inputPost(
      uri,
      jsonEncode({'address': address, ...CatLabTrace.requestFields}),
      InputAuth.forCall(),
    );
    if (res.statusCode != 200) {
      throw Exception('Proxy error HTTP ${res.statusCode}');
    }
    return jsonDecode(res.body) as Map<String, dynamic>;
  }
  final res = await _post(
    uri,
    jsonEncode({
      'address': address,
      ...CatLabTrace.requestFields,
      ...tour.fields,
    }),
    extraHeaders: tour.headers,
  ).timeout(proxyRequestTimeout);
  if (res.statusCode != 200) {
    TourScope.recordRejection(tour, res.statusCode, _tryJson(res.body));
    throw Exception('Proxy error HTTP ${res.statusCode}');
  }
  return jsonDecode(res.body) as Map<String, dynamic>;
}

/// Eingabe-Aufruf (Autocomplete, Geocoding außerhalb einer Tour).
///
/// Angemeldet ([input] gesetzt): mit Token; der Proxy zählt gegen das
/// Tagesbudget. Eine Ablehnung oder ein Netzfehler wird zu [InputFailure] –
/// es gibt KEINEN zweiten Versuch ohne Token. Eine Antwort aus einer
/// inzwischen beendeten Anmeldung wird verworfen.
///
/// Öffentlich ([input] null): wie bisher, ohne Token.
Future<http.Response> _inputPost(Uri uri, String body, InputCall? input) async {
  final http.Response res;
  try {
    res = await _post(uri, body, extraHeaders: input?.headers ?? const {})
        .timeout(proxyRequestTimeout);
  } catch (_) {
    if (input == null) rethrow;
    InputAuth.checkCurrent(input);
    throw InputAuth.report(const InputFailure(InputFailureKind.network));
  }
  if (input != null) {
    InputAuth.checkCurrent(input);
    if (res.statusCode != 200) {
      throw InputAuth.report(
          InputFailure.fromResponse(res.statusCode, _tryJson(res.body)));
    }
  }
  return res;
}

Object? _tryJson(String body) {
  try {
    return jsonDecode(body);
  } catch (_) {
    return null;
  }
}

Future<Map<String, dynamic>> proxyReverseGeocode(
  double latitude,
  double longitude,
) async {
  if (!mapsProxyConfigured()) throw Exception(webBlockedMessage);
  final base = mapsProxyBase.endsWith('/')
      ? mapsProxyBase.substring(0, mapsProxyBase.length - 1)
      : mapsProxyBase;
  final uri = Uri.parse('$base/api/geocode');
  final res = await _inputPost(
    uri,
    jsonEncode(
      {'lat': latitude, 'lng': longitude, ...CatLabTrace.requestFields},
    ),
    InputAuth.forCall(),
  );
  if (res.statusCode != 200) {
    throw Exception('Proxy error HTTP ${res.statusCode}');
  }
  return jsonDecode(res.body) as Map<String, dynamic>;
}

Future<Map<String, dynamic>> proxyAutocomplete({
  required String input,
  required String sessionToken,
  String language = 'de',
  double? latitude,
  double? longitude,
  int? radiusMeters,
}) async {
  if (!mapsProxyConfigured()) throw Exception(webBlockedMessage);
  final base = mapsProxyBase.endsWith('/')
      ? mapsProxyBase.substring(0, mapsProxyBase.length - 1)
      : mapsProxyBase;
  final uri = Uri.parse('$base/api/autocomplete');
  final res = await _inputPost(
    uri,
    jsonEncode({
      'input': input,
      'sessiontoken': sessionToken,
      'language': language,
      if (latitude != null && longitude != null)
        'location': '$latitude,$longitude',
      if (radiusMeters != null) 'radius': radiusMeters,
      ...CatLabTrace.requestFields,
    }),
    InputAuth.forCall(),
  );
  if (res.statusCode != 200) {
    throw Exception('Proxy error HTTP ${res.statusCode}');
  }
  return jsonDecode(res.body) as Map<String, dynamic>;
}

/// Der Proxy ist in diesem Build nicht eingerichtet (kein MAPS_PROXY_BASE).
class ProxyNotConfiguredException implements Exception {
  const ProxyNotConfiguredException();
}

/// POST /api/account/bootstrap mit dem Supabase-Zugangstoken.
///
/// Schickt bewusst einen leeren Körper: Nutzer, Konto und Plan bestimmt allein
/// der Proxy anhand des geprüften Tokens. Liefert Status und (falls lesbar)
/// den JSON-Körper; die Bewertung übernimmt der Aufrufer.
Future<({int status, Object? body})> proxyAccountBootstrap(
        String accessToken) =>
    proxyAuthedPost('/api/account/bootstrap', const {}, accessToken);

/// POST an einen geschützten Proxy-Endpunkt mit Bearer-Token.
/// Liefert Status und (falls lesbar) den JSON-Körper.
Future<({int status, Object? body})> proxyAuthedPost(
    String path, Map<String, Object?> body, String accessToken) async {
  if (!mapsProxyConfigured()) throw const ProxyNotConfiguredException();
  final base = mapsProxyBase.endsWith('/')
      ? mapsProxyBase.substring(0, mapsProxyBase.length - 1)
      : mapsProxyBase;
  final res = await _post(
    Uri.parse('$base$path'),
    jsonEncode(body),
    extraHeaders: {'Authorization': 'Bearer $accessToken'},
  ).timeout(proxyRequestTimeout);
  return (status: res.statusCode, body: _tryJson(res.body));
}

/// Proxy helper: POST /api/directions with { origin, destination, waypoints }
Future<Map<String, dynamic>> proxyDirections({
  required String origin,
  required String destination,
  List<String>? waypoints,
  String mode = 'driving',
  String departureTime = 'now',
  bool optimize = false,
  bool avoidFerries = false,
  bool alternatives = false,
}) async {
  if (!mapsProxyConfigured()) throw Exception(webBlockedMessage);
  final base = mapsProxyBase.endsWith('/')
      ? mapsProxyBase.substring(0, mapsProxyBase.length - 1)
      : mapsProxyBase;
  final uri = Uri.parse('$base/api/directions');
  final payload = {
    'origin': origin,
    'destination': destination,
    'waypoints': waypoints ?? [],
    'mode': mode,
    'departure_time': departureTime,
    'optimize': optimize,
    'alternatives': alternatives,
    if (avoidFerries) 'avoid': 'ferries',
    // Nur die Kennung der laufenden Berechnung, damit der Proxy die Aufrufe
    // zusammenfassen kann. Der Proxy ignoriert die Felder fuer Google.
    ...CatLabTrace.requestFields,
  };
  // Im Tour-Modus Pflicht; wirft, wenn die Tour nichts mehr erlaubt.
  final tour = TourScope.forCall();
  if (tour != null) payload.addAll(tour.fields);
  final res = await _post(uri, jsonEncode(payload),
          extraHeaders: tour?.headers ?? const {})
      .timeout(proxyRequestTimeout);
  if (res.statusCode != 200) {
    if (tour != null) {
      TourScope.recordRejection(tour, res.statusCode, _tryJson(res.body));
    }
    throw Exception('Proxy error HTTP ${res.statusCode}');
  }
  return jsonDecode(res.body) as Map<String, dynamic>;
}
