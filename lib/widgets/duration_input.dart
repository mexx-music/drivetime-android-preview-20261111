import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Compact numeric hours/minutes input for a remaining-time budget.
class DurationInput extends StatefulWidget {
  final int minutes;
  final int maxMinutes;
  final ValueChanged<int> onChanged;

  const DurationInput({
    super.key,
    required this.minutes,
    required this.maxMinutes,
    required this.onChanged,
  });

  @override
  State<DurationInput> createState() => _DurationInputState();
}

class _DurationInputState extends State<DurationInput> {
  late final TextEditingController _hours;
  late final TextEditingController _minutes;

  @override
  void initState() {
    super.initState();
    _hours = TextEditingController();
    _minutes = TextEditingController();
    _syncFromWidget();
  }

  @override
  void didUpdateWidget(DurationInput oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_currentMinutes != widget.minutes) _syncFromWidget();
  }

  int get _currentMinutes =>
      (int.tryParse(_hours.text) ?? 0) * 60 +
      (int.tryParse(_minutes.text) ?? 0);

  void _syncFromWidget() {
    _hours.text = (widget.minutes ~/ 60).toString();
    _minutes.text = (widget.minutes % 60).toString().padLeft(2, '0');
  }

  void _onEdit() {
    final hours = int.tryParse(_hours.text) ?? 0;
    final minutes = (int.tryParse(_minutes.text) ?? 0).clamp(0, 59);
    final value = (hours * 60 + minutes).clamp(0, widget.maxMinutes);
    widget.onChanged(value);
  }

  @override
  void dispose() {
    _hours.dispose();
    _minutes.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Row(
        children: [
          Expanded(
            child: TextField(
              controller: _hours,
              keyboardType: TextInputType.number,
              inputFormatters: [
                FilteringTextInputFormatter.digitsOnly,
                LengthLimitingTextInputFormatter(2),
              ],
              decoration: const InputDecoration(labelText: 'Stunden'),
              onChanged: (_) => _onEdit(),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: TextField(
              controller: _minutes,
              keyboardType: TextInputType.number,
              inputFormatters: [
                FilteringTextInputFormatter.digitsOnly,
                LengthLimitingTextInputFormatter(2),
              ],
              decoration: const InputDecoration(labelText: 'Minuten'),
              onChanged: (_) => _onEdit(),
            ),
          ),
        ],
      );
}
