class PortAliases {
  // Lowercase-Aliase je Hafen. Ergänzbar.
  static const Map<String, List<String>> aliases = {
    'hirtshals': ['hirtshals'],
    'kristiansand': ['kristiansand', 'krs'],
    'stavanger': ['stavanger'],
    'bergen': ['bergen'],
    'kiel': ['kiel'],
    'oslo': ['oslo'],

    'trelleborg': ['trelleborg'],
    'travemünde': [
      'travemunde',
      'travemünde',
      'travemuende',
      'lubeck travemünde',
      'lübeck-travemünde',
      'lübeck'
    ],
    'rostock': ['rostock'],
    'swinoujscie': ['swinoujscie', 'świnoujście', 'swino'],

    'grenaa': ['grenaa', 'grenå'],
    'halmstad': ['halmstad'],

    // Adria
    'ancona': ['ancona', 'porto di ancona', 'port of ancona'],
    'venezia': ['venezia', 'venice', 'venedig'],
    'bari': ['bari', 'porto di bari', 'port of bari'],
    'brindisi': ['brindisi', 'porto di brindisi', 'port of brindisi', 'br'],
    'igoumenitsa': ['igoumenitsa', 'igoumenítsa', 'igumenitsa', 'ηγουμενίτσα'],
    'patras': ['patras', 'patra', 'πάτρα', 'patrasso'],

    // Norwegen-Set usw. ist oben schon drin
  };

  static List<String> allFor(String name) {
    final key = name.toLowerCase();
    return [
      ...{key, ...(aliases[key] ?? const [])}
    ];
  }
}
