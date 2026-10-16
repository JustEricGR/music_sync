import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:musicsync_app/radio/geo.dart';
import 'package:musicsync_app/radio/radio_repository.dart';
import 'package:musicsync_app/radio/radio_station.dart';
import 'package:musicsync_app/radio/song_recognizer.dart';

RadioStation _station(String name, {double? lat, double? lon, int clicks = 0, int votes = 0, int trend = 0}) =>
    RadioStation(uuid: name, name: name, streamUrl: 'http://x', lat: lat, lon: lon, clickCount: clicks, votes: votes, clickTrend: trend);

void main() {
  group('CountryLocator (bundled borders)', () {
    late CountryLocator locator;

    setUpAll(() {
      locator = CountryLocator.parse(File('assets/geo/countries.json').readAsStringSync());
    });

    test('finds countries for well-known cities', () {
      expect(locator.lookup(37.98, 23.73)?.code, 'GR'); // Atena
      expect(locator.lookup(40.64, 22.94)?.code, 'GR'); // Salonic
      expect(locator.lookup(41.01, 28.98)?.code, 'TR'); // Istanbul
      expect(locator.lookup(44.43, 26.10)?.code, 'RO'); // București
      expect(locator.lookup(40.18, 44.51)?.code, 'AM'); // Erevan
      expect(locator.lookup(43.86, 18.41)?.code, 'BA'); // Sarajevo
    });

    test('coastal point just offshore falls back to nearest country', () {
      expect(locator.lookup(37.93, 23.66)?.code, 'GR'); // Pireu, în mare
    });

    test('open sea far from land is unknown', () {
      expect(locator.lookup(35.0, -40.0), isNull);
    });
  });

  test('parse handles holes', () {
    final raw = jsonEncode([
      {
        'c': 'XX',
        'n': 'Donut',
        'p': [
          [
            [[0, 0], [10, 0], [10, 10], [0, 10], [0, 0]],
            [[4, 4], [6, 4], [6, 6], [4, 6], [4, 4]],
          ]
        ],
      },
      {
        'c': 'YY',
        'n': 'Hole',
        'p': [
          [
            [[4, 4], [6, 4], [6, 6], [4, 6], [4, 4]],
          ]
        ],
      },
    ]);
    final locator = CountryLocator.parse(raw);
    expect(locator.lookup(2, 2)?.code, 'XX');
    expect(locator.lookup(5, 5)?.code, 'YY');
  });

  test('flagEmoji', () {
    expect(flagEmoji('GR'), '🇬🇷');
    expect(flagEmoji('tr'), '🇹🇷');
    expect(flagEmoji(''), '🌍');
  });

  test('fmFrequency is parsed from the station name', () {
    expect(_station('Republic 100.3').fmFrequency, '100.3 FM');
    expect(_station('Radio Zeppelin 106,7').fmFrequency, '106.7 FM');
    expect(_station('Kiss 92.9 Thessaloniki').fmFrequency, '92.9 FM');
    expect(_station('1055 Rock').fmFrequency, isNull);
    expect(_station('Radio 2.0').fmFrequency, isNull);
  });

  test('fromRadioBrowser maps API fields', () {
    final s = RadioStation.fromRadioBrowser({
      'stationuuid': 'u1',
      'name': ' Test FM ',
      'url': 'http://a',
      'url_resolved': 'http://b',
      'countrycode': 'gr',
      'votes': 3,
      'clickcount': 4,
      'clicktrend': -1,
      'geo_lat': 40.0,
      'geo_long': 22.0,
      'hls': 1,
      'bitrate': 128,
    });
    expect(s.name, 'Test FM');
    expect(s.streamUrl, 'http://b');
    expect(s.countryCode, 'GR');
    expect(s.isHls, isTrue);
    expect(s.hasLocation, isTrue);
    expect(RadioStation.fromJson(s.toJson()).toJson(), s.toJson());
  });

  group('sortStations', () {
    final near = _station('near', lat: 40.6, lon: 22.95, clicks: 1);
    final mid = _station('mid', lat: 40.9, lon: 23.3, clicks: 5);
    final far = _station('far', lat: 37.98, lon: 23.73, clicks: 100); // Atena, >150 km
    final noGeo = _station('nogeo', clicks: 50, votes: 9, trend: 7);

    test('nearby: in-radius by distance, then the rest by popularity', () {
      final sorted = sortStations([far, noGeo, mid, near], StationSort.nearby, lat: 40.64, lon: 22.94);
      expect(sorted.map((s) => s.name), ['near', 'mid', 'far', 'nogeo']);
    });

    test('popular / votes / trending', () {
      expect(sortStations([near, far, noGeo], StationSort.popular).first.name, 'far');
      expect(sortStations([near, far, noGeo], StationSort.votes).first.name, 'nogeo');
      expect(sortStations([near, far, noGeo], StationSort.trending).first.name, 'nogeo');
    });
  });

  test('parseRawHeaderEnd finds the end of HTTP and ICY headers', () {
    final icy = latin1.encode('ICY 200 OK\r\nicy-name:X\r\n\r\nAUDIO');
    expect(parseRawHeaderEnd(icy), 22);
    expect(latin1.decode(icy.sublist(22 + 4)), 'AUDIO');
    expect(parseRawHeaderEnd(latin1.encode('HTTP/1.0 200 OK\r\nicy-br:128\r\n')), -1);
  });
}
