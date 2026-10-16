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

/// Poziția secvenței "\r\n\r\n" care încheie antetele unui răspuns HTTP/ICY
/// sau -1 dacă antetele nu au sosit încă complet.
int parseRawHeaderEnd(List<int> bytes) {
  for (var i = 0; i + 3 < bytes.length; i++) {
    if (bytes[i] == 13 && bytes[i + 1] == 10 && bytes[i + 2] == 13 && bytes[i + 3] == 10) return i;
  }
  return -1;
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

  // Tokenul rămâne la actualizări (setările aplicației se păstrează), iar o
  // copie în folderul de muzică îl recuperează și după o reinstalare.
  static File? get _tokenBackupFile =>
      Platform.isAndroid ? File('/storage/emulated/0/Music/MusicSync/.musicsync_audd_token') : null;

  static Future<String?> getToken() async {
    final prefs = await SharedPreferences.getInstance();
    final t = prefs.getString(_kTokenKey)?.trim();
    final backup = _tokenBackupFile;
    if (t != null && t.isNotEmpty) {
      // Tokenurile salvate înainte de existența copiei primesc și ele una.
      try {
        if (backup != null && !await backup.exists()) {
          await backup.parent.create(recursive: true);
          await backup.writeAsString(t, flush: true);
        }
      } catch (_) {}
      return t;
    }
    try {
      if (backup != null && await backup.exists()) {
        final restored = (await backup.readAsString()).trim();
        if (restored.isNotEmpty) {
          await prefs.setString(_kTokenKey, restored);
          return restored;
        }
      }
    } catch (_) {
      // Fără acces la stocare — doar tokenul din setări contează.
    }
    return null;
  }

  static Future<void> setToken(String? token) async {
    final prefs = await SharedPreferences.getInstance();
    final value = token?.trim() ?? '';
    final backup = _tokenBackupFile;
    if (value.isEmpty) {
      await prefs.remove(_kTokenKey);
      try {
        if (backup != null && await backup.exists()) await backup.delete();
      } catch (_) {}
    } else {
      await prefs.setString(_kTokenKey, value);
      try {
        if (backup != null) {
          await backup.parent.create(recursive: true);
          await backup.writeAsString(value, flush: true);
        }
      } catch (_) {}
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
    Uint8List data;
    try {
      data = await _captureHttp(streamUrl, maxBytes);
    } on RecognitionException {
      rethrow;
    } catch (_) {
      // Servere SHOUTcast vechi răspund "ICY 200 OK" în loc de "HTTP/1.1 200 OK"
      // și clientul HTTP le respinge ("Invalid response line") — citim direct.
      data = await _captureRaw(Uri.parse(streamUrl), maxBytes);
    }

    if (data.length < 40000) {
      throw RecognitionException('Prea puține date din stream pentru recunoaștere.');
    }
    final type = streamUrl.toLowerCase().contains('aac') ? 'aac' : 'mp3';
    final file = await _tempFile(type);
    await file.writeAsBytes(data, flush: true);
    return file;
  }

  Future<Uint8List> _captureHttp(String streamUrl, int maxBytes) async {
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
    return bytes.takeBytes();
  }

  Future<Uint8List> _captureRaw(Uri uri, int maxBytes) => captureRawStream(uri, maxBytes);

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


/// Citește stream-ul printr-un socket, acceptând atât "HTTP/1.x 200" cât și
/// "ICY 200 OK"; urmează redirecționările.
Future<Uint8List> captureRawStream(Uri uri, int maxBytes, {int redirects = 3}) async {
  final port = uri.hasPort ? uri.port : (uri.scheme == 'https' ? 443 : 80);
  const connectTimeout = Duration(seconds: 15);
  final Socket socket = uri.scheme == 'https'
      ? await SecureSocket.connect(uri.host, port, timeout: connectTimeout)
      : await Socket.connect(uri.host, port, timeout: connectTimeout);
  final path = uri.path.isEmpty ? '/' : uri.path;
  socket.write('GET ${uri.hasQuery ? '$path?${uri.query}' : path} HTTP/1.0\r\n'
      'Host: ${uri.host}\r\n'
      'User-Agent: $kHttpUserAgent\r\n'
      'Accept: */*\r\n'
      'Connection: close\r\n\r\n');

  final buffer = BytesBuilder(copy: false);
  final done = Completer<void>();
  int? bodyStart;
  Uri? redirectTo;
  void fail(Object e) => done.isCompleted ? null : done.completeError(e);

  final sub = socket.listen(
    (chunk) {
      buffer.add(chunk);
      if (bodyStart == null) {
        final all = buffer.toBytes();
        final end = parseRawHeaderEnd(all);
        if (end < 0) {
          if (all.length > 16384) fail(RecognitionException('Răspuns neașteptat de la stream.'));
          return;
        }
        final head = latin1.decode(all.sublist(0, end));
        final lines = head.split('\r\n');
        final code = int.tryParse(lines.first.split(' ').elementAtOrNull(1) ?? '');
        if (code != null && code >= 300 && code < 400) {
          final locationLine = lines.firstWhere((l) => l.toLowerCase().startsWith('location:'), orElse: () => '');
          final location = locationLine.isEmpty ? '' : locationLine.substring('location:'.length).trim();
          if (location.isNotEmpty) redirectTo = uri.resolve(location);
          if (!done.isCompleted) done.complete();
          return;
        }
        if (code != 200) {
          fail(RecognitionException('Stream-ul a răspuns: ${lines.first}'));
          return;
        }
        bodyStart = end + 4;
      }
      if (buffer.length - bodyStart! >= maxBytes && !done.isCompleted) done.complete();
    },
    onDone: () => done.isCompleted ? null : done.complete(),
    onError: fail,
    cancelOnError: true,
  );
  try {
    await done.future.timeout(const Duration(seconds: 25), onTimeout: () {});
  } finally {
    await sub.cancel();
    socket.destroy();
  }

  final target = redirectTo;
  if (target != null) {
    if (redirects <= 0) throw RecognitionException('Prea multe redirecționări ale stream-ului.');
    return captureRawStream(target, maxBytes, redirects: redirects - 1);
  }
  final start = bodyStart;
  if (start == null) throw RecognitionException('Stream-ul nu a trimis date.');
  final all = buffer.takeBytes();
  return start >= all.length ? Uint8List(0) : Uint8List.sublistView(all, start);
}
