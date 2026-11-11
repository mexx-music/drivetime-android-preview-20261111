import 'package:flutter_test/flutter_test.dart';
import 'package:driverroute_eta/services/catlab_trace.dart';

void main() {
  setUp(CatLabTrace.end);
  tearDown(CatLabTrace.end);

  test('ohne laufende Berechnung wird nichts mitgeschickt', () {
    expect(CatLabTrace.workUnitId, isNull);
    expect(CatLabTrace.requestFields, isEmpty);
  });

  test('eine Berechnung bekommt eine Kennung, die alle Aufrufe teilen', () {
    CatLabTrace.begin();
    final ersterAufruf = CatLabTrace.requestFields;
    final zweiterAufruf = CatLabTrace.requestFields;

    expect(ersterAufruf['cc_work_unit'], isNotNull);
    expect(zweiterAufruf['cc_work_unit'], ersterAufruf['cc_work_unit'],
        reason: 'beide Aufrufe gehören zur selben Berechnung');
    expect(ersterAufruf['cc_work_kind'], 'route');
  });

  test('jede Berechnung bekommt eine eigene Kennung', () {
    CatLabTrace.begin();
    final erste = CatLabTrace.workUnitId;
    CatLabTrace.end();
    CatLabTrace.begin();
    expect(CatLabTrace.workUnitId, isNot(erste));
  });

  test('die Kennung ist eine gültige UUID', () {
    CatLabTrace.begin();
    expect(
      CatLabTrace.workUnitId,
      matches(RegExp(
          r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$')),
      reason: 'der Proxy nimmt nur echte UUIDs an',
    );
  });

  test('eine Fährroute wird eigens gekennzeichnet', () {
    CatLabTrace.begin();
    expect(CatLabTrace.kind, 'route');
    CatLabTrace.markFerry();
    expect(CatLabTrace.requestFields['cc_work_kind'], 'route_ferry');
  });

  test('mehrfaches Kennzeichnen bleibt bei route_ferry', () {
    CatLabTrace.begin();
    CatLabTrace.markFerry();
    CatLabTrace.markFerry();
    expect(CatLabTrace.kind, 'route_ferry');
  });

  test('die Kennung bleibt beim Kennzeichnen dieselbe', () {
    CatLabTrace.begin();
    final vorher = CatLabTrace.workUnitId;
    CatLabTrace.markFerry();
    expect(CatLabTrace.workUnitId, vorher,
        reason: 'sonst zerfiele die Berechnung in zwei Arbeitseinheiten');
  });

  test('die nächste Berechnung startet wieder als Straßenroute', () {
    CatLabTrace.begin();
    CatLabTrace.markFerry();
    CatLabTrace.end();
    CatLabTrace.begin();
    expect(CatLabTrace.kind, 'route',
        reason: 'eine Fährroute darf nicht auf die folgende abfärben');
  });

  test('ohne laufende Berechnung kennzeichnet markFerry nichts', () {
    CatLabTrace.markFerry();
    expect(CatLabTrace.requestFields, isEmpty);
  });

  test('nach dem Ende gehören Aufrufe zu keiner Berechnung mehr', () {
    CatLabTrace.begin();
    CatLabTrace.markFerry();
    CatLabTrace.end();
    expect(CatLabTrace.workUnitId, isNull);
    expect(CatLabTrace.requestFields, isEmpty);
    expect(CatLabTrace.kind, 'route', reason: 'auch die Gattung wird zurückgesetzt');
  });

  test('mitgeschickt wird nur Kennung und Gattung, sonst nichts', () {
    CatLabTrace.begin();
    expect(CatLabTrace.requestFields.keys.toSet(),
        {'cc_work_unit', 'cc_work_kind'});
  });
}
