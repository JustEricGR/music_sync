import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:file_picker/file_picker.dart';
import 'package:googleapis/youtube/v3.dart' as youtube;
import 'package:path/path.dart' as p;
import 'package:flutter_foreground_task/flutter_foreground_task.dart';

// ── Structuri de date de sprijin ──────────────────────────────────────────
class DownloadProgressInfo {
  final String currentSongTitle;
  final String statusMessage;
  final double songProgress;
  final double overallProgress;
  final int currentIndex;
  final int totalCount;
  final String logMessage;

  DownloadProgressInfo({
    required this.currentSongTitle,
    required this.statusMessage,
    required this.songProgress,
    required this.overallProgress,
    required this.currentIndex,
    required this.totalCount,
    required this.logMessage,
  });
}

class DownloadResult {
  final bool isCancelled;
  final int successCount;
  final int skippedCount;
  final List<String> failedSongs;

  DownloadResult({
    required this.isCancelled,
    required this.successCount,
    required this.skippedCount,
    required this.failedSongs,
  });
}

// ── Helper pentru notificări ──────────────────────────────────────────────
class DownloadNotificationManager {
  static Future<void> init() async {
    // Inițializare mock pentru a preveni erorile la startup
  }

  static Future<void> update({
    required String title,
    required String body,
    required int progress,
    required int maxProgress,
  }) async {}

  static Future<void> dismiss() async {}
  
  static void listenForCancelAction({required Function onCancel}) {}
}

// ── Serviciul Principal de Download ───────────────────────────────────────
class DownloadSyncService {
  bool _isCancelled = false;
  Process? _activeProcessWindows;
  HttpClient? _httpClient;

  void cancelDownload() {
    _isCancelled = true;
    try {
      if (Platform.isWindows) {
        _activeProcessWindows?.kill(ProcessSignal.sigkill);
      }
      _httpClient?.close(force: true);
    } catch (_) {}
    _activeProcessWindows = null;
    _httpClient = null;
  }

  void dispose() {
    cancelDownload();
  }

  Future<String?> selectOutputDirectory() async {
    if (Platform.isAndroid) {
      final directory = Directory('/storage/emulated/0/Music/MusicSync');
      if (!await directory.exists()) {
        await directory.create(recursive: true);
      }
      return directory.path;
    }
    return await FilePicker.platform.getDirectoryPath();
  }

  String _getYtDlpPathWindows() {
    final localExecutable = File('yt-dlp.exe');
    if (localExecutable.existsSync()) {
      return localExecutable.absolute.path;
    }
    return 'yt-dlp';
  }

