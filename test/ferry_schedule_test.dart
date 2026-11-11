import 'package:driverroute_eta/models/ferry_route.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('Nordfähren sind im lokalen Routenbestand enthalten', () async {
    // Browser unit tests do not serve pubspec assets through rootBundle.
    if (kIsWeb) return;
    final raw = await rootBundle.loadString('assets/fahrplaene/ferries.json');
    final routes = FerryRoute.listFromJson(raw);
    for (final id in [
      'travemalmo_finnlines',
      'malmotrav_finnlines',
      'kielgoteborg_stena',
      'goteborgkiel_stena',
    ]) {
      expect(routes.singleWhere((route) => route.id == id).active, isTrue);
    }
    expect(routes.singleWhere((route) => route.id == 'kiel_trelle_tt').active,
        isFalse);
    expect(routes.singleWhere((route) => route.id == 'trelle_kiel_tt').active,
        isFalse);
  });
}
