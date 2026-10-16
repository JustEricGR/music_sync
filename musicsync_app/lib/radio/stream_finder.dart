import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'disk_cache.dart';
import 'radio_station.dart';

/// Rezultatul căutării: un link de stream verificat (răspunde cu audio).
class FoundStream {
  final String streamUrl;
  final String? name;
  final String? homepage;
  final String? favicon;

  const FoundStream({required this.streamUrl, this.name, this.homepage, this.favicon});
}

// ── Parsare (funcții pure, testabile) ───────────────────────────────────────

/// Primul link dintr-un fișier playlist .pls / .m3u.
String? parsePlaylistFile(String body) {
  for (final raw in const LineSplitter().convert(body)) {
    final line = raw.trim();
    final pls = RegExp(r'^File\d+\s*=\s*(\S+)', caseSensitive: false).firstMatch(line);
    if (pls != null) return pls.group(1);
    if (line.startsWith('http://') || line.startsWith('https://')) return line;
  }
  return null;
}

// Domenii cunoscute de găzduire a stream-urilor radio.
const List<String> _kStreamHosts = [
  'streamtheworld', 'radiojar', 'zeno.fm', 'zenoradio', 'live24', 'shoutcast', 'icecast', 'radioca.st',
  'securenetsystems', 'streamguys', 'radiostreaming', 'stream.laut.fm', 'radioking', 'infomaniak',
  'listen2myradio', 'radio.co', 'mixlr', 'onlineradiobox', 'streema', 'emisorasonline', 'radionomy',
  'cdnstream', 'akamaized', 'streaming', 'stream.',
];

// Acceptă și linkurile din JSON cu slash-uri escapate (https:\/\/host\/cale).
final RegExp _urlInText = RegExp(r'''https?:\\?/\\?/(?:[^\s"'<>()\\]|\\/)+''');
final RegExp _audioPath = RegExp(
  r'(\.mp3|\.aac|\.aacp|\.ogg|\.opus|\.m3u8?|\.pls)(\?|$)|/stream|/live|/listen|/;|/radio\.mp3|:\d{4,5}(/|$)',
  caseSensitive: false,
);
final RegExp _notAudio = RegExp(
  r'\.(png|jpe?g|gif|svg|webp|ico|css|js|woff2?|ttf|html?|php|json|xml)(\?|$)|facebook|twitter|instagram|youtube|google|apple\.com|play\.google|wp-content|fonts\.',
  caseSensitive: false,
);

/// Linkuri din pagină care arată a stream audio, cele mai probabile primele.
List<String> extractStreamCandidates(String html) {
  final seen = <String>{};
  final scored = <(int, String)>[];
  for (final m in _urlInText.allMatches(html)) {
    final url = m.group(0)!.replaceAll(r'\/', '/').replaceAll('&amp;', '&');
    if (!seen.add(url) || _notAudio.hasMatch(url)) continue;
    final lower = url.toLowerCase();
    int score = 0;
    if (_audioPath.hasMatch(lower)) score += 2;
    if (_kStreamHosts.any(lower.contains)) score += 1;
    if (score > 0) scored.add((score, url));
  }
  scored.sort((a, b) => b.$1.compareTo(a.$1));
  return scored.map((e) => e.$2).toList();
}

/// Pagini interne de tip "player / live / ascultă", unde stă de obicei stream-ul.
List<String> extractPlayerPages(String html, Uri base) {
  final result = <String>{};
  final href = RegExp(r'''(?:href|src)\s*=\s*["']([^"'#]+)["']''', caseSensitive: false);
  final hint = RegExp(r'player|live|listen|stream|radio|ascult|ακο|ζωντ|canli|dinle|embed', caseSensitive: false);
  for (final m in href.allMatches(html)) {
    final link = m.group(1)!;
    if (!hint.hasMatch(link) || _notAudio.hasMatch(link.replaceAll(RegExp(r'\.html?$|\.php$'), ''))) continue;
    final uri = base.resolve(link);
    if (!uri.scheme.startsWith('http') || uri.toString() == base.toString()) continue;
    result.add(uri.toString());
  }
  return result.take(4).toList();
}

String? extractTitle(String html) {
  final og = RegExp(r'''<meta[^>]+property=["']og:site_name["'][^>]+content=["']([^"']+)''', caseSensitive: false)
      .firstMatch(html);
  final title = og?.group(1) ?? RegExp(r'<title[^>]*>([^<]+)</title>', caseSensitive: false).firstMatch(html)?.group(1);
  if (title == null) return null;
  final clean = title.replaceAll('&amp;', '&').replaceAll(RegExp(r'\s+'), ' ').trim();
  // "Radio X 99.5 | Ακούστε live" -> "Radio X 99.5"
  return clean.split(RegExp(r'\s[|–—-]\s')).first.trim();
}

