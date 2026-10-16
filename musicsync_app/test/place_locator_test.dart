import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:musicsync_app/radio/place_locator.dart';
import 'package:musicsync_app/radio/radio_station.dart';

RadioStation _s(String name, {String state = '', String cc = 'GR', String country = 'Greece', double? lat, double? lon}) =>
    RadioStation(uuid: name, name: name, streamUrl: 'http://x', state: state, countryCode: cc, country: country, lat: lat, lon: lon);

void main() {
  late PlaceLocator locator;

  setUpAll(() {
    locator = PlaceLocator.parse(File('assets/geo/places.json').readAsStringSync());
  });

  test('normalizePlaceName folds diacritics and Greek accents', () {
    expect(normalizePlaceName('İstanbul'), 'istanbul');
    expect(normalizePlaceName('Constanța'), 'constanta');
    expect(normalizePlaceName('Θεσσαλονίκη'), 'θεσσαλονικη');
    expect(normalizePlaceName('Athens, Greece'), 'athensgreece');
  });

  test('stations with real coordinates are unchanged', () {
    final s = _s('X', lat: 1, lon: 2);
    expect(identical(locator.place(s), s), isTrue);
  });

  test('state city name places the station in that city', () {
    final athens = locator.place(_s('Radio A', state: 'Athens'))!;
    expect(athens.precision, LocationPrecision.city);
    expect(athens.lat, closeTo(37.98, 0.1));

    // Variantă ortografică din alternatele GeoNames.
    final heraklion = locator.place(_s('Radio B', state: 'Heraclion'))!;
    expect(heraklion.lat, closeTo(35.33, 0.1));

    // "Athens Greece" -> bucata "Athens".
    final split = locator.place(_s('Radio C', state: 'Athens Greece'))!;
    expect(split.precision, LocationPrecision.city);
    expect(split.lon, closeTo(23.73, 0.1));
  });

  test('big city in the station name', () {
    final s = locator.place(_s('Radio Thessaloniki 94.5'))!;
    expect(s.precision, LocationPrecision.city);
    expect(s.lat, closeTo(40.64, 0.1));
  });

  test('national / online station goes to the capital, without distance', () {
    final s = locator.place(_s('Kral FM', cc: 'TR', country: 'Turkey'))!;
    expect(s.precision, LocationPrecision.country);
    expect(s.lat, closeTo(39.92, 0.1)); // Ankara
    expect(s.distanceKmFrom(39.9, 32.8), isNull);
  });

  test('unknown country stays without location', () {
    expect(locator.place(_s('X', cc: '', country: '')), isNull);
  });

  test('precision survives the offline cache round-trip', () {
    final s = locator.place(_s('Radio A', state: 'Athens'))!;
    expect(RadioStation.fromJson(s.toJson()).precision, LocationPrecision.city);
  });
}
