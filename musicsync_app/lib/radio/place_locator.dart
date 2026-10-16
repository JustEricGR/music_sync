import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;

import 'radio_station.dart';

const String _kPlacesAsset = 'assets/geo/places.json';

const Map<String, String> _kFold = {
  'à': 'a', 'á': 'a', 'â': 'a', 'ã': 'a', 'ä': 'a', 'å': 'a', 'ā': 'a', 'ă': 'a', 'ą': 'a', 'ǎ': 'a',
  'ç': 'c', 'ć': 'c', 'ĉ': 'c', 'ċ': 'c', 'č': 'c', 'ď': 'd', 'đ': 'd',
  'è': 'e', 'é': 'e', 'ê': 'e', 'ë': 'e', 'ē': 'e', 'ĕ': 'e', 'ė': 'e', 'ę': 'e', 'ě': 'e', 'ə': 'e',
  'ĝ': 'g', 'ğ': 'g', 'ġ': 'g', 'ģ': 'g', 'ĥ': 'h', 'ħ': 'h',
  'ì': 'i', 'í': 'i', 'î': 'i', 'ï': 'i', 'ĩ': 'i', 'ī': 'i', 'ĭ': 'i', 'į': 'i', 'ı': 'i', 'ǐ': 'i',
  'ĵ': 'j', 'ķ': 'k', 'ĺ': 'l', 'ļ': 'l', 'ľ': 'l', 'ŀ': 'l', 'ł': 'l',
  'ñ': 'n', 'ń': 'n', 'ņ': 'n', 'ň': 'n', 'ŉ': 'n',
  'ò': 'o', 'ó': 'o', 'ô': 'o', 'õ': 'o', 'ö': 'o', 'ø': 'o', 'ō': 'o', 'ŏ': 'o', 'ő': 'o', 'ǒ': 'o',
  'ŕ': 'r', 'ŗ': 'r', 'ř': 'r', 'ś': 's', 'ŝ': 's', 'ş': 's', 'š': 's', 'ș': 's',
  'ţ': 't', 'ť': 't', 'ŧ': 't', 'ț': 't',
  'ù': 'u', 'ú': 'u', 'û': 'u', 'ü': 'u', 'ũ': 'u', 'ū': 'u', 'ŭ': 'u', 'ů': 'u', 'ű': 'u', 'ų': 'u', 'ǔ': 'u',
  'ŵ': 'w', 'ý': 'y', 'ÿ': 'y', 'ŷ': 'y', 'ź': 'z', 'ż': 'z', 'ž': 'z',
  'ß': 'ss', 'æ': 'ae', 'œ': 'oe', 'þ': 'th',
  'ά': 'α', 'ἀ': 'α', 'ἁ': 'α', 'ὰ': 'α', 'ᾶ': 'α', 'έ': 'ε', 'ἐ': 'ε', 'ἑ': 'ε', 'ὲ': 'ε',
  'ή': 'η', 'ἠ': 'η', 'ἡ': 'η', 'ὴ': 'η', 'ῆ': 'η', 'ί': 'ι', 'ϊ': 'ι', 'ΐ': 'ι', 'ἰ': 'ι', 'ἱ': 'ι', 'ὶ': 'ι', 'ῖ': 'ι',
  'ό': 'ο', 'ὀ': 'ο', 'ὁ': 'ο', 'ὸ': 'ο', 'ύ': 'υ', 'ϋ': 'υ', 'ΰ': 'υ', 'ὐ': 'υ', 'ὑ': 'υ', 'ὺ': 'υ', 'ῦ': 'υ',
  'ώ': 'ω', 'ὠ': 'ω', 'ὡ': 'ω', 'ὼ': 'ω', 'ῶ': 'ω', 'ς': 'σ',
};

final RegExp _keep = RegExp(r'[^0-9a-zα-ωа-яёіїєґ]');

/// Cheia de căutare a unui nume de loc — identică cu scriptul care a generat
/// `assets/geo/places.json` (fără diacritice, doar litere și cifre).
String normalizePlaceName(String name) {
  final lower = name.toLowerCase();
  final buffer = StringBuffer();
  for (final rune in lower.runes) {
    final c = String.fromCharCode(rune);
    buffer.write(_kFold[c] ?? c);
  }
  return buffer.toString().replaceAll(_keep, '');
}

final RegExp _stateSplit = RegExp(r'[,/()\-]|\s+');
final RegExp _nameSplit = RegExp(r'[\s\-_.,|/()]+');
const Set<String> _kStopWords = {
  'region', 'province', 'city', 'state', 'county', 'district', 'prefecture', 'radio', 'online', 'music',
};

/// Plasează pe hartă posturile Radio Browser fără coordonate, după orașul /
/// regiunea declarată (bază de date GeoNames inclusă în aplicație, offline).
/// Cele fără oraș (naționale / online) ajung la capitala țării.
class PlaceLocator {
  /// țară -> nume normalizat -> [lat, lon, oraș mare (1/0)]
  final Map<String, Map<String, List<num>>> _places;
  final Map<String, List<num>> _capitals;

  PlaceLocator._(this._places, this._capitals);

  static PlaceLocator? _cached;

  static Future<PlaceLocator> load() async {
    if (_cached != null) return _cached!;
    final raw = await rootBundle.loadString(_kPlacesAsset);
    _cached = await compute(PlaceLocator.parse, raw);
    return _cached!;
  }

  static PlaceLocator parse(String raw) {
    final decoded = jsonDecode(raw) as Map<String, dynamic>;
    final places = <String, Map<String, List<num>>>{};
    (decoded['places'] as Map<String, dynamic>).forEach((cc, map) {
      places[cc] = {
        for (final e in (map as Map<String, dynamic>).entries) e.key: List<num>.from(e.value as List),
      };
    });
    final capitals = {
      for (final e in (decoded['capitals'] as Map<String, dynamic>).entries) e.key: List<num>.from(e.value as List),
    };
    return PlaceLocator._(places, capitals);
  }

  /// Postul cu poziție: neschimbat dacă are deja coordonate; altfel plasat
  /// după oraș sau la capitală; null dacă nici țara nu e cunoscută.
  RadioStation? place(RadioStation s) {
    if (s.hasLocation) return s;
    final cc = s.countryCode;
    final places = _places[cc];
    final stop = {..._kStopWords, normalizePlaceName(s.country)};

    if (places != null) {
      final state = s.state.trim();
      if (state.isNotEmpty) {
        final hit = places[normalizePlaceName(state)];
        if (hit != null) return s.withLocation(hit[0].toDouble(), hit[1].toDouble(), LocationPrecision.city);
        for (final token in state.split(_stateSplit)) {
          final key = normalizePlaceName(token);
          if (key.length < 4 || stop.contains(key)) continue;
          final p = places[key];
          if (p != null) return s.withLocation(p[0].toDouble(), p[1].toDouble(), LocationPrecision.city);
        }
      }
      // Oraș mare în numele postului ("Radio Thessaloniki 94.5").
      for (final token in s.name.split(_nameSplit)) {
        final key = normalizePlaceName(token);
        if (key.length < 5 || stop.contains(key)) continue;
        final p = places[key];
        if (p != null && p[2] == 1) return s.withLocation(p[0].toDouble(), p[1].toDouble(), LocationPrecision.city);
      }
    }

    final capital = _capitals[cc];
    if (capital == null) return null;
    return s.withLocation(capital[0].toDouble(), capital[1].toDouble(), LocationPrecision.country);
  }
}
