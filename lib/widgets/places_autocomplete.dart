import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:uuid/uuid.dart';

import '../services/geocoding_service.dart';
import '../services/maps_proxy.dart';

enum PlacesAutocompleteMode { inline, bottomSheet }

const int _kMinChars = 3;
const Duration _kDebounce = Duration(milliseconds: 500);

class PlacesAutocompleteField extends StatefulWidget {
  const PlacesAutocompleteField({
    super.key,
    required this.apiKey,
    required this.controller,
    this.hintText,
    this.language = 'de',
    this.country,
    this.onPlacePicked,
    this.originLat,
    this.originLng,
    this.biasRadiusMeters,
    this.includedPrimaryTypes,
    this.includeQueryPredictions = false,
    this.mode = PlacesAutocompleteMode.inline,
    this.onSearchPressed,
    this.onUserEdit,
  });

  final String apiKey;
  final TextEditingController controller;
  final String? hintText;
  final String language;
  final String? country;
  final void Function(
          String description, String placeId, double? lat, double? lng)?
      onPlacePicked;
  final PlacesAutocompleteMode mode;
  final VoidCallback? onSearchPressed;

  /// Nur echte Tastatureingaben, nicht das programmatische Setzen des Texts.
  final ValueChanged<String>? onUserEdit;

  // Bias / Filter
  final double? originLat;
  final double? originLng;
  final int? biasRadiusMeters;
  final List<String>? includedPrimaryTypes;
  final bool includeQueryPredictions;

  @override
  State<PlacesAutocompleteField> createState() =>
      _PlacesAutocompleteFieldState();
}

class _PlacesAutocompleteFieldState extends State<PlacesAutocompleteField> {
  final FocusNode _focus = FocusNode();
  Timer? _debounce;
  List<_Pred> _items = [];
  String _sessionToken = const Uuid().v4();
  bool _showInlineList = false;
  bool _autoApplied = false; // prevent repeated auto-apply

  /// Laufnummer der Vorschlagsanfragen: nur die jüngste darf die Liste
  /// setzen. Beim schnellen Tippen kann eine ältere Antwort später eintreffen.
  int _fetchSeq = 0;

  @override
  void initState() {
    super.initState();
    _focus.addListener(_handleFocus);
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _focus.removeListener(_handleFocus);
    _focus.dispose();
    super.dispose();
  }

  void _handleFocus() async {
    // on focus loss, we deliberately DO NOT auto-apply suggestions.
    if (!_focus.hasFocus) {
      // Debug: notify that no auto-apply will happen on blur
      debugPrint(
          'focus loss: no suggestion auto-applied for ${widget.hintText ?? 'field'}');
    }
  }

  String _short(String desc) {
    if (desc.isEmpty) return desc;
    final i = desc.indexOf(',');
    final base = (i > 0) ? desc.substring(0, i).trim() : desc.trim();
    return (base.length > 30) ? '${base.substring(0, 30).trimRight()}…' : base;
  }

  double? _safeRadiusMeters(int? v) {
    if (v == null) return null;
    final d = v.toDouble();
    if (d <= 0) return null;
    return d > 50000 ? 50000.0 : d;
  }

  void _onChanged(String s) {
    _debounce?.cancel();
    // user typed -> clear explicit selection mark for this controller
    _resetExplicitSelectionForController(widget.controller);
    widget.onUserEdit?.call(s);
    if (s.trim().length < _kMinChars) {
      _fetchSeq++; // laufende Anfrage überholt
      setState(() {
        _items = [];
        _showInlineList = false;
      });
      return;
    }
    _debounce = Timer(_kDebounce, () => _fetch(s));
  }