  Future<DownloadResult> downloadPlaylistWithProgress({
    required String playlistTitle,
    required List<youtube.PlaylistItem> items,
    required String targetDirectoryPath,
    required Function(DownloadProgressInfo) onProgress,
  }) async {
    _isCancelled = false;
    _httpClient = HttpClient();
    // Tăiem orice verificare restrictivă de certificate
    _httpClient!.badCertificateCallback = (cert, host, port) => true;

    final safePlaylistTitle = _cleanFileName(playlistTitle);
    final playlistFolder = Directory(p.join(targetDirectoryPath, safePlaylistTitle));
    if (!await playlistFolder.exists()) {
      await playlistFolder.create(recursive: true);
    }

    int successCount = 0;
    int skippedCount = 0;
    List<String> failedSongs = [];
    final totalSongs = items.length;

    debugPrint('=== START DESCĂRCARE PLAYLIST: $playlistTitle ($totalSongs piese) ===');

    for (int i = 0; i < totalSongs; i++) {
      if (_isCancelled) {
        debugPrint('--- DESCĂRCARE ANULATĂ DE UTILIZATOR ---');
        break;
      }

      final item = items[i];
      final rawTitle = item.snippet?.title ?? 'Piesa ${i + 1}';
      final videoId = item.snippet?.resourceId?.videoId;

      if (videoId == null || videoId.isEmpty || rawTitle == 'Private video' || rawTitle == 'Deleted video') {
        failedSongs.add('$rawTitle (Video privat sau șters)');
        continue;
      }

      final safeSongTitle = _cleanFileName(rawTitle);
      final targetM4a = File(p.join(playlistFolder.path, '$safeSongTitle.m4a'));
      final targetMp3 = File(p.join(playlistFolder.path, '$safeSongTitle.mp3'));

      // Check dacă există deja
      if (await targetM4a.exists() || await targetMp3.exists()) {
        skippedCount++;
        debugPrint('[$i/$totalSongs] [SKIP] "$rawTitle" există deja pe disc.');
        onProgress(DownloadProgressInfo(
          currentSongTitle: rawTitle,
          statusMessage: 'Există deja (Sărit)',
          songProgress: 1.0,
          overallProgress: (i + 1) / totalSongs,
          currentIndex: i + 1,
          totalCount: totalSongs,
          logMessage: '[SKIP] "$rawTitle"',
        ));
        continue;
      }

      debugPrint('[$i/$totalSongs] [DESCARCĂ] Titlu: "$rawTitle" | ID: $videoId');
      
      onProgress(DownloadProgressInfo(
        currentSongTitle: rawTitle,
        statusMessage: 'Obținere stream audio...',
        songProgress: 0.0,
        overallProgress: i / totalSongs,
        currentIndex: i + 1,
        totalCount: totalSongs,
        logMessage: '[START] "$rawTitle"',
      ));

      bool downloadedSuccessfully = false;
      String lastErrorMsg = '';

      // ── PLATFORMA WINDOWS ───────────────────────────────────────────────
      if (Platform.isWindows) {
        final ytDlpExecutable = _getYtDlpPathWindows();
        final outputFilePath = targetMp3.path;

        try {
          _activeProcessWindows = await Process.start(ytDlpExecutable, [
            '-x', '--audio-format', 'mp3', '--audio-quality', '0',
            '--no-check-certificates',
            '-o', outputFilePath,
            '--no-playlist', '--newline',
            'https://www.youtube.com/watch?v=$videoId',
          ]);

          double currentSongProg = 0.0;
          final stdoutStream = _activeProcessWindows!.stdout
              .transform(utf8.decoder)
              .transform(const LineSplitter());

          final sub = stdoutStream.listen((line) {
            if (_isCancelled) return;
            if (line.contains('[download]') && line.contains('%')) {
              final match = RegExp(r'(\d+(?:\.\d+)?)%').firstMatch(line);
              if (match != null) {
                final parsedPercent = double.tryParse(match.group(1)!) ?? 0.0;
                currentSongProg = parsedPercent / 100.0;
                onProgress(DownloadProgressInfo(
                  currentSongTitle: rawTitle,
                  statusMessage: 'Descărcare: ${match.group(1)}%',
                  songProgress: currentSongProg.clamp(0.0, 1.0),
                  overallProgress: ((i + currentSongProg) / totalSongs).clamp(0.0, 1.0),
                  currentIndex: i + 1,
                  totalCount: totalSongs,
                  logMessage: '',
                ));
              }
            }
          });

          final exitCode = await _activeProcessWindows!.exitCode;
          await sub.cancel();

          if (exitCode == 0 && await targetMp3.exists()) {
            downloadedSuccessfully = true;
          } else {
            lastErrorMsg = 'yt-dlp error code $exitCode';
          }
        } catch (e) {
          lastErrorMsg = e.toString();
        } finally {
          _activeProcessWindows = null;
        }

      // ── PLATFORMA ANDROID (Public Proxies Direct Extractor) ─────────────
      // ── PLATFORMA ANDROID (Multi-API Stable Extractor) ───────────────
      } else if (Platform.isAndroid) {
        String? audioUrl;

        // Lista de API-uri verificat active (fallback rapid)
        final providers = [
          'https://pipedapi.kavin.rocks/streams/$videoId',
          'https://api.piped.privacydev.net/streams/$videoId',
          'https://invidious.privacydev.net/api/v1/videos/$videoId',
          'https://inv.nadeko.net/api/v1/videos/$videoId',
          'https://co.wuk.sh/api/json',
        ];

        for (final provider in providers) {
          if (_isCancelled) break;
          try {
            if (provider.contains('co.wuk.sh')) {
              // Cobalt Official API
              final req = await _httpClient!.postUrl(Uri.parse(provider));
              req.headers.set('Content-Type', 'application/json');
              req.headers.set('Accept', 'application/json');
              req.add(utf8.encode(jsonEncode({
                'url': 'https://www.youtube.com/watch?v=$videoId',
                'downloadMode': 'audio',
                'audioFormat': 'm4a',
              })));

              final res = await req.close().timeout(const Duration(seconds: 3));
              if (res.statusCode == 200) {
                final body = await res.transform(utf8.decoder).join();
                final json = jsonDecode(body);
                if (json['url'] != null) {
                  audioUrl = json['url'];
                  break;
                }
              }
            } else if (provider.contains('piped')) {
              // Piped API (Kavin / PrivacyDev)
              final req = await _httpClient!.getUrl(Uri.parse(provider)).timeout(const Duration(seconds: 3));
              final res = await req.close();
              if (res.statusCode == 200) {
                final body = await res.transform(utf8.decoder).join();
                final json = jsonDecode(body);
                final streams = json['audioStreams'] as List?;
                if (streams != null && streams.isNotEmpty) {
                  // Luăm piesa cu bitrate maxim
                  streams.sort((a, b) => (b['bitrate'] ?? 0).compareTo(a['bitrate'] ?? 0));
                  audioUrl = streams.first['url'];
                  break;
                }
              }
            } else {
              // Invidious API
              final req = await _httpClient!.getUrl(Uri.parse(provider)).timeout(const Duration(seconds: 3));
              final res = await req.close();
              if (res.statusCode == 200) {
                final body = await res.transform(utf8.decoder).join();
                final json = jsonDecode(body);
                final formats = json['adaptiveFormats'] as List?;
                if (formats != null) {
                  final audioOnly = formats.where((f) => f['type']?.toString().contains('audio') ?? false).toList();
                  if (audioOnly.isNotEmpty) {
                    audioOnly.sort((a, b) => (b['bitrate'] ?? 0).compareTo(a['bitrate'] ?? 0));
                    audioUrl = audioOnly.first['url'];
                    break;
                  }
                }
              }
            }
          } catch (e) {
            // Dacă un server dă timeout sau host lookup error, trece instant la următorul fără să blocheze aplicația
            debugPrint('Skip provider $provider: $e');
          }
        }

        // Descărcarea fișierului dacă am primit un URL valid
        if (audioUrl != null && !_isCancelled) {
          final outputFile = targetM4a;
          try {
            final req = await _httpClient!.getUrl(Uri.parse(audioUrl));
            req.headers.set('User-Agent', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64)');
            final res = await req.close().timeout(const Duration(seconds: 45));

            if (res.statusCode == 200 || res.statusCode == 206) {
              final totalBytes = res.contentLength;
              int downloadedBytes = 0;
              final sink = outputFile.openWrite();

              await for (final chunk in res) {
                if (_isCancelled) break;
                sink.add(chunk);
                downloadedBytes += chunk.length;

                if (totalBytes > 0) {
                  final prog = (downloadedBytes / totalBytes).clamp(0.0, 1.0);
                  onProgress(DownloadProgressInfo(
                    currentSongTitle: rawTitle,
                    statusMessage: 'Descărcare: ${(prog * 100).toInt()}%',
                    songProgress: prog,
                    overallProgress: ((i + prog) / totalSongs).clamp(0.0, 1.0),
                    currentIndex: i + 1,
                    totalCount: totalSongs,
                    logMessage: '',
                  ));
                }
              }

              await sink.flush();
              await sink.close();

              if (await outputFile.exists() && await outputFile.length() > 50000) {
                downloadedSuccessfully = true;
              } else {
                lastErrorMsg = 'Fișier gol sau incomplet.';
                if (await outputFile.exists()) await outputFile.delete();
              }
            } else {
              lastErrorMsg = 'Server Error HTTP ${res.statusCode}';
            }
          } catch (e) {
            lastErrorMsg = e.toString().split('\n').first;
            if (await outputFile.exists()) {
              try { await outputFile.delete(); } catch (_) {}
            }
          }
        } else {
          lastErrorMsg = 'Toate serverele au returnat offline.';
        }
      }

      if (downloadedSuccessfully) {
        successCount++;
        debugPrint('[$i/$totalSongs] [SUCCESS] "$rawTitle" salvat!');
        onProgress(DownloadProgressInfo(
          currentSongTitle: rawTitle,
          statusMessage: 'Salvat cu succes!',
          songProgress: 1.0,
          overallProgress: (i + 1) / totalSongs,
          currentIndex: i + 1,
          totalCount: totalSongs,
          logMessage: '[SUCCESS] "$safeSongTitle"',
        ));
      } else if (!_isCancelled) {
        failedSongs.add('$rawTitle ($lastErrorMsg)');
        debugPrint('[$i/$totalSongs] [FAILED] "$rawTitle" -> Eroare: $lastErrorMsg');
      }
    }

    _httpClient?.close(force: true);
    _httpClient = null;

    return DownloadResult(
      isCancelled: _isCancelled,
      successCount: successCount,
      skippedCount: skippedCount,
      failedSongs: failedSongs,
    );
  }

  String _cleanFileName(String name) {
    return name.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_').trim();
  }
}