import 'package:flutter/material.dart';

import '../models/ferry_route.dart';

/// Ein kompakter Dialog zur Bestätigung einer automatisch erkannten Fähre.
/// Liefert bei Bestätigung eine Map mit den Keys 'direction' und 'departure',
/// bei Ignorieren `null`.
class FerrySelectionDialog extends StatefulWidget {
  final FerryRoute route;

  const FerrySelectionDialog({super.key, required this.route});

  @override
  State<FerrySelectionDialog> createState() => _FerrySelectionDialogState();
}

class _FerrySelectionDialogState extends State<FerrySelectionDialog> {
  late String _selectedDirection;
  late String _selectedDeparture;

  List<String> _allDepartures(FerryRoute route) {
    final values = <String>{
      ...route.departuresLocal,
      ...route.departuresByWeekday.values.expand((times) => times),
    }.toList()
      ..sort();
    return values;
  }

  // --- helper: build two directions from route.from/to or fallback to name ---
  List<String> _buildDirections(FerryRoute r) {
    String from = r.from.trim();
    String to = r.to.trim();
    if (from.isEmpty || to.isEmpty) {
      final n = r.name.trim();
      final parts = n.split(RegExp(r'\s*[–-]\s*'));
      if (parts.length == 2) {
        from = from.isEmpty ? parts[0].trim() : from;
        to = to.isEmpty ? parts[1].trim() : to;
      }
    }
    final d1 = '$from–$to';
    final d2 = '$to–$from';
    // deduplicate and filter empty
    return {d1, d2}
        .where((e) => e.replaceAll('–', '').trim().isNotEmpty)
        .toList();
  }

  @override
  void initState() {
    super.initState();
    final dirs = _buildDirections(widget.route);
    _selectedDirection = dirs.isNotEmpty ? dirs.first : '';
    final deps = _allDepartures(widget.route);
    _selectedDeparture = deps.isNotEmpty ? deps.first : '';
  }

  @override
  Widget build(BuildContext context) {
    final directions = _buildDirections(widget.route);
    final departures = _allDepartures(widget.route);

    // If no directions were found, show a simple dialog telling the user.
    if (directions.isEmpty) {
      return AlertDialog(
        title: const Text('🚢 Erkannte Fähre'),
        content: const Text('Keine Richtungen verfügbar.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, null),
              child: const Text('Schließen'))
        ],
      );
    }

    final canConfirm =
        _selectedDirection.isNotEmpty && _selectedDeparture.isNotEmpty;

    return AlertDialog(
      title: const Text('🚢 Erkannte Fähre'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
              'Automatisch erkannt: ${widget.route.name} (${widget.route.operators.join(', ')})'),
          const SizedBox(height: 12),
          Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('Richtung'),
              ...directions.map((d) => RadioListTile<String>(
                    value: d,
                    groupValue: _selectedDirection,
                    onChanged: (v) {
                      if (v != null) setState(() => _selectedDirection = v);
                    },
                    title: Text(d),
                    dense: true,
                    visualDensity: VisualDensity.compact,
                  )),
              const SizedBox(height: 12),
              const Text('Abfahrt'),
              DropdownButton<String>(
                value: (departures.contains(_selectedDeparture))
                    ? _selectedDeparture
                    : null,
                isExpanded: true,
                items: departures
                    .map((d) => DropdownMenuItem(value: d, child: Text(d)))
                    .toList(),
                onChanged: (v) {
                  if (v != null) setState(() => _selectedDeparture = v);
                },
              ),
            ],
          ),
          const SizedBox(height: 6),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(null),
          child: const Text('Ignorieren'),
        ),
        FilledButton(
          onPressed: canConfirm
              ? () {
                  Navigator.of(context).pop({
                    'direction': _selectedDirection,
                    'departure': _selectedDeparture,
                  });
                }
              : null,
          child: const Text('Bestätigen'),
        ),
      ],
    );
  }
}
