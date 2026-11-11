import 'package:driverroute_eta/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  Future<void> pumpAtSize(
    WidgetTester tester, {
    required double width,
    required double height,
  }) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = Size(width, height);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);

    await tester.pumpWidget(const DriverRouteApp());
    await tester.pumpAndSettle();
  }

  testWidgets('Desktop zeigt Eingabe und Ergebnisvorschau nebeneinander',
      (tester) async {
    await pumpAtSize(tester, width: 1280, height: 800);

    expect(find.text('Tour vorbereiten'), findsOneWidget);
    expect(find.text('Deine Tourübersicht'), findsOneWidget);
    expect(find.text('ROUTE PLANEN'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Smartphone bleibt bei einer kompakten Spalte', (tester) async {
    await pumpAtSize(tester, width: 390, height: 844);

    expect(find.text('Tour vorbereiten'), findsOneWidget);
    expect(find.text('Deine Tourübersicht'), findsNothing);
    expect(find.text('ROUTE PLANEN'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Querformat nutzt ab 860 Pixeln die Ergebnisfläche',
      (tester) async {
    await pumpAtSize(tester, width: 900, height: 600);

    expect(find.text('Deine Tourübersicht'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Mehrere Zwischenstopps lassen sich hinzufügen und sortieren',
      (tester) async {
    await pumpAtSize(tester, width: 390, height: 844);
    await tester.ensureVisible(find.text('ZWISCHENSTOPPS'));
    await tester.tap(find.text('ZWISCHENSTOPPS'));
    await tester.pumpAndSettle();

    final stopField = find.byWidgetPredicate((widget) =>
        widget is TextField &&
        widget.decoration?.labelText == 'Adresse oder Ort eingeben');
    final addButton = find.text('Zwischenstopp hinzufügen');

    await tester.enterText(stopField, 'Sofia, Bulgarien');
    await tester.ensureVisible(addButton);
    await tester.tap(addButton);
    await tester.pumpAndSettle();
    expect(find.text('1. Sofia, Bulgarien'), findsOneWidget);

    await tester.enterText(stopField, 'Sibiu, Rumänien');
    await tester.ensureVisible(addButton);
    await tester.tap(addButton);
    await tester.pumpAndSettle();
    expect(find.text('2. Sibiu, Rumänien'), findsOneWidget);

    await tester.ensureVisible(find.text('2. Sibiu, Rumänien'));
    await tester.tap(find.byTooltip('Nach oben').last);
    await tester.pumpAndSettle();
    expect(find.text('1. Sibiu, Rumänien'), findsOneWidget);
    expect(find.text('2. Sofia, Bulgarien'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Routen-Vorlage: einsetzen und umgekehrt einsetzen',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    await pumpAtSize(tester, width: 390, height: 844);
    await tester.pumpAndSettle();

    await tester.scrollUntilVisible(
      find.textContaining('Routen-Vorlage ·'),
      250,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.ensureVisible(find.textContaining('Routen-Vorlage ·'));
    await tester.pumpAndSettle();

    // Zugeklappt ist die Liste unsichtbar.
    expect(find.textContaining('Kulata → Botevgrad'), findsNothing);

    await tester.tap(find.textContaining('Routen-Vorlage ·'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Kulata → Botevgrad → Calafat → Nadlac'),
        findsOneWidget);

    // Einsetzen übernimmt die Stopps in Fahrtreihenfolge.
    await tester.ensureVisible(find.text('Einsetzen').first);
    await tester.tap(find.text('Einsetzen').first);
    await tester.pumpAndSettle();
    expect(find.textContaining('Aktuelle 4 Stopps'), findsOneWidget);

    // Auch "Umgekehrt" setzt die Strecke ein, nur in Gegenrichtung.
    // (Die Reihenfolge selbst deckt route_preset_test.dart ab.)
    await tester.ensureVisible(find.text('Umgekehrt').first);
    await tester.tap(find.text('Umgekehrt').first);
    await tester.pumpAndSettle();
    expect(find.textContaining('Aktuelle 4 Stopps'), findsOneWidget);

    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'Zeitbudget ist sichtbar und Abfahrt erst bei Aktivierung editierbar',
      (tester) async {
    await pumpAtSize(tester, width: 390, height: 844);
    await tester.scrollUntilVisible(
      find.text('ABFAHRT & ZEIT'),
      250,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.ensureVisible(find.text('ABFAHRT & ZEIT'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('ABFAHRT & ZEIT'));
    await tester.pumpAndSettle();

    // Aufgeklappt stehen die drei Werte da - aber noch keine Eingabefelder.
    expect(find.text('Fahrzeit'), findsOneWidget);
    expect(find.text('Einsatzzeit'), findsOneWidget);
    expect(find.text('Seit Lenkpause'), findsOneWidget);
    expect(find.text('Stunden'), findsNothing);
    expect(find.text('Minuten'), findsNothing);

    // Die Abfahrt steht auf Jetzt, ohne Datum und Uhrzeit anzubieten.
    expect(find.text('Jetzt'), findsOneWidget);

    // Erst ein Tipp auf den Wert öffnet die Eingabe - und nur diese eine.
    await tester.tap(find.text('Fahrzeit'));
    await tester.pumpAndSettle();
    expect(find.text('Verbleibende Fahrzeit'), findsOneWidget);
    expect(find.text('Stunden'), findsOneWidget);
    expect(find.text('Minuten'), findsOneWidget);

    // Und ein zweiter Tipp schließt sie wieder.
    await tester.tap(find.text('Fahrzeit'));
    await tester.pumpAndSettle();
    expect(find.text('Stunden'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'Fähre ist automatisch aktiv und Uhrzeit hat keinen Zahlenrad-Picker',
      (tester) async {
    await pumpAtSize(tester, width: 390, height: 844);
    await tester.scrollUntilVisible(
      find.text('FÄHRE'),
      250,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.text('FÄHRE'));
    await tester.pumpAndSettle();

    final tile = find.ancestor(
      of: find.text('Fähre automatisch vorschlagen'),
      matching: find.byType(SwitchListTile),
    );
    expect(tester.widget<SwitchListTile>(tile).value, isTrue);
    expect(find.text('Fähre wählen (Test)'), findsNothing);
    await tester.scrollUntilVisible(
      find.text('Uhrzeit wählen'),
      250,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.ensureVisible(find.text('Uhrzeit wählen'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Uhrzeit wählen'));
    await tester.pumpAndSettle();
    expect(find.byType(TimePickerDialog), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Dänemark-Alternative schaltet automatische Fähre aus',
      (tester) async {
    await pumpAtSize(tester, width: 390, height: 844);
    await tester.scrollUntilVisible(
      find.text('FÄHRE'),
      250,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.text('FÄHRE'));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.text('Alternative über Dänemark: 2 Fähren'),
      250,
      scrollable: find.byType(Scrollable).first,
    );
    await tester
        .ensureVisible(find.text('Alternative über Dänemark: 2 Fähren'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Alternative über Dänemark: 2 Fähren'));
    await tester.pumpAndSettle();

    final automatic = find.ancestor(
      of: find.text('Fähre automatisch vorschlagen'),
      matching: find.byType(SwitchListTile),
    );
    final denmark = find.ancestor(
      of: find.text('Alternative über Dänemark: 2 Fähren'),
      matching: find.byType(SwitchListTile),
    );
    expect(tester.widget<SwitchListTile>(automatic).value, isFalse);
    expect(tester.widget<SwitchListTile>(denmark).value, isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Fährsuche wählt eine Verbindung und übersteuert Automatik',
      (tester) async {
    SharedPreferences.setMockInitialValues({
      'ferries_json_cache_v2':
          '{"routes":[{"id":"igou_bari_grimaldi","name":"Igoumenitsa–Bari (Grimaldi)","from":"Igoumenitsa","to":"Bari","operators":["Grimaldi"],"duration_hours":10,"departures_local":[],"tz":"Europe/Athens","region":"Griechenland/Italien","active":true}]}',
    });
    await pumpAtSize(tester, width: 390, height: 844);
    await tester.scrollUntilVisible(
      find.text('FÄHRE'),
      250,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.text('FÄHRE'));
    await tester.pumpAndSettle();

    final search = find.byWidgetPredicate((widget) =>
        widget is TextField &&
        widget.decoration?.labelText == 'Fähre manuell suchen');
    await tester.ensureVisible(search);
    await tester.enterText(search, 'Igoumenitsa Bari');
    await tester.pumpAndSettle();
    final route = find.text('Igoumenitsa–Bari (Grimaldi)');
    await tester.ensureVisible(route);
    await tester.tap(route);
    await tester.pumpAndSettle();

    expect(find.text('Manuell gewählt – statt automatischem Vorschlag'),
        findsOneWidget);
    final automatic = find.ancestor(
      of: find.text('Fähre automatisch vorschlagen'),
      matching: find.byType(SwitchListTile),
    );
    expect(tester.widget<SwitchListTile>(automatic).value, isFalse);
    expect(tester.takeException(), isNull);
  });
}
