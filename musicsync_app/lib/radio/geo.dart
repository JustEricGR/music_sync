import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;

const String _kCountriesAsset = 'assets/geo/countries.json';

class CountryInfo {
  final String code;
  final String name;
  const CountryInfo(this.code, this.name);

  String get flag => flagEmoji(code);
}

/// Drapelul ca emoji din codul ISO (ex. "GR" -> 🇬🇷).
String flagEmoji(String countryCode) {
  if (countryCode.length != 2) return '🌍';
  final upper = countryCode.toUpperCase();
  return String.fromCharCodes(upper.codeUnits.map((c) => 0x1F1E6 + c - 0x41));
}

double haversineKm(double lat1, double lon1, double lat2, double lon2) {
  const r = 6371.0;
  double rad(double d) => d * pi / 180;
  final dLat = rad(lat2 - lat1);
  final dLon = rad(lon2 - lon1);
  final a = sin(dLat / 2) * sin(dLat / 2) + cos(rad(lat1)) * cos(rad(lat2)) * sin(dLon / 2) * sin(dLon / 2);
  return 2 * r * asin(min(1.0, sqrt(a)));
}

class _Polygon {
  /// Primul inel = conturul exterior, restul = găuri. Coordonate [lon, lat].
  final List<List<List<double>>> rings;
  final double minLon, minLat, maxLon, maxLat;
  _Polygon(this.rings, this.minLon, this.minLat, this.maxLon, this.maxLat);
}

class _Country {
  final CountryInfo info;
  final List<_Polygon> polygons;
  _Country(this.info, this.polygons);
}

bool _ringContains(List<List<double>> ring, double lon, double lat) {
  bool inside = false;
  for (int i = 0, j = ring.length - 1; i < ring.length; j = i++) {
    final xi = ring[i][0], yi = ring[i][1];
    final xj = ring[j][0], yj = ring[j][1];
    if (((yi > lat) != (yj > lat)) && (lon < (xj - xi) * (lat - yi) / (yj - yi) + xi)) {
      inside = !inside;
    }
  }
  return inside;
}

/// Granițele țărilor (Natural Earth 1:50m, inclus în aplicație) — găsește
/// țara pentru o coordonată GPS complet offline.
class CountryLocator {
  final List<_Country> _countries;
  CountryLocator._(this._countries);

  static CountryLocator? _cached;

  static Future<CountryLocator> load() async {
    if (_cached != null) return _cached!;
    final raw = await rootBundle.loadString(_kCountriesAsset);
    _cached = await compute(CountryLocator.parse, raw);
    return _cached!;
  }

  /// Format: `[{"c": "GR", "n": "Greece", "p": [[[[lon, lat], ...], ...hole rings], ...polygons]}]`
  static CountryLocator parse(String raw) {
    final decoded = jsonDecode(raw) as List;
    final countries = <_Country>[];
    for (final c in decoded) {
      final polygons = <_Polygon>[];
      for (final poly in c['p'] as List) {
        final rings = (poly as List)
            .map((ring) => (ring as List).map((pt) => [(pt[0] as num).toDouble(), (pt[1] as num).toDouble()]).toList())
            .toList();
        if (rings.isEmpty || rings.first.isEmpty) continue;
        double minLon = 180, minLat = 90, maxLon = -180, maxLat = -90;
        for (final pt in rings.first) {
          minLon = min(minLon, pt[0]);
          maxLon = max(maxLon, pt[0]);
          minLat = min(minLat, pt[1]);
          maxLat = max(maxLat, pt[1]);
        }
        polygons.add(_Polygon(rings, minLon, minLat, maxLon, maxLat));
      }
      countries.add(_Country(CountryInfo(c['c'] as String, c['n'] as String), polygons));
    }
    return CountryLocator._(countries);
  }

  /// Toate țările, ordonate după nume (pentru alegerea țării din listă).
  List<CountryInfo> get countries {
    final byCode = <String, CountryInfo>{for (final c in _countries) c.info.code: c.info};
    return byCode.values.toList()..sort((a, b) => a.name.compareTo(b.name));
  }

  /// Țara care conține punctul; dacă niciuna (coastă, insulă mică omisă
  /// la scara 1:50m), cea mai apropiată graniță în limita a ~25 km.
  CountryInfo? lookup(double lat, double lon) {
    for (final country in _countries) {
      for (final poly in country.polygons) {
        if (lon < poly.minLon || lon > poly.maxLon || lat < poly.minLat || lat > poly.maxLat) continue;
        if (!_ringContains(poly.rings.first, lon, lat)) continue;
        final inHole = poly.rings.skip(1).any((hole) => _ringContains(hole, lon, lat));
        if (!inHole) return country.info;
      }
    }

    const marginDeg = 0.3;
    CountryInfo? best;
    double bestKm = 25;
    for (final country in _countries) {
      for (final poly in country.polygons) {
        if (lon < poly.minLon - marginDeg ||
            lon > poly.maxLon + marginDeg ||
            lat < poly.minLat - marginDeg ||
            lat > poly.maxLat + marginDeg) {
          continue;
        }
        for (final pt in poly.rings.first) {
          final km = haversineKm(lat, lon, pt[1], pt[0]);
          if (km < bestKm) {
            bestKm = km;
            best = country.info;
          }
        }
      }
    }
    return best;
  }
}