String? extractFavicon(String html, Uri base) {
  final m = RegExp(
    r'''<link[^>]+rel=["'][^"']*(?:apple-touch-icon|icon)[^"']*["'][^>]*href=["']([^"']+)''',
    caseSensitive: false,
  ).firstMatch(html);
  return m == null ? null : base.resolve(m.group(1)!).toString();
}

// ── Rețea ─────────────────────────────────────────────────────────────────

enum _ProbeKind { audio, playlist, html, other }

class _Probe {
  final _ProbeKind kind;
  final String body;
  const _Probe(this.kind, [this.body = '']);
}

/// Găsește stream-ul unui post pornind de la site-ul lui sau de la un link
/// de stream / playlist. Verifică fiecare candidat (trebuie să răspundă cu
/// audio), deci rezultatul chiar se poate asculta.
class StreamFinder {
  final http.Client _client = http.Client();

  /// Căutare în catalogul Radio Browser, folosită când site-ul își încarcă
  /// player-ul din JavaScript (stream-ul nu apare în HTML).
  final Future<List<RadioStation>> Function(String name, {String? countryCode})? directorySearch;

  StreamFinder({this.directorySearch});

  void dispose() => _client.close();

  Future<_Probe> _probe(String url, {bool readBody = false}) async {
    final request = http.Request('GET', Uri.parse(url))
      ..headers['User-Agent'] = 'Mozilla/5.0 (Linux; Android 14) $kHttpUserAgent'
      ..headers['Icy-MetaData'] = '0';
    final response = await _client.send(request).timeout(const Duration(seconds: 12));
    final type = (response.headers['content-type'] ?? '').toLowerCase();
    final isIcy = response.headers.keys.any((k) => k.toLowerCase().startsWith('icy-'));

    _ProbeKind kind;
    if (response.statusCode >= 400) {
      kind = _ProbeKind.other;
    } else if (type.contains('mpegurl') || type.contains('scpls') || type.contains('x-scpls')) {
      kind = url.toLowerCase().contains('.m3u8') || type.contains('apple') ? _ProbeKind.audio : _ProbeKind.playlist;
    } else if (isIcy || type.startsWith('audio/') || type.contains('ogg') || type.contains('octet-stream') && _audioPath.hasMatch(url)) {
      kind = _ProbeKind.audio;
    } else if (type.contains('html')) {
      kind = _ProbeKind.html;
    } else {
      kind = _ProbeKind.other;
    }

    if (kind == _ProbeKind.audio || !readBody && kind != _ProbeKind.playlist) {
      // Stream infinit — nu-l citim, doar închidem conexiunea.
      unawaited(response.stream.listen(null).cancel());
      return _Probe(kind);
    }

    final bytes = <int>[];
    final done = Completer<void>();
    late StreamSubscription<List<int>> sub;
    sub = response.stream.listen(
      (chunk) {
        bytes.addAll(chunk);
        if (bytes.length > 1500000 && !done.isCompleted) done.complete();
      },
      onDone: () => done.isCompleted ? null : done.complete(),
      onError: (Object _) => done.isCompleted ? null : done.complete(),
    );
    await done.future.timeout(const Duration(seconds: 15), onTimeout: () {});
    await sub.cancel();
    return _Probe(kind, utf8.decode(bytes, allowMalformed: true));
  }

  /// Verifică un candidat; urmează playlisturile .pls/.m3u. Întoarce linkul
  /// de stream funcțional sau null.
  Future<String?> _verify(String url, {int depth = 0}) async {
    try {
      final probe = await _probe(url, readBody: false);
      if (probe.kind == _ProbeKind.audio) return url;
      if (probe.kind == _ProbeKind.playlist && depth < 2) {
        final inner = parsePlaylistFile(probe.body);
        if (inner != null) return _verify(inner, depth: depth + 1);
      }
    } catch (_) {}
    return null;
  }

