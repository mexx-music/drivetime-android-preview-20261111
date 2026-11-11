// NOTE: Dieser Widget wurde in `main.dart` integriert; die alte Datei wird als Placeholder beibehalten
// um mögliche Importfehler zu vermeiden. Entfernt sensible Daten und die alte Logik.

import 'package:flutter/material.dart';
import 'package:driverroute_eta/widgets/ferry_selection_dialog.dart';
import '../models/ferry_route.dart';

class RouteInputWidget extends StatefulWidget {
  final FerryRoute? detectedRoute;

  const RouteInputWidget({super.key, this.detectedRoute});

  @override
  State<RouteInputWidget> createState() => _RouteInputWidgetState();
}

class _RouteInputWidgetState extends State<RouteInputWidget> {
  // local test state to store chosen ferry selection
  String _selectedFerryDirection = '';
  String _selectedFerryDeparture = '';

  @override
  Widget build(BuildContext context) {
    // Use the optional detectedRoute passed into the widget.
    final detectedRoute = widget.detectedRoute;

    return ElevatedButton(
      onPressed: () async {
        if (detectedRoute == null) return;
        final result = await showDialog<Map<String, String>?>(
          context: context,
          builder: (_) => FerrySelectionDialog(route: detectedRoute),
        );
        if (result != null) {
          onFerrySelectionConfirmed(
            direction: result['direction']!,
            departure: result['departure']!,
          );
        }
      },
      child: const Text('Fähre wählen (Test)'),
    );
  }

  void onFerrySelectionConfirmed(
      {required String direction, required String departure}) {
    setState(() {
      _selectedFerryDirection = direction;
      _selectedFerryDeparture = departure;
    });
    // TODO: an deine ETA-/Segment-Logik weiterreichen (keine Refactorings):
    // etaEngine.applyFerrySelection(direction: direction, departure: departure);
  }
}

// Minimaler, nicht automatisch aufgerufener Helfer, der den geforderten Dialog-Call
// enthält. Er wird hier nur deklariert (kein Aufruf), damit Build unverändert bleibt.
Future<void> _maybeShowFerryDialog(
    BuildContext context,
    dynamic detectedRoute,
    Function({required String direction, required String departure})
        onFerrySelectionConfirmed) async {
  // Der Nutzer wünschte exakt diesen Block (angepasst auf vorhandene Namen):
  final result = await showDialog<Map<String, String>?>(
    context: context,
    builder: (_) => FerrySelectionDialog(route: detectedRoute),
  );

  if (result != null) {
    final chosenDirection = result['direction']!;
    final chosenDeparture = result['departure']!;
    // Weiterleitung an die erwartete Callback-API
    onFerrySelectionConfirmed(
        direction: chosenDirection, departure: chosenDeparture);
  }
}
