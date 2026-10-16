import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

import 'disk_cache.dart';
import 'radio_station.dart';

enum StationSort { nearby, popular, votes, trending }

const String _kManualStationsKey = 'radio_manual_stations';
const String _kLastLatKey = 'radio_last_lat';
const String _kLastLonKey = 'radio_last_lon';

/// Raza pentru posturile "din apropiere" (Radio Browser nu are date despre
/// puterea emițătoarelor, deci aproximăm acoperirea doar după distanță).
const double kNearbyRadiusKm = 150;

class CachedStations {
  final List<RadioStation> stations;
  final DateTime? fetchedAt;
  const CachedStations(this.stations, this.fetchedAt);
}

class RadioRepository {
  // Oglinzi publice Radio Browser — încercate pe rând.
  static const List<String> _servers = [
    'de1.api.radio-browser.info',
    'nl1.api.radio-browser.info',
    'at1.api.radio-browser.info',
    'de2.api.radio-browser.info',
  ];

  Future<List<dynamic>> _getJson(String path, Map<String, String> query) async {
    Object? lastError;
    for (final host in _servers) {
      try {
        final uri = Uri.https(host, path, query);
        final res = await http
            .get(uri, headers: {'User-Agent': kHttpUserAgent})
            .timeout(const Duration(seconds: 15));
        if (res.statusCode == 200) {
          final decoded = jsonDecode(utf8.decode(res.bodyBytes));
          if (decoded is List) return decoded;
        }
        lastError = 'HTTP ${res.statusCode}';
      } catch (e) {
        lastError = e;
      }
    }
    throw Exception('Radio Browser indisponibil: $lastError');
  }

  /// Posturile țării (cele mai ascultate) + cele cu coordonate din raza
  /// [kNearbyRadiusKm] (pot fi și peste graniță).
  Future<List<RadioStation>> fetchForArea({String? countryCode, double? lat, double? lon}) async {
    final byUuid = <String, RadioStation>{};

    void addAll(List<dynamic> raw) {
      for (final item in raw.whereType<Map>()) {
        final s = RadioStation.fromRadioBrowser(Map<String, dynamic>.from(item));
        if (s.uuid.isEmpty || s.streamUrl.isEmpty || s.name.isEmpty) continue;
        byUuid[s.uuid] = s;
      }
    }

    if (countryCode != null && countryCode.isNotEmpty) {
      addAll(await _getJson('/json/stations/search', {
        'countrycode': countryCode,
        'hidebroken': 'true',
        'order': 'clickcount',
        'reverse': 'true',
        'limit': '500',
      }));
    }

    if (lat != null && lon != null) {
      addAll(await _getJson('/json/stations/search', {
        'geo_lat': lat.toStringAsFixed(4),
        'geo_long': lon.toStringAsFixed(4),
        'geo_distance': (kNearbyRadiusKm * 1000).round().toString(),
        'hidebroken': 'true',
        'order': 'clickcount',
        'reverse': 'true',
        'limit': '300',
      }));
    }

    return byUuid.values.toList();
  }

  /// Doar posturile unei țări (inclusiv cele fără coordonate) — pentru
  /// răsfoirea altor țări din listă.
  Future<List<RadioStation>> fetchCountry(String countryCode) async {
    final raw = await _getJson('/json/stations/search', {
      'countrycode': countryCode,
      'hidebroken': 'true',
      'order': 'clickcount',
      'reverse': 'true',
      'limit': '1000',
    });
    return _parseStations(raw);
  }

  /// TOATE posturile unei țări (și cele fără coordonate, ~3/4 din catalog) —
  /// pentru hartă și listă. Parsarea rulează pe alt isolate.
  Future<List<RadioStation>> fetchCountryAll(String countryCode) async {
    Object? lastError;
    for (final host in _servers) {
      try {
        final uri = Uri.https(host, '/json/stations/search', {
          'countrycode': countryCode,
          'hidebroken': 'true',
          'order': 'clickcount',
          'reverse': 'true',
          'limit': '20000',
        });
        final res = await http
            .get(uri, headers: {'User-Agent': kHttpUserAgent})
            .timeout(const Duration(minutes: 2));
        if (res.statusCode == 200) return compute(_decodeAll, res.bodyBytes);
        lastError = 'HTTP ${res.statusCode}';
      } catch (e) {
        lastError = e;
      }
    }
    throw Exception('Radio Browser indisponibil: $lastError');
  }

