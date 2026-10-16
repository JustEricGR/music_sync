import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:musicsync_app/radio/radio_station.dart';
import 'package:musicsync_app/radio/station_clusters.dart';
import 'package:musicsync_app/themes/app_themes.dart';
import 'package:musicsync_app/themes/theme_photos.dart';

RadioStation _s(String id, double lat, double lon, {String state = '', int clicks = 0}) => RadioStation(
      uuid: id,
      name: id,
      streamUrl: 'http://x',
      lat: lat,
      lon: lon,
      state: state,
      country: 'Greece',
      countryCode: 'GR',
      clickCount: clicks,
    );

void main() {
  group('clusterStations', () {
    final athens = [
      _s('a1', 37.98, 23.72, state: 'Athens', clicks: 5),
      _s('a2', 37.99, 23.73, state: 'Athens', clicks: 50),
      _s('a3', 37.97, 23.74, state: 'Attica'),
    ];
    final thessaloniki = [_s('t1', 40.64, 22.94, state: 'Thessaloniki')];

    test('zoomed out: one bubble per city, most popular first, place name', () {
      final clusters = clusterStations(
        [...athens, ...thessaloniki],
        zoom: 6,
        south: 34,
        west: 19,
        north: 42,
        east: 28,
      );
      expect(clusters.length, 2);
      final ath = clusters.firstWhere((c) => c.stations.length == 3);
      expect(ath.stations.first.uuid, 'a2');
      expect(ath.placeName, 'Athens');
      expect(ath.lat, closeTo(37.98, 0.01));
    });

    test('zoomed in: stations split apart', () {
      final clusters = clusterStations(athens, zoom: 16, south: 37.9, west: 23.6, north: 38.1, east: 23.8);
      expect(clusters.length, 3);
    });

    test('stations outside the visible area are skipped', () {
      final clusters = clusterStations(
        [...athens, ...thessaloniki],
        zoom: 10,
        south: 40.4,
        west: 22.6,
        north: 40.9,
        east: 23.2,
      );
      expect(clusters.single.stations.single.uuid, 't1');
    });
  });

  group('theme photos', () {
    test('groupThemeAssets groups images per theme folder', () {
      final grouped = groupThemeAssets([
        'assets/images/turkey/turkey2.jpg',
        'assets/images/turkey/turkey1.jpg',
        'assets/images/turkey/notes.txt',
        'assets/images/greece/new photo.PNG',
        'assets/yugoslavia.jpg',
        'assets/geo/countries.json',
      ]);
      expect(grouped, {
        'turkey': ['assets/images/turkey/turkey1.jpg', 'assets/images/turkey/turkey2.jpg'],
        'greece': ['assets/images/greece/new photo.PNG'],
      });
    });

    test('every theme folder exists in assets/images', () {
      for (final theme in appThemes.values) {
        expect(Directory('assets/images/${theme.photoFolder}').existsSync(), isTrue, reason: theme.id);
      }
    });
  });
}
