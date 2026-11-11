/// Client key supplied at build/run time. Never commit a real key here.
const String GOOGLE_MAPS_API_KEY =
    String.fromEnvironment('GOOGLE_MAPS_API_KEY');

/// Debug helper: reports only whether the key is present and its length.
/// Do NOT print the key itself.
String googleMapsApiKeyInfo() {
  if (GOOGLE_MAPS_API_KEY.isEmpty) return 'GOOGLE_MAPS_API_KEY=empty';
  return 'GOOGLE_MAPS_API_KEY length=${GOOGLE_MAPS_API_KEY.length}';
}