  /// Căutare după nume (subșir, fără diferență de majuscule).
  Future<List<RadioStation>> searchByName(String name, {String? countryCode}) async {
    final raw = await _getJson('/json/stations/search', {
      'name': name,
      if (countryCode != null) 'countrycode': countryCode,
      'hidebroken': 'true',
      'order': 'clickcount',
      'reverse': 'true',
      'limit': '30',
    });
    return _parseStations(raw);
  }

  /// Toate posturile din lume care au coordonate (~13.500, ~17 MB) — ca în
  /// Radio Garden. Parsarea rulează pe alt isolate ca să nu blocheze UI-ul.
  Future<List<RadioStation>> fetchWorld() async {
    Object? lastError;
    for (final host in _servers) {
      try {
        final uri = Uri.https(host, '/json/stations/search', {
          'has_geo_info': 'true',
          'hidebroken': 'true',
          'limit': '100000',
        });
        final res = await http
            .get(uri, headers: {'User-Agent': kHttpUserAgent})
            .timeout(const Duration(minutes: 3));
        if (res.statusCode == 200) {
          return compute(_decodeWorld, res.bodyBytes);
        }
        lastError = 'HTTP ${res.statusCode}';
      } catch (e) {
        lastError = e;
      }
    }
    throw Exception('Radio Browser indisponibil: $lastError');
  }

  Future<void> saveWorldCache(List<RadioStation> stations) async {
    final file = _cacheFile('world');
    final tmp = File('${file.path}.tmp');
    await tmp.writeAsString(await compute(_encodeCache, stations));
    await tmp.rename(file.path);
  }

  Future<CachedStations> loadWorldCache() async {
    final file = _cacheFile('world');
    if (!await file.exists()) return const CachedStations([], null);
    try {
      return await compute(_decodeCache, await file.readAsString());
    } catch (_) {
      return const CachedStations([], null);
    }
  }

  List<RadioStation> _parseStations(List<dynamic> raw) {
    final result = <RadioStation>[];
    for (final item in raw.whereType<Map>()) {
      final s = RadioStation.fromRadioBrowser(Map<String, dynamic>.from(item));
      if (s.uuid.isEmpty || s.streamUrl.isEmpty || s.name.isEmpty) continue;
      result.add(s);
    }
    return result;
  }

  /// Etichetă Radio Browser: anunță că postul a fost pornit (contează la
  /// clasamentul de popularitate). Erorile sunt ignorate.
  Future<void> reportClick(RadioStation station) async {
    if (station.isManual) return;
    try {
      await _getJson('/json/url/${station.uuid}', {});
    } catch (_) {}
  }

  // ── Cache offline ─────────────────────────────────────────────────────────

  File _cacheFile(String key) => File(p.join(DiskCache.rootPath, 'stations_$key.json'));

  static String cacheKeyFor(String? countryCode) =>
      (countryCode == null || countryCode.isEmpty) ? 'nearby' : countryCode.toUpperCase();

  Future<void> saveCache(String key, List<RadioStation> stations) async {
    final file = _cacheFile(key);
    final tmp = File('${file.path}.tmp');
    await tmp.writeAsString(await compute(_encodeCache, stations));
    await tmp.rename(file.path);
  }

  Future<CachedStations> loadCache(String key) async {
    final file = _cacheFile(key);
    if (!await file.exists()) return const CachedStations([], null);
    try {
      return await compute(_decodeCache, await file.readAsString());
    } catch (_) {
      return const CachedStations([], null);
    }
  }

  static String countryAllKey(String countryCode) => 'all_${countryCode.toUpperCase()}';

  // ── Posturi adăugate manual ───────────────────────────────────────────────

