import '../models/ferry_route.dart';

/// Finds a connection by either harbour, operator or route name. Every query
/// word must match, so "Igoumenitsa Bari" selects the correct direction pair.
class FerryRouteSearch {
  static List<FerryRoute> find(
    Iterable<FerryRoute> routes,
    String query, {
    int maxResults = 12,
  }) {
    final words = _normalize(query)
        .split(RegExp(r'\s+'))
        .where((word) => word.isNotEmpty)
        .toList();
    if (words.isEmpty) return const [];

    final matches = routes.where((route) {
      if (!route.active) return false;
      final searchable = _normalize([
        route.name,
        route.from,
        route.to,
        ...route.operators,
      ].join(' '));
      return words.every(searchable.contains);
    }).toList();
    final first = words.first;
    matches.sort((a, b) {
      final aStarts = _normalize(a.from).startsWith(first) ? 0 : 1;
      final bStarts = _normalize(b.from).startsWith(first) ? 0 : 1;
      if (aStarts != bStarts) return aStarts.compareTo(bStarts);
      return a.name.compareTo(b.name);
    });
    return matches.take(maxResults).toList();
  }

  static String _normalize(String value) => value
      .toLowerCase()
      .replaceAll('ä', 'a')
      .replaceAll('ö', 'o')
      .replaceAll('ü', 'u')
      .replaceAll('ø', 'o')
      .replaceAll('å', 'a')
      .replaceAll('é', 'e')
      .replaceAll('è', 'e')
      .replaceAll('ś', 's')
      .replaceAll('ł', 'l')
      .replaceAll('ą', 'a')
      .replaceAll('ę', 'e')
      .replaceAll('ć', 'c')
      .replaceAll('ń', 'n')
      .replaceAll('ź', 'z')
      .replaceAll('ż', 'z')
      .replaceAll('ß', 'ss')
      .replaceAll('ae', 'a')
      .replaceAll('oe', 'o')
      .replaceAll('ue', 'u')
      .replaceAll(RegExp(r'[^a-z0-9]+'), ' ')
      .trim();
}