  Future<void> _fetch(String q) async {
    final seq = ++_fetchSeq;
    final Map<String, dynamic> originPart =
        (widget.originLat != null && widget.originLng != null)
            ? {
                'origin': {
                  'latitude': widget.originLat,
                  'longitude': widget.originLng,
                }
              }
            : {};

    final double? safeR = _safeRadiusMeters(widget.biasRadiusMeters);
    final Map<String, dynamic> biasPart =
        (safeR != null && widget.originLat != null && widget.originLng != null)
            ? {
                'locationBias': {
                  'circle': {
                    'center': {
                      'latitude': widget.originLat,
                      'longitude': widget.originLng,
                    },
                    'radius': safeR,
                  }
                }
              }
            : {};

    final body = <String, dynamic>{
      'input': q,
      'languageCode': widget.language,
      'sessionToken': _sessionToken,
      'includeQueryPredictions': widget.includeQueryPredictions,
      if (widget.country != null) 'regionCode': widget.country!.toUpperCase(),
      'includedPrimaryTypes':
          widget.includedPrimaryTypes ?? const ['locality', 'postal_code'],
      ...originPart,
      ...biasPart,
    };

    try {
      if (kDebugMode && mapsDirectCallsAllowed() && widget.apiKey.isEmpty) {
        debugPrint('[PlacesAutocomplete] WARNING: apiKey is empty');
      }
      late final Map<String, dynamic> data;
      if (!mapsDirectCallsAllowed()) {
        if (!mapsProxyConfigured()) return;
        data = await proxyAutocomplete(
          input: q,
          sessionToken: _sessionToken,
          language: widget.language,
          latitude: widget.originLat,
          longitude: widget.originLng,
          radiusMeters: safeR?.round(),
        );
      } else {
        final res = await http.post(
          Uri.parse('https://places.googleapis.com/v1/places:autocomplete'),
          headers: {
            'Content-Type': 'application/json',
            'X-Goog-Api-Key': widget.apiKey,
            'X-Goog-FieldMask': '*',
          },
          body: jsonEncode(body),
        );
        if (res.statusCode != 200) {
          if (kDebugMode) {
            debugPrint('[PlacesAutocomplete] HTTP ${res.statusCode}');
            debugPrint('[PlacesAutocomplete] ${res.body}');
          }
          if (mounted) {
            setState(() {
              _items = [];
              _showInlineList = false;
            });
          }
          return;
        }
        data = jsonDecode(res.body) as Map<String, dynamic>;
      }
      // Inzwischen neuer getippt oder Feld geleert: diese Antwort ist überholt.
      if (!mounted || seq != _fetchSeq) return;

      if (kDebugMode) {
        debugPrint(
          '[PlacesAutocomplete] got ${data.keys.length} keys from autocomplete response',
        );
      }
      final newItems = <_Pred>[];
      for (final suggestion in (data['suggestions'] as List? ?? const [])) {
        final pred =
            (suggestion['placePrediction'] as Map<String, dynamic>?) ?? {};
        final text = (pred['text']?['text'] ?? '').toString();
        final id = (pred['placeId'] ?? '').toString();
        if (text.isNotEmpty) newItems.add(_Pred(text, id));
      }
      for (final prediction in (data['predictions'] as List? ?? const [])) {
        final text = (prediction['description'] ?? '').toString();
        final id = (prediction['place_id'] ?? '').toString();
        if (text.isNotEmpty) newItems.add(_Pred(text, id));
      }

      if (!mounted) return;
      setState(() {
        _items = newItems;
        // reset auto-apply whenever suggestions change
        _autoApplied = false;
      });
      // publish suggestions for external consumers (e.g. main.dart fallback)
      _registerSuggestionsForController(
        widget.controller,
        _items
            .map((e) => e.description ?? '')
            .where((s) => s.isNotEmpty)
            .toList(),
      );

      if (widget.mode == PlacesAutocompleteMode.inline) {
        setState(() => _showInlineList = _items.isNotEmpty);
      } else {
        // bottomSheet mode
        if (!kIsWeb) {
          _showBottomSheet(_items);
        } else {
          // as fallback show inline on desktop/web
          setState(() => _showInlineList = _items.isNotEmpty);
        }
      }
    } catch (e) {
      if (kDebugMode) {
        // ignore: avoid_print
        print('[PlacesAutocomplete] fetch error: $e');
      }
    }
  }

