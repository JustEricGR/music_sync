import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'disk_cache.dart';

const String _kTokenKey = 'audd_api_token';
const String _kHistoryKey = 'song_recognition_history';
const int _kMaxHistory = 200;

/// Shazam nu oferă API sau autentificare pentru aplicații terțe, așa că
/// recunoașterea folosește AudD (aceeași idee: amprentă audio -> melodie),
/// cu un token personal introdus o singură dată.
const String kRecognitionDashboardUrl = 'https://dashboard.audd.io/';

class RecognizedSong {
  final String title;
  final String artist;
  final String album;
  final String releaseDate;
  final String songLink;
  final DateTime recognizedAt;

  /// Postul de radio pe care rula, dacă e cazul.
  final String? stationName;

  const RecognizedSong({
    required this.title,
    required this.artist,
    this.album = '',
    this.releaseDate = '',
    this.songLink = '',
    required this.recognizedAt,
    this.stationName,
  });

  String get youtubeSearchUrl =>
      'https://www.youtube.com/results?search_query=${Uri.encodeQueryComponent('$artist $title')}';

  Map<String, dynamic> toJson() => {
        'title': title,
        'artist': artist,
        'album': album,
        'releaseDate': releaseDate,
        'songLink': songLink,
        'recognizedAt': recognizedAt.toIso8601String(),
        if (stationName != null) 'stationName': stationName,
      };

  factory RecognizedSong.fromJson(Map<String, dynamic> j) => RecognizedSong(
        title: j['title'] as String? ?? '',
        artist: j['artist'] as String? ?? '',
        album: j['album'] as String? ?? '',
        releaseDate: j['releaseDate'] as String? ?? '',
        songLink: j['songLink'] as String? ?? '',
        recognizedAt: DateTime.tryParse(j['recognizedAt'] as String? ?? '') ?? DateTime.now(),
        stationName: j['stationName'] as String?,
      );
}

class RecognitionException implements Exception {
  final String message;
  RecognitionException(this.message);
  @override
  String toString() => message;
}

class SongRecognizer {
  final AudioRecorder _recorder = AudioRecorder();

  void dispose() {
    _recorder.dispose();
  }

  // ── Cont / token ──────────────────────────────────────────────────────────

  static Future<String?> getToken() async {
    final prefs = await SharedPreferences.getInstance();
    final t = prefs.getString(_kTokenKey);
    return (t == null || t.isEmpty) ? null : t;
  }

  static Future<void> setToken(String? token) async {
    final prefs = await SharedPreferences.getInstance();
    if (token == null || token.isEmpty) {
      await prefs.remove(_kTokenKey);
    } else {
      await prefs.setString(_kTokenKey, token);
    }
  }

  // ── Istoric ───────────────────────────────────────────────────────────────

  static Future<List<RecognizedSong>> loadHistory() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getStringList(_kHistoryKey) ?? [];
    final result = <RecognizedSong>[];
    for (final s in raw) {
      try {
        result.add(RecognizedSong.fromJson(jsonDecode(s) as Map<String, dynamic>));
      } catch (_) {}
    }
    return result;
  }

  static Future<void> addToHistory(RecognizedSong song) async {
    final history = await loadHistory();
    history.insert(0, song);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(
      _kHistoryKey,
      history.take(_kMaxHistory).map((s) => jsonEncode(s.toJson())).toList(),
    );
  }

  static Future<void> clearHistory() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_kHistoryKey);
  }

  // ── Captură audio ─────────────────────────────────────────────────────────

  Future<File> _tempFile(String ext) async {
    final dir = await getTemporaryDirectory();
    return File(p.join(dir.path, 'recognize_${DateTime.now().millisecondsSinceEpoch}.$ext'));
  }

  /// Înregistrează de la microfon.
  Future<File> recordMicrophone(Duration duration) async {
    if (!await _recorder.hasPermission()) {
      throw RecognitionException('Permisiunea pentru microfon a fost refuzată.');
    }
    final file = await _tempFile('m4a');
    await _recorder.start(
      const RecordConfig(encoder: AudioEncoder.aacLc, sampleRate: 44100, numChannels: 1),
      path: file.path,
    );
    await Future.delayed(duration);
    final path = await _recorder.stop();
    if (path == null) throw RecognitionException('Înregistrarea a eșuat.');
    return File(path);
  }

  /// Ia direct ~15 secunde din stream-ul radio (mai exact decât microfonul,
  /// fără zgomot de fundal). Nu merge pentru stream-uri HLS (.m3u8).
  Future<File> captureStream(String streamUrl, {int maxBytes = 260000}) async {
    final client = http.Client();
    final bytes = BytesBuilder(copy: false);
    try {
      final request = http.Request('GET', Uri.parse(streamUrl))..headers['User-Agent'] = kHttpUserAgent;
      final response = await client.send(request).timeout(const Duration(seconds: 15));
      if (response.statusCode != 200) {
        throw RecognitionException('Stream-ul a răspuns cu HTTP ${response.statusCode}.');
      }
      final done = Completer<void>();
      late StreamSubscription<List<int>> sub;
      sub = response.stream.listen(
        (chunk) {
          bytes.add(chunk);
          if (bytes.length >= maxBytes && !done.isCompleted) done.complete();
        },
        onDone: () => done.isCompleted ? null : done.complete(),
        onError: (Object e) => done.isCompleted ? null : done.completeError(e),
        cancelOnError: true,
      );
      await done.future.timeout(const Duration(seconds: 25), onTimeout: () {});
      await sub.cancel();
    } finally {
      client.close();
    }

    if (bytes.length < 40000) {
      throw RecognitionException('Prea puține date din stream pentru recunoaștere.');
    }
    final type = streamUrl.toLowerCase().contains('aac') ? 'aac' : 'mp3';
    final file = await _tempFile(type);
    await file.writeAsBytes(bytes.takeBytes(), flush: true);
    return file;
  }

  // ── Recunoaștere ──────────────────────────────────────────────────────────

  /// Trimite fragmentul audio la serviciu. Întoarce null dacă nu s-a găsit
  /// nicio potrivire. Fișierul temporar e șters la final.
  Future<RecognizedSong?> recognize(File audio, {required String token, String? stationName}) async {
    try {
      final request = http.MultipartRequest('POST', Uri.parse('https://api.audd.io/'))
        ..fields['api_token'] = token
        ..files.add(await http.MultipartFile.fromPath('file', audio.path));
      final streamed = await request.send().timeout(const Duration(seconds: 40));
      final body = await streamed.stream.bytesToString();
      final decoded = jsonDecode(body) as Map<String, dynamic>;

      if (decoded['status'] != 'success') {
        final err = decoded['error'];
        final message = err is Map ? (err['error_message'] ?? err['error_code']) : body;
        throw RecognitionException('Serviciul de recunoaștere: $message');
      }

      final result = decoded['result'];
      if (result is! Map) return null;

      return RecognizedSong(
        title: result['title'] as String? ?? '',
        artist: result['artist'] as String? ?? '',
        album: result['album'] as String? ?? '',
        releaseDate: result['release_date'] as String? ?? '',
        songLink: result['song_link'] as String? ?? '',
        recognizedAt: DateTime.now(),
        stationName: stationName,
      );
    } on FormatException {
      throw RecognitionException('Răspuns invalid de la serviciul de recunoaștere.');
    } finally {
      try {
        await audio.delete();
      } catch (_) {}
    }
  }
}
