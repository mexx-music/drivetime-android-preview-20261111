import 'dart:convert';

/// Öffentliche Supabase-Werte für den Login, zur Build-Zeit per
/// `--dart-define=SUPABASE_URL=… --dart-define=SUPABASE_PUBLISHABLE_KEY=…`.
///
/// Beide Werte sind öffentlich: jeder Browser bekommt sie ohnehin zu sehen.
/// Ein geheimer Schlüssel (Service-Role, `sb_secret_…`) darf nie hier landen –
/// er würde jedem Besucher Vollzugriff auf die Datenbank geben. Deshalb wird
/// ein solcher Schlüssel abgewiesen, statt ihn zu benutzen.
///
/// Fehlen die Werte, ist der Login schlicht ausgeschaltet und die App läuft
/// genau wie bisher.
class AuthConfig {
  const AuthConfig({required this.url, required this.publishableKey});

  final String url;
  final String publishableKey;

  static const String _urlDefine = String.fromEnvironment('SUPABASE_URL');
  static const String _keyDefine =
      String.fromEnvironment('SUPABASE_PUBLISHABLE_KEY');

  /// null = Login nicht eingerichtet. Wirft bei einer unsicheren Einstellung.
  static AuthConfig? fromEnvironment() => parse(_urlDefine, _keyDefine);

  static AuthConfig? parse(String url, String key) {
    url = url.trim();
    key = key.trim();
    if (url.isEmpty && key.isEmpty) return null;
    if (url.isEmpty || key.isEmpty) {
      throw ArgumentError('SUPABASE_URL und SUPABASE_PUBLISHABLE_KEY nur zusammen');
    }
    final uri = Uri.tryParse(url);
    final local = uri != null && (uri.host == 'localhost' || uri.host == '127.0.0.1');
    if (uri == null ||
        uri.host.isEmpty ||
        !(uri.scheme == 'https' || (local && uri.scheme == 'http'))) {
      throw ArgumentError('SUPABASE_URL muss eine https-Adresse sein');
    }
    if (!isPublicKey(key)) {
      // Der Schlüssel selbst kommt bewusst nicht in die Meldung.
      throw ArgumentError('SUPABASE_PUBLISHABLE_KEY ist kein öffentlicher Schlüssel');
    }
    return AuthConfig(url: url, publishableKey: key);
  }

  /// Nur der neue Publishable Key oder der alte anon-JWT sind erlaubt.
  static bool isPublicKey(String key) {
    if (key.startsWith('sb_publishable_')) return true;
    if (key.startsWith('sb_secret_')) return false;
    final parts = key.split('.');
    if (parts.length != 3) return false;
    try {
      final payload = jsonDecode(
          utf8.decode(base64Url.decode(base64Url.normalize(parts[1]))));
      return payload is Map && payload['role'] == 'anon';
    } catch (_) {
      return false;
    }
  }
}
