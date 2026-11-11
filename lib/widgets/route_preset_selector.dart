import 'package:flutter/material.dart';

import '../models/route_preset.dart';

/// Kompakte Auswahl gespeicherter Routen-Vorlagen.
///
/// Zugeklappt:  🛣️ Routen-Vorlage · 3 gespeichert ▾
/// Aufgeklappt: Liste mit "Einsetzen", "Umgekehrt" und Löschen, darunter
/// "Aktuelle Stopps als Vorlage speichern".
class RoutePresetSelector extends StatefulWidget {
  final List<RoutePreset> presets;

  /// Vorlage in Fahrtrichtung bzw. umgekehrt übernehmen.
  final void Function(RoutePreset preset, {required bool reverse}) onApply;

  final ValueChanged<RoutePreset> onDelete;

  /// Aktuelle Zwischenstopps als neue Vorlage sichern.
  final void Function(String name) onSaveCurrent;

  /// Wie viele Zwischenstopps gerade gesetzt sind (steuert das Speichern).
  final int currentStopCount;

  const RoutePresetSelector({
    super.key,
    required this.presets,
    required this.onApply,
    required this.onDelete,
    required this.onSaveCurrent,
    required this.currentStopCount,
  });

  @override
  State<RoutePresetSelector> createState() => _RoutePresetSelectorState();
}

class _RoutePresetSelectorState extends State<RoutePresetSelector> {
  bool _open = false;

  String get _summary {
    final n = widget.presets.length;
    if (n == 0) return 'Keine';
    if (n == 1) return '1 gespeichert';
    return '$n gespeichert';
  }

  Future<void> _askAndSave() async {
    final ctl = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Vorlage speichern'),
        content: TextField(
          controller: ctl,
          autofocus: true,
          decoration: const InputDecoration(
            labelText: 'Name',
            hintText: 'z. B. GR → AT · östlich um Ex-Jugoslawien',
          ),
          onSubmitted: (v) => Navigator.of(ctx).pop(v.trim()),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Abbrechen'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(ctl.text.trim()),
            child: const Text('Speichern'),
          ),
        ],
      ),
    );
    if (name != null && name.isNotEmpty) widget.onSaveCurrent(name);
  }

  Future<void> _confirmDelete(RoutePreset preset) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Vorlage löschen?'),
        content: Text(preset.name),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Abbrechen'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Löschen'),
          ),
        ],
      ),
    );
    if (ok == true) widget.onDelete(preset);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final active = widget.presets.isNotEmpty;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        InkWell(
          onTap: () => setState(() => _open = !_open),
          borderRadius: BorderRadius.circular(6),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 4),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Symbol statt Emoji: die übrigen Abschnitte verwenden
                // durchgehend Symbole, ein buntes Emoji fällt heraus.
                Icon(Icons.alt_route_rounded,
                    size: 16,
                    color: active ? theme.colorScheme.primary : null),
                const SizedBox(width: 6),
                Flexible(
                  child: Text(
                    'Routen-Vorlage · $_summary',
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(
                      fontWeight: active ? FontWeight.w600 : FontWeight.normal,
                      color: active ? theme.colorScheme.primary : null,
                    ),
                  ),
                ),
                Icon(
                  _open ? Icons.arrow_drop_up : Icons.arrow_drop_down,
                  size: 18,
                  color: active ? theme.colorScheme.primary : null,
                ),
              ],
            ),
          ),
        ),
        if (_open)
          Container(
            margin: const EdgeInsets.only(bottom: 4),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(8),
              border:
                  Border.all(color: theme.dividerColor.withValues(alpha: 0.6)),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (widget.presets.isEmpty)
                  Padding(
                    padding: const EdgeInsets.all(10),
                    child: Text(
                      'Noch keine Vorlage. Zwischenstopps setzen und unten '
                      'speichern – dann steht die Strecke jederzeit auf '
                      'Knopfdruck bereit.',
                      style: theme.textTheme.bodySmall,
                    ),
                  ),
                for (final preset in widget.presets)
                  Padding(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(preset.name,
                            style: theme.textTheme.bodyMedium
                                ?.copyWith(fontWeight: FontWeight.w600)),
                        const SizedBox(height: 2),
                        Text(preset.preview, style: theme.textTheme.bodySmall),
                        const SizedBox(height: 4),
                        Wrap(
                          spacing: 6,
                          runSpacing: 4,
                          crossAxisAlignment: WrapCrossAlignment.center,
                          children: [
                            OutlinedButton.icon(
                              style: OutlinedButton.styleFrom(
                                visualDensity: VisualDensity.compact,
                              ),
                              onPressed: () =>
                                  widget.onApply(preset, reverse: false),
                              icon: const Icon(Icons.play_arrow, size: 16),
                              label: const Text('Einsetzen'),
                            ),
                            OutlinedButton.icon(
                              style: OutlinedButton.styleFrom(
                                visualDensity: VisualDensity.compact,
                              ),
                              onPressed: () =>
                                  widget.onApply(preset, reverse: true),
                              icon: const Icon(Icons.swap_horiz, size: 16),
                              label: const Text('Umgekehrt'),
                            ),
                            IconButton(
                              tooltip: 'Vorlage löschen',
                              visualDensity: VisualDensity.compact,
                              onPressed: () => _confirmDelete(preset),
                              icon: const Icon(Icons.delete_outline, size: 18),
                            ),
                          ],
                        ),
                        const Divider(height: 12),
                      ],
                    ),
                  ),
                Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                  child: OutlinedButton.icon(
                    onPressed:
                        widget.currentStopCount > 0 ? _askAndSave : null,
                    icon: const Icon(Icons.bookmark_add_outlined, size: 18),
                    label: Text(widget.currentStopCount > 0
                        ? 'Aktuelle ${widget.currentStopCount} Stopps als Vorlage speichern'
                        : 'Zum Speichern zuerst Zwischenstopps setzen'),
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}
