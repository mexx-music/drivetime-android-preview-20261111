/// Kartenbeschriftung in lesbarer Schrift (Experiment MapLibre).
///
/// Vektorkacheln (OpenMapTiles-Schema, z. B. OpenFreeMap) enthalten zu jedem
/// Ort mehrere Namen. Der Stil wird so umgeschrieben, dass jede Beschriftung,
/// die einen Namen zeigt, ihn in lateinischer Schrift ausgibt:
///
///   Länder, Hauptstädte, Meere: deutsch → lateinisch → international → lokal
///   übrige Orte, Straßen:       lateinisch → international → lokal
///
/// Thessaloníki statt Θεσσαλονίκη, Belgrad statt Београд, Smederevo statt
/// Смедерево. Die Originalschrift erscheint nur, wenn es keine lateinische
/// Form gibt. Nummern (Straßen-`ref`) bleiben unverändert.
library;

/// Deutsch zuerst – für Länder, Bundesländer, Hauptstädte und Meere
/// („Serbien“, „Belgrad“, „Prag“, „Mittelmeer“).
const List<Object> germanFirstName = [
  'coalesce',
  ['get', 'name:de'],
  ['get', 'name_de'],
  ['get', 'name:latin'],
  ['get', 'name_int'],
  ['get', 'name:en'],
  ['get', 'name_en'],
  ['get', 'name'],
];

/// Lateinische Schreibweise zuerst – für alle übrigen Orte und Straßen.
/// Die deutschen Namen kleinerer Orte im Osten sind oft historisch
/// („Semendria“ für Smederevo, „Großbetschkerek“ für Zrenjanin) und helfen
/// heute keinem Fahrer; `name:latin` liefert die lokale Schreibweise in
/// lateinischer Schrift („Smederevo“, „Thessaloníki“, „Plovdiv“).
const List<Object> latinFirstName = [
  'coalesce',
  ['get', 'name:latin'],
  ['get', 'name_int'],
  ['get', 'name:en'],
  ['get', 'name_en'],
  ['get', 'name'],
];

/// Für Ortsbeschriftungen: Land/Bundesland/Hauptstadt deutsch, sonst lateinisch.
const List<Object> placeNameExpression = [
  'case',
  [
    'any',
    ['==', ['get', 'class'], 'country'],
    ['==', ['get', 'class'], 'state'],
    ['==', ['get', 'class'], 'continent'],
    ['==', ['get', 'capital'], 2],
  ],
  germanFirstName,
  latinFirstName,
];

/// true, wenn ein `text-field` einen Ortsnamen ausgibt (nicht nur `ref`).
bool showsName(Object? textField) {
  if (textField is String) return textField.contains('{name');
  if (textField is List) {
    return textField.any((e) =>
        (e is String && (e == 'name' || e.startsWith('name:') || e.startsWith('name_'))) ||
        showsName(e));
  }
  return false;
}

/// Ausdruck je Ebene: Orte nach Art, Gewässer deutsch, Rest lateinisch.
List<Object> nameExpressionFor(Map<String, dynamic> layer) => switch (layer['source-layer']) {
      'place' => placeNameExpression,
      'water_name' => germanFirstName,
      _ => latinFirstName,
    };

/// Kopie des Stils mit lesbaren Namen in allen Namens-Beschriftungen.
Map<String, dynamic> latinizeStyle(Map<String, dynamic> style) {
  final layers = <Map<String, dynamic>>[];
  for (final raw in (style['layers'] as List).cast<Map<String, dynamic>>()) {
    final layer = Map<String, dynamic>.of(raw);
    final layout = layer['layout'];
    if (layout is Map && showsName(layout['text-field'])) {
      layer['layout'] = Map<String, dynamic>.of(layout.cast<String, dynamic>())
        ..['text-field'] = nameExpressionFor(layer);
    }
    layers.add(layer);
  }
  return Map<String, dynamic>.of(style)..['layers'] = layers;
}
