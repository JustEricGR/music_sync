import 'package:flutter_test/flutter_test.dart';

import 'package:musicsync_app/radio/radio_station.dart';
import 'package:musicsync_app/radio/stream_finder.dart';

void main() {
  test('parsePlaylistFile reads .pls and .m3u', () {
    expect(parsePlaylistFile('[playlist]\nNumberOfEntries=1\nFile1=http://s.example:8000/live\nTitle1=X'),
        'http://s.example:8000/live');
    expect(parsePlaylistFile('#EXTM3U\n#EXTINF:-1,Radio\nhttps://a.example/stream.mp3\n'), 'https://a.example/stream.mp3');
    expect(parsePlaylistFile('nothing here'), isNull);
  });

  test('extractStreamCandidates finds audio links and skips images/social', () {
    const html = r'''
      <img src="https://site.gr/wp-content/uploads/logo.png">
      <a href="https://facebook.com/radio">fb</a>
      <script>var player = {"src":"https:\/\/netradio.live24.gr\/republicthess"};</script>
      <audio src="https://radio.example.gr:31056/live"></audio>
      <a href="https://site.gr/about">about</a>
    ''';
    final c = extractStreamCandidates(html);
    expect(c, containsAll(['https://netradio.live24.gr/republicthess', 'https://radio.example.gr:31056/live']));
    expect(c.any((u) => u.contains('logo.png') || u.contains('facebook')), isFalse);
  });

  test('extractTitle and extractFavicon', () {
    const html = '<title>Greca 99,4 | Ακούστε live</title><link rel="icon" href="/favicon.png">';
    expect(extractTitle(html), 'Greca 99,4');
    expect(extractFavicon(html, Uri.parse('https://greca994.gr/')), 'https://greca994.gr/favicon.png');
  });

  test('countryFromHost and directory queries', () {
    expect(countryFromHost('kissfm.ro'), 'RO');
    expect(countryFromHost('powerturk.com.tr'), 'TR');
    expect(countryFromHost('powerturk.com'), isNull);
    expect(countryFromHost('radio.fm'), isNull);
    expect(directoryQueriesFor('kissfm.ro', null), ['kiss fm', 'kissfm']);
    expect(directoryQueriesFor('radiozu.ro', 'ZU'), ['radio zu', 'radiozu']);
  });

  test('rankDirectoryMatches prefers same homepage, then country', () {
    RadioStation s(String id, String name, String home, String cc, int clicks) =>
        RadioStation(uuid: id, name: name, streamUrl: 'http://$id', homepage: home, countryCode: cc, clickCount: clicks);
    final ranked = rankDirectoryMatches([
      s('us', '103.5 KISSFM Boise', 'https://1035kissfmboise.com/', 'US', 900),
      s('ro', 'Kiss FM', 'https://www.kissfm.ro/', 'RO', 10),
      s('ua', 'KissFm Deep', '', 'UA', 500),
    ], host: 'kissfm.ro', country: 'RO');
    expect(ranked.first.uuid, 'ro');
  });
}