  Future<void> _showBottomSheet(List<_Pred> itemsSnapshot) async {
    final res = await showModalBottomSheet<String?>(
      context: context,
      useRootNavigator: true,
      builder: (ctx) {
        return SafeArea(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 420),
            child: itemsSnapshot.isEmpty
                ? const Padding(
                    padding: EdgeInsets.all(12),
                    child: Text('Keine Vorschläge'))
                : ListView.separated(
                    itemCount: itemsSnapshot.length,
                    separatorBuilder: (_, __) => const Divider(height: 1),
                    itemBuilder: (_, i) {
                      final it = itemsSnapshot[i];
                      final desc = it.description ?? '';
                      final short = _short(desc);
                      return Material(
                        color: Colors.transparent,
                        child: InkWell(
                          onTap: () {
                            // debug immediately when tapped in bottom sheet
                            debugPrint(
                                'selected suggestion (bottomSheet): ${it.description}');
                            Navigator.of(ctx).pop(it.description);
                          },
                          child: ListTile(
                            title: Text(short),
                            subtitle: desc != short ? Text(desc) : null,
                          ),
                        ),
                      );
                    },
                  ),
          ),
        );
      },
    );

    if (res != null) {
      // res contains full description
      if (kDebugMode)
        debugPrint('[PlacesAutocomplete] bottomSheet selected: ${res}');
      await _handleSelection(res, null, null);
    }
  }

  Future<void> _handleSelection(
      String description, double? lat, double? lng) async {
    // Debug: selection happened
    debugPrint('selected suggestion: $description');
    // Write the FULL selected description into the external controller
    final full = description;
    widget.controller.value = TextEditingValue(
      text: full,
      selection: TextSelection.collapsed(offset: full.length),
    );
    // Notify listeners with full description and coords
    widget.onPlacePicked?.call(description, '', lat, lng);
    // mark explicit selection for external logic
    _markExplicitSelection(widget.controller);
    // Hide inline list and clear items to close suggestions
    if (mounted) {
      setState(() {
        _showInlineList = false;
        _items = [];
      });
    }
    try {
      FocusScope.of(context).unfocus();
    } catch (_) {}
  }

  Future<void> _pickDetailAndSelect(_Pred p) async {
    // fetch details to get lat/lng, then select
    double? lat;
    double? lng;
    // Immediate debug so we know tapping worked (sync onTap should fire this)
    debugPrint('pickDetailAndSelect invoked for: ${p.description}');
    try {
      if (!mapsDirectCallsAllowed()) {
        final resolved = await GeocodingService.resolve(p.description);
        lat = resolved.lat;
        lng = resolved.lng;
      } else {
        if (kDebugMode) {
          debugPrint(
            '[PlacesAutocomplete] fetch detail for placeId=${p.placeId}',
          );
        }
        final detRes = await http.get(
          Uri.parse(
              'https://places.googleapis.com/v1/places/${Uri.encodeComponent(p.placeId)}'),
          headers: {
            'X-Goog-Api-Key': widget.apiKey,
            'X-Goog-FieldMask': '*',
          },
        );

        if (detRes.statusCode == 200) {
          if (kDebugMode)
            debugPrint(
                '[PlacesAutocomplete] detail response length=${detRes.body.length}');
          final body = jsonDecode(detRes.body) as Map<String, dynamic>;
          final loc = body['location'] as Map<String, dynamic>?;
          if (loc != null) {
            lat = (loc['latitude'] as num).toDouble();
            lng = (loc['longitude'] as num).toDouble();
          }
        } else {
          if (kDebugMode)
            debugPrint(
                '[PlacesAutocomplete] detail HTTP ${detRes.statusCode}: ${detRes.body}');
        }
      }
    } catch (e) {
      if (kDebugMode)
        debugPrint('[PlacesAutocomplete] detail fetch exception: $e');
    }

    await _handleSelection(p.description, lat, lng);
  }

  @override
  Widget build(BuildContext context) {
    if (widget.mode == PlacesAutocompleteMode.inline) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextField(
            focusNode: _focus,
            controller: widget.controller,
            textInputAction: TextInputAction.search,
            decoration: InputDecoration(
              labelText: widget.hintText,
              suffixIcon: Row(mainAxisSize: MainAxisSize.min, children: [
                IconButton(
                    icon: const Icon(Icons.search),
                    tooltip: 'Suchen',
                    onPressed: widget.onSearchPressed),
                IconButton(
                    icon: const Icon(Icons.keyboard_hide),
                    tooltip: 'Tastatur ausblenden',
                    onPressed: () => FocusScope.of(context).unfocus()),
              ]),
            ),
            onChanged: _onChanged,
            onSubmitted: (_) async {
              // Do not auto-apply suggestions on Enter/Submit; delegate to parent search action.
              widget.onSearchPressed?.call();
            },
          ),
          if (_showInlineList && _items.isNotEmpty)
            Container(
              constraints: const BoxConstraints(maxHeight: 280),
              decoration: BoxDecoration(
                  color: Colors.white,
                  border: Border.all(color: Colors.black12),
                  borderRadius: BorderRadius.circular(8)),
              margin: const EdgeInsets.only(top: 4),
              child: ListView.separated(
                shrinkWrap: true,
                padding: EdgeInsets.zero,
                itemCount: _items.length,
                separatorBuilder: (_, __) => const Divider(height: 1),
                itemBuilder: (_, i) {
                  final it = _items[i];
                  final desc = it.description ?? '';
                  final short = _short(desc);
                  return Material(
                    color: Colors.transparent,
                    child: InkWell(
                      onTap: () async {
                        // debug immediately when tapped inline
                        debugPrint(
                            'selected suggestion (inline): ${it.description}');
                        await _pickDetailAndSelect(it);
                      },
                      child: ListTile(
                        title: Text(short),
                        subtitle: desc != short
                            ? Text(desc,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                    fontSize: 12, color: Colors.black54))
                            : null,
                      ),
                    ),
                  );
                },
              ),
            ),
        ],
      );
    }

    // bottomSheet mode: show only a TextField; results are shown in bottomSheet
    return TextField(
      focusNode: _focus,
      controller: widget.controller,
      textInputAction: TextInputAction.search,
      decoration: InputDecoration(
          labelText: widget.hintText,
          suffixIcon: Row(mainAxisSize: MainAxisSize.min, children: [
            IconButton(
                icon: const Icon(Icons.search),
                tooltip: 'Suchen',
                onPressed: widget.onSearchPressed),
            IconButton(
                icon: const Icon(Icons.keyboard_hide),
                tooltip: 'Tastatur ausblenden',
                onPressed: () => FocusScope.of(context).unfocus()),
          ])),
      onChanged: _onChanged,
      onSubmitted: (_) async {
        // Always delegate Enter/Search to the parent's onSearchPressed; do not auto-apply suggestions.
        widget.onSearchPressed?.call();
      },
    );
  }
}

// Registry to expose last suggestions per controller and explicit selection flag.
final Map<int, List<String>> _placesLastSuggestions = {};
final Map<int, bool> _placesExplicitSelection = {};

void _registerSuggestionsForController(
    TextEditingController ctl, List<String> suggestions) {
  _placesLastSuggestions[ctl.hashCode] = suggestions;
}

List<String> getSuggestionsForController(TextEditingController ctl) {
  return _placesLastSuggestions[ctl.hashCode] ?? const [];
}

void _markExplicitSelection(TextEditingController ctl) {
  _placesExplicitSelection[ctl.hashCode] = true;
}

void _resetExplicitSelectionForController(TextEditingController ctl) {
  _placesExplicitSelection[ctl.hashCode] = false;
}

bool isExplicitlySelectedForController(TextEditingController ctl) {
  return _placesExplicitSelection[ctl.hashCode] ?? false;
}

void markExplicitSelection(TextEditingController ctl) {
  _markExplicitSelection(ctl);
}

class _Pred {
  _Pred(this.description, this.placeId);
  final String description;
  final String placeId;
}
