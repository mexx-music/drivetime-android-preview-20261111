import 'package:driverroute_eta/logic/time_budget.dart';
import 'package:driverroute_eta/widgets/duration_input.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Verbleibende Zeit wird in bisherige Zeit für ETA umgerechnet', () {
    expect(TimeBudget.elapsedFromRemaining(480, 600), 120);
    expect(TimeBudget.elapsedFromRemaining(720, 900), 180);
    expect(TimeBudget.elapsedFromRemaining(999, 540), 0);
    expect(TimeBudget.elapsedFromRemaining(-1, 780), 780);
  });

  testWidgets('Stunden und Minuten sind direkt eingebbar', (tester) async {
    var selected = 600;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: StatefulBuilder(builder: (context, setState) {
          return DurationInput(
            minutes: selected,
            maxMinutes: 600,
            onChanged: (value) => setState(() => selected = value),
          );
        }),
      ),
    ));

    expect(find.text('Stunden'), findsOneWidget);
    expect(find.text('Minuten'), findsOneWidget);
    await tester.enterText(find.byType(TextField).first, '8');
    await tester.pump();
    expect(selected, 480);
    await tester.enterText(find.byType(TextField).last, '30');
    await tester.pump();
    expect(selected, 510);
    expect(tester.takeException(), isNull);
  });
}
