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

      } else if (Platform.isAndroid) {
  for (int attempt = 1; attempt <= 3; attempt++) {
    if (_isCancelled) break;

    HttpClient? client;
    IOSink? sink;
    File? currentOutputFile;

    try {
      await DownloadNotificationManager.update(
        title: rawTitle,
        body: 'Pregătire audio... • Piesa ${i + 1} din $totalSongs',
        progress: 0,
        maxProgress: 100,
      );

      onProgress(DownloadProgressInfo(
        currentSongTitle: rawTitle,
        statusMessage: 'Serverul pregătește audio...',
        songProgress: 0.0,
        overallProgress: i / totalSongs,
        currentIndex: i + 1,
        totalCount: totalSongs,
        logMessage:
            '[SERVER] Se solicită "$rawTitle" de la MusicSync API (attempt $attempt)...',
      ));

      final uri = Uri.parse(
        'https://music-sync-efl7.onrender.com/download/$videoId',
      );

      client = HttpClient();

      // Render Free poate avea cold start, deci îi dăm timp.
      client.connectionTimeout = const Duration(seconds: 90);

      final request = await client.getUrl(uri);

      final response = await request.close().timeout(
        const Duration(minutes: 4),
      );

      if (_isCancelled) {
        client.close(force: true);
        break;
      }

      if (response.statusCode != HttpStatus.ok) {
        String errorBody = '';

        try {
          errorBody = await response
              .transform(utf8.decoder)
              .join()
              .timeout(
                const Duration(seconds: 15),
                onTimeout: () => '',
              );
        } catch (_) {}

        throw HttpException(
          'Server HTTP ${response.statusCode}'
          '${errorBody.isNotEmpty ? ': $errorBody' : ''}',
        );
      }

      // Backendul nostru trimite extensia reală.
      final serverExtension =
          response.headers.value('x-musicsync-extension') ?? 'm4a';

      final normalizedExtension = serverExtension
          .replaceAll('.', '')
          .trim()
          .toLowerCase();

      final actualExtension =
          normalizedExtension.isEmpty ? 'm4a' : normalizedExtension;

      final finalOutputPath = p.join(
        playlistFolder.path,
        '$safeSongTitle.$actualExtension',
      );

      currentOutputFile = File(finalOutputPath);

      // Dacă a rămas un fișier parțial de la o încercare precedentă,
      // îl ștergem înainte.
      if (await currentOutputFile.exists()) {
        await currentOutputFile.delete();
      }

      sink = currentOutputFile.openWrite();

      final totalBytes = response.contentLength;
      int bytesDownloaded = 0;
      int lastNotifPercent = -1;

      onProgress(DownloadProgressInfo(
        currentSongTitle: rawTitle,
        statusMessage: 'Începe descărcarea...',
        songProgress: 0.0,
        overallProgress: i / totalSongs,
        currentIndex: i + 1,
        totalCount: totalSongs,
        logMessage:
            '[DOWNLOAD] Serverul a pregătit "$rawTitle". Încep transferul...',
      ));

      await for (final chunk in response.timeout(
        const Duration(seconds: 45),
      )) {
        if (_isCancelled) {
          break;
        }

        sink.add(chunk);
        bytesDownloaded += chunk.length;

        if (totalBytes > 0) {
          final currentSongProg =
              (bytesDownloaded / totalBytes).clamp(0.0, 1.0);

          final currentOverall =
              ((i + currentSongProg) / totalSongs).clamp(0.0, 1.0);

          final percent = (currentSongProg * 100).round();

          if (percent != lastNotifPercent) {
            lastNotifPercent = percent;

            await DownloadNotificationManager.update(
              title: rawTitle,
              body: '$percent% • Piesa ${i + 1} din $totalSongs',
              progress: percent,
              maxProgress: 100,
            );
          }

          onProgress(DownloadProgressInfo(
            currentSongTitle: rawTitle,
            statusMessage: 'Descărcare: $percent%',
            songProgress: currentSongProg,
            overallProgress: currentOverall,
            currentIndex: i + 1,
            totalCount: totalSongs,
            logMessage: '',
          ));
        } else {
          // În caz că Render nu trimite Content-Length.
          onProgress(DownloadProgressInfo(
            currentSongTitle: rawTitle,
            statusMessage: 'Se descarcă audio...',
            songProgress: 0.5,
            overallProgress:
                ((i + 0.5) / totalSongs).clamp(0.0, 1.0),
            currentIndex: i + 1,
            totalCount: totalSongs,
            logMessage: '',
          ));
        }
      }

      await sink.flush();
      await sink.close();
      sink = null;

      client.close();
      client = null;

      if (_isCancelled) {
        if (currentOutputFile != null &&
            await currentOutputFile.exists()) {
          await currentOutputFile.delete();
        }

        break;
      }

      if (currentOutputFile == null ||
          !await currentOutputFile.exists()) {
        throw Exception(
          'Fișierul audio nu a fost creat după download.',
        );
      }

      final downloadedSize = await currentOutputFile.length();

      if (downloadedSize < 50000) {
        await currentOutputFile.delete();

        throw Exception(
          'Fișier audio invalid sau incomplet '
          '($downloadedSize bytes).',
        );
      }

      downloadedSuccessfully = true;

      debugPrint(
        '[DL] SUCCESS SERVER: '
        '"$rawTitle" -> ${currentOutputFile.path} '
        '($downloadedSize bytes)',
      );

      onProgress(DownloadProgressInfo(
        currentSongTitle: rawTitle,
        statusMessage: 'Salvat cu succes!',
        songProgress: 1.0,
        overallProgress: (i + 1) / totalSongs,
        currentIndex: i + 1,
        totalCount: totalSongs,
        logMessage:
            '[SUCCESS] "$rawTitle" descărcat prin MusicSync Server.',
      ));

      break;
    } catch (e) {
      try {
        await sink?.flush();
      } catch (_) {}

      try {
        await sink?.close();
      } catch (_) {}

      sink = null;

      try {
        client?.close(force: true);
      } catch (_) {}

      client = null;

      lastErrorMsg = e.toString().split('\n').first;

      debugPrint(
        '[DL] SERVER ERROR attempt $attempt: $lastErrorMsg',
      );

      // Ștergem fișierul incomplet.
      if (currentOutputFile != null) {
        try {
          if (await currentOutputFile.exists()) {
            await currentOutputFile.delete();
          }
        } catch (_) {}
      }

      if (attempt < 3 && !_isCancelled) {
        final delay = Duration(seconds: 3 * attempt);

        onProgress(DownloadProgressInfo(
          currentSongTitle: rawTitle,
          statusMessage:
              'Reîncercare în ${delay.inSeconds}s...',
          songProgress: 0.0,
          overallProgress: i / totalSongs,
          currentIndex: i + 1,
          totalCount: totalSongs,
          logMessage:
              '[RETRY] Server attempt $attempt eșuat pentru '
              '"$rawTitle": $lastErrorMsg',
        ));

        await Future.delayed(delay);
      }
    } finally {
      try {
        await sink?.flush();
      } catch (_) {}

      try {
        await sink?.close();
      } catch (_) {}

      try {
        client?.close(force: true);
      } catch (_) {}
    }
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