  Future<List<RadioStation>> loadManualStations() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getStringList(_kManualStationsKey) ?? [];
    final result = <RadioStation>[];
    for (final s in raw) {
      try {
        result.add(RadioStation.fromJson(jsonDecode(s) as Map<String, dynamic>));
      } catch (_) {}
    }
    return result;
  }

  Future<void> _saveManualStations(List<RadioStation> stations) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_kManualStationsKey, stations.map((s) => jsonEncode(s.toJson())).toList());
  }

  Future<RadioStation> addManualStation({
    required String name,
    required String streamUrl,
    String countryCode = '',
    String homepage = '',
    String favicon = '',
    double? lat,
    double? lon,
  }) async {
    final station = RadioStation(
      uuid: 'manual-${DateTime.now().microsecondsSinceEpoch}',
      name: name,
      streamUrl: streamUrl,
      countryCode: countryCode,
      homepage: homepage,
      favicon: favicon,
      lat: lat,
      lon: lon,
      isHls: streamUrl.toLowerCase().contains('.m3u8'),
      isManual: true,
    );
    final all = await loadManualStations();
    all.add(station);
    await _saveManualStations(all);
    return station;
  }

  Future<void> removeManualStation(String uuid) async {
    final all = await loadManualStations();
    all.removeWhere((s) => s.uuid == uuid);
    await _saveManualStations(all);
  }

  // ── Ultima poziție cunoscută ──────────────────────────────────────────────

  Future<(double, double)?> loadLastPosition() async {
    final prefs = await SharedPreferences.getInstance();
    final lat = prefs.getDouble(_kLastLatKey);
    final lon = prefs.getDouble(_kLastLonKey);
    return (lat == null || lon == null) ? null : (lat, lon);
  }

  Future<void> saveLastPosition(double lat, double lon) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(_kLastLatKey, lat);
    await prefs.setDouble(_kLastLonKey, lon);
  }
}

// Funcții top-level (rulează și pe alt isolate prin compute()).

List<RadioStation> _decodeAll(Uint8List bytes) {
  final raw = jsonDecode(utf8.decode(bytes)) as List;
  final result = <RadioStation>[];
  for (final item in raw.whereType<Map>()) {
    final s = RadioStation.fromRadioBrowser(Map<String, dynamic>.from(item));
    if (s.uuid.isEmpty || s.streamUrl.isEmpty || s.name.isEmpty) continue;
    result.add(s);
  }
  return result;
}

List<RadioStation> _decodeWorld(Uint8List bytes) {
  final raw = jsonDecode(utf8.decode(bytes)) as List;
  final result = <RadioStation>[];
  for (final item in raw.whereType<Map>()) {
    final s = RadioStation.fromRadioBrowser(Map<String, dynamic>.from(item));
    if (s.uuid.isEmpty || s.streamUrl.isEmpty || s.name.isEmpty || !s.hasLocation) continue;
    result.add(s);
  }
  return result;
}

String _encodeCache(List<RadioStation> stations) => jsonEncode({
      'fetchedAt': DateTime.now().toIso8601String(),
      'stations': stations.map((s) => s.toJson()).toList(),
    });

CachedStations _decodeCache(String raw) {
  final decoded = jsonDecode(raw) as Map<String, dynamic>;
  final stations = (decoded['stations'] as List)
      .whereType<Map>()
      .map((m) => RadioStation.fromJson(Map<String, dynamic>.from(m)))
      .toList();
  return CachedStations(stations, DateTime.tryParse(decoded['fetchedAt'] as String? ?? ''));
}

/// Ordonează posturile pentru listă. "Aproape": cele cu coordonate în rază,
/// după distanță, urmate de restul posturilor țării după popularitate.
List<RadioStation> sortStations(List<RadioStation> stations, StationSort sort, {double? lat, double? lon}) {
  final list = List<RadioStation>.from(stations);
  switch (sort) {
    case StationSort.popular:
      list.sort((a, b) => b.clickCount.compareTo(a.clickCount));
      break;
    case StationSort.votes:
      list.sort((a, b) => b.votes.compareTo(a.votes));
      break;
    case StationSort.trending:
      list.sort((a, b) => b.clickTrend.compareTo(a.clickTrend));
      break;
    case StationSort.nearby:
      list.sort((a, b) {
        final da = a.distanceKmFrom(lat, lon);
        final db = b.distanceKmFrom(lat, lon);
        final aNear = da != null && da <= kNearbyRadiusKm;
        final bNear = db != null && db <= kNearbyRadiusKm;
        if (aNear && bNear) return da.compareTo(db);
        if (aNear != bNear) return aNear ? -1 : 1;
        return b.clickCount.compareTo(a.clickCount);
      });
      break;
  }
  return list;
}