  Future<FoundStream?> find(String input) async {
    var url = input.trim();
    if (!url.startsWith('http')) url = 'https://$url';
    final base = Uri.parse(url);

    // 1. Linkul dat e chiar stream-ul (sau un playlist .pls/.m3u)?
    final direct = await _verify(url);
    if (direct != null) return FoundStream(streamUrl: direct);

    // 2. E o pagină — căutăm în ea și în paginile ei de "player/live".
    final page = await _probe(url, readBody: true);
    if (page.kind != _ProbeKind.html) return _findInDirectory(base, null, null);

    final name = extractTitle(page.body);
    final favicon = extractFavicon(page.body, base);
    final pages = [page.body];
    for (final sub in extractPlayerPages(page.body, base)) {
      try {
        final p = await _probe(sub, readBody: true);
        if (p.kind == _ProbeKind.html) pages.add(p.body);
      } catch (_) {}
    }

    final tried = <String>{};
    for (final html in pages) {
      for (final candidate in extractStreamCandidates(html).take(10)) {
        if (!tried.add(candidate)) continue;
        final ok = await _verify(candidate);
        if (ok != null) {
          return FoundStream(streamUrl: ok, name: name, homepage: url, favicon: favicon);
        }
      }
    }

    // 3. Player încărcat din JavaScript — căutăm postul în Radio Browser.
    return _findInDirectory(base, name, favicon);
  }

  Future<FoundStream?> _findInDirectory(Uri site, String? pageTitle, String? pageFavicon) async {
    final search = directorySearch;
    if (search == null) return null;

    final host = normalizeHost(site.host);
    final queries = directoryQueriesFor(host, pageTitle);
    final country = countryFromHost(host);

    final candidates = <RadioStation>[];
    for (final q in queries) {
      try {
        candidates.addAll(await search(q, countryCode: country));
        if (country != null && candidates.isEmpty) candidates.addAll(await search(q));
      } catch (_) {}
      if (candidates.isNotEmpty) break;
    }

    for (final s in rankDirectoryMatches(candidates, host: host, country: country).take(5)) {
      final ok = await _verify(s.streamUrl);
      if (ok != null) {
        return FoundStream(
          streamUrl: ok,
          name: pageTitle ?? s.name,
          homepage: site.toString(),
          favicon: s.favicon.isNotEmpty ? s.favicon : pageFavicon,
        );
      }
    }
    return null;
  }
}

String normalizeHost(String host) => host.toLowerCase().replaceFirst(RegExp(r'^(www|m|live|radio)\.'), '');

/// Țara după domeniul de nivel superior (.gr, .ro, .tr...), dacă e unul de țară.
String? countryFromHost(String host) {
  final parts = host.split('.');
  final tld = parts.last;
  // .fm/.io/.tv/.me etc. sunt folosite global, nu indică țara.
  const generic = {'fm', 'io', 'tv', 'me', 'co', 'cc', 'ws', 'to', 'ly'};
  if (tld.length != 2 || generic.contains(tld)) {
    if (parts.length >= 3 && parts[parts.length - 2] == 'com' && tld.length == 2) return tld.toUpperCase();
    return null;
  }
  return tld == 'uk' ? 'GB' : tld.toUpperCase();
}

/// Ce căutăm în catalog: numele din domeniu ("powerturk"), varianta cu
/// spațiu înainte de "fm"/"radio" ("kiss fm") și titlul paginii.
List<String> directoryQueriesFor(String host, String? pageTitle) {
  final label = host.split('.').first;
  final queries = <String>[];
  final spaced = label
      .replaceAllMapped(RegExp(r'(fm|radio)$'), (m) => ' ${m.group(1)}')
      .replaceAllMapped(RegExp(r'^(radio)'), (m) => '${m.group(1)} ')
      .trim();
  if (spaced != label) queries.add(spaced);
  queries.add(label);
  if (pageTitle != null && pageTitle.length >= 3) queries.add(pageTitle);
  return queries;
}

String _alnum(String s) => s.toLowerCase().replaceAll(RegExp(r'[^\p{L}\p{N}]', unicode: true), '');

/// Cele mai probabile posturi pentru un site: același domeniu în homepage,
/// apoi aceeași țară, apoi cele mai ascultate.
List<RadioStation> rankDirectoryMatches(List<RadioStation> stations, {required String host, String? country}) {
  final label = _alnum(host.split('.').first);
  int score(RadioStation s) {
    int v = 0;
    final home = Uri.tryParse(s.homepage);
    if (home != null && normalizeHost(home.host) == host) v += 4;
    if (country != null && s.countryCode == country) v += 2;
    if (_alnum(s.name).contains(label) || label.contains(_alnum(s.name))) v += 1;
    return v;
  }

  final unique = {for (final s in stations) s.uuid: s}.values.where((s) => score(s) > 0).toList();
  unique.sort((a, b) {
    final d = score(b).compareTo(score(a));
    return d != 0 ? d : b.clickCount.compareTo(a.clickCount);
  });
  return unique;
}
