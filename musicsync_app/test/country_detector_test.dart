import 'package:flutter_test/flutter_test.dart';

import 'package:musicsync_app/themes/app_themes.dart';
import 'package:musicsync_app/themes/country_detector.dart';

void main() {
  group('detectThemeForPlaylist', () {
    test('defaults to Greece when nothing matches', () {
      expect(detectThemeForPlaylist(title: 'Gym mix', songNames: ['Song A.m4a', 'Other Song.mp3']), 'grecia');
      expect(detectThemeForPlaylist(title: '', songNames: []), 'grecia');
    });

    test('playlist title keyword wins', () {
      expect(detectThemeForPlaylist(title: 'Türkçe Pop', songNames: ['x.mp3']), 'turcia');
      expect(detectThemeForPlaylist(title: 'Turkish hits', songNames: []), 'turcia');
      expect(detectThemeForPlaylist(title: 'Sevdah noći', songNames: []), 'bosnia');
      expect(detectThemeForPlaylist(title: 'Persian classics', songNames: []), 'iran');
      expect(detectThemeForPlaylist(title: 'Armenian rabiz', songNames: []), 'armenia');
    });

    test('Turkish letters in song names', () {
      final songs = ['Tarkan - Şımarık.m4a', 'Sezen Aksu - Gidiyorum.m4a', 'Müslüm Gürses - Affet.m4a'];
      expect(detectThemeForPlaylist(title: 'Favorites', songNames: songs), 'turcia');
    });

    test('Greek script in song names', () {
      final songs = ['Νίκος Βέρτης - Θέλω να σε δω.m4a', 'Πάνος Κιάμος - Σ\'ακολουθώ.m4a'];
      expect(detectThemeForPlaylist(title: 'My list', songNames: songs), 'grecia');
    });

    test('Azerbaijani schwa beats Turkish letters', () {
      final songs = ['Aygün Kazımova - Gəl.m4a', 'Röya - Sevgilim gəl.m4a'];
      expect(detectThemeForPlaylist(title: 'Mix', songNames: songs), 'azerbaidjan');
    });

    test('Persian vs Sorani Kurdish in Arabic script', () {
      expect(detectThemeForPlaylist(title: 'x', songNames: ['ابی - ستاره.m4a', 'گوگوش - من آمده‌ام.m4a']), 'iran');
      expect(detectThemeForPlaylist(title: 'x', songNames: ['حەمە جەزا - ئەی ڕەقیب.m4a', 'نەژاد - کوردستان.m4a']), 'kurdistan');
    });

    test('turkmen keyword is Central Asia, not Turkey', () {
      expect(detectThemeForPlaylist(title: 'Turkmen songs', songNames: []), 'central asia');
    });

    test('a few Turkish songs do not override a Greek playlist', () {
      final songs = [
        for (int i = 0; i < 10; i++) 'Καλλιτέχνης $i - Τραγούδι.m4a',
        'Tarkan - Şımarık.m4a',
      ];
      expect(detectThemeForPlaylist(title: 'Mix', songNames: songs), 'grecia');
    });

    test('one Turkish song in a large unrelated playlist keeps the default', () {
      final songs = [for (int i = 0; i < 40; i++) 'Artist $i - Song $i.m4a', 'Tarkan - Şımarık.m4a'];
      expect(detectThemeForPlaylist(title: 'Workout', songNames: songs), 'grecia');
    });

    test('every detected id is a real theme', () {
      for (final id in [...kCountryCodeToTheme.values, kDefaultThemeId]) {
        expect(appThemes.containsKey(id), isTrue, reason: id);
      }
    });
  });

  test('themeForCountryCode', () {
    expect(themeForCountryCode('TR'), 'turcia');
    expect(themeForCountryCode('gr'), 'grecia');
    expect(themeForCountryCode('RO'), 'grecia');
    expect(themeForCountryCode(null), 'grecia');
  });
}
