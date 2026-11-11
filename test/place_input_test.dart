import 'package:driverroute_eta/widgets/place_input.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('Startfeld bietet Meine Position ohne technische Meldung an',
      (tester) async {
    final controller = TextEditingController();
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PlaceInput(
            label: 'Startort',
            hint: 'Start eingeben',
            controller: controller,
            inlineAutocomplete: true,
            enableCurrentLocation: true,
          ),
        ),
      ),
    );

    expect(find.text('Meine Position'), findsOneWidget);
    expect(find.textContaining('HTTP 403'), findsNothing);
  });
}
