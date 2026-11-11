import 'package:flutter/services.dart' show rootBundle;
import 'package:shared_preferences/shared_preferences.dart';

import '../models/ferry_route.dart';

class FerryScheduleLoader {
  static const _cacheKey = 'ferries_json_cache_v2';
  static const _assetPath = 'assets/fahrplaene/ferries.json';

  static Future<(String source, List<FerryRoute> routes)> load() async {
    final prefs = await SharedPreferences.getInstance();
    final cached = prefs.getString(_cacheKey);
    if (cached != null && cached.trim().isNotEmpty) {
      return ('Cache', FerryRoute.listFromJson(cached));
    }
    final raw = await rootBundle.loadString(_assetPath);
    return ('Asset', FerryRoute.listFromJson(raw));
  }

  static Future<void> saveToCache(String jsonRaw) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_cacheKey, jsonRaw);
  }
}
