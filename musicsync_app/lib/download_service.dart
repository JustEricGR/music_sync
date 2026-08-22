import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:file_picker/file_picker.dart';
import 'package:googleapis/youtube/v3.dart' as youtube;
import 'package:path/path.dart' as p;
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';
import 'playlist_manifest.dart';


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
  static const MethodChannel _ytDlpChannel =
    MethodChannel('musicsync/ytdlp');

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

  Future<bool> _ensureAndroidStoragePermission() async {
    if (!Platform.isAndroid) return true;
    if (await Permission.manageExternalStorage.isGranted) return true;

    final status = await Permission.manageExternalStorage.request();
    return status.isGranted;
  }

  Future<String?> selectOutputDirectory() async {
    if (Platform.isAndroid) {
      if (!await _ensureAndroidStoragePermission()) {
        return null;
      }

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

    if (!await _ensureAndroidStoragePermission()) {
      return DownloadResult(
        isCancelled: false,
        successCount: 0,
        skippedCount: 0,
        failedSongs: [
          'Permisiune de stocare lipsă. Activează "Acces la toate '
              'fișierele" pentru MusicSync din Setări și încearcă din nou.',
        ],
      );
    }

    _httpClient = HttpClient();
    // Tăiem orice verificare restrictivă de certificate
    _httpClient!.badCertificateCallback = (cert, host, port) => true;

    final safePlaylistTitle = _cleanFileName(playlistTitle);
    final playlistFolder = Directory(p.join(targetDirectoryPath, safePlaylistTitle));
    if (!await playlistFolder.exists()) {
      await playlistFolder.create(recursive: true);
    }

    // Melodii deja descărcate în ALTE playlisturi — le copiem în loc să le
    // redescărcăm prin yt-dlp.
    final crossPlaylistIndex = await PlaylistManifest.buildCrossPlaylistIndex(
      rootDir: Directory(targetDirectoryPath),
      excludeFolder: playlistFolder,
    );

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

      // Check dacă există deja — întâi prin manifest (după videoId, robust
      // la titluri modificate), apoi fallback pe verificarea veche a căii
      // (compatibilitate cu fișiere descărcate înainte de manifest).
      final existingSongs = await PlaylistManifest.getOrderedSongs(playlistFolder);
      final alreadyTracked = existingSongs.any((s) => s.videoId == videoId);
      final alreadyOnDiskLegacy = !alreadyTracked && (await targetM4a.exists() || await targetMp3.exists());

      if (alreadyOnDiskLegacy) {
        final legacyFile = await targetM4a.exists() ? targetM4a : targetMp3;
        await PlaylistManifest.insertSong(playlistFolder, PlaylistSongEntry(
          videoId: videoId,
          fileName: p.basename(legacyFile.path),
          title: rawTitle,
          sourceIndex: i,
        ));
      }

      if (alreadyTracked || alreadyOnDiskLegacy) {
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
      String? savedFilePath;

      // ── COPIERE DIN ALT PLAYLIST (evită redescărcarea) ──────────────────
      final crossHit = crossPlaylistIndex[videoId];
      if (crossHit != null) {
        try {
          final destPath = p.join(playlistFolder.path, p.basename(crossHit.file.path));
          final copied = await crossHit.file.copy(destPath);
          downloadedSuccessfully = true;
          savedFilePath = copied.path;
          debugPrint(
            '[$i/$totalSongs] [COPY] "$rawTitle" copiat din playlistul "${crossHit.playlistFolderName}".',
          );
        } catch (e) {
          // Nu eșuăm melodia doar pentru că fast-path-ul de copiere a
          // picat — mergem mai departe cu descărcarea normală.
          debugPrint('[$i/$totalSongs] [COPY FAILED] $e — se încearcă descărcare normală.');
        }
      }

      // ── PLATFORMA WINDOWS ───────────────────────────────────────────────
      if (!downloadedSuccessfully && Platform.isWindows) {
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
            savedFilePath = targetMp3.path;
          } else {
            lastErrorMsg = 'yt-dlp error code $exitCode';
          }
        } catch (e) {
          lastErrorMsg = e.toString();
        } finally {
          _activeProcessWindows = null;
        }

      } else if (!downloadedSuccessfully && Platform.isAndroid) {
        try {
          onProgress(DownloadProgressInfo(
            currentSongTitle: rawTitle,
            statusMessage: 'Pregătire yt-dlp local...',
            songProgress: 0.0,
            overallProgress: i / totalSongs,
            currentIndex: i + 1,
            totalCount: totalSongs,
            logMessage: '[LOCAL YT-DLP] Se descarcă "$rawTitle"...',
          ));

          await DownloadNotificationManager.update(
            title: rawTitle,
            body: 'Descărcare locală • Piesa ${i + 1} din $totalSongs',
            progress: 0,
            maxProgress: 100,
          );

          final baseOutputPath = p.join(playlistFolder.path, safeSongTitle);

          final dynamic response = await _ytDlpChannel.invokeMethod(
            'downloadAudio',
            {
              'videoId': videoId,
              'outputPath': baseOutputPath,
            },
          );

          if (_isCancelled) {
            break;
          }

          if (response == null) {
            throw Exception('Nu s-a primit răspuns de la yt-dlp local.');
          }

          final Map<dynamic, dynamic> result =
              Map<dynamic, dynamic>.from(response);

          final bool success = result['success'] == true;
          final String returnedPath = result['path']?.toString() ?? '';
          final String error = result['error']?.toString() ?? '';

          if (!success) {
            throw Exception(error.isNotEmpty ? error : 'yt-dlp local a eșuat.');
          }

          if (returnedPath.isEmpty) {
            throw Exception('yt-dlp nu a returnat calea fișierului.');
          }

          final outputFile = File(returnedPath);

          if (!await outputFile.exists()) {
            throw Exception('Fișierul rezultat nu există: $returnedPath');
          }

          final size = await outputFile.length();

          if (size < 50000) {
            try {
              await outputFile.delete();
            } catch (_) {}

            throw Exception('Fișier incomplet: $size bytes');
          }

          downloadedSuccessfully = true;
          savedFilePath = returnedPath;

          debugPrint(
            '[YT-DLP LOCAL SUCCESS] $returnedPath ($size bytes)',
          );
        } catch (e) {
          lastErrorMsg = e.toString().split('\n').first;

          debugPrint('[YT-DLP LOCAL ERROR] $lastErrorMsg');
        }
      }

      if (downloadedSuccessfully && savedFilePath != null) {
        await PlaylistManifest.insertSong(playlistFolder, PlaylistSongEntry(
          videoId: videoId,
          fileName: p.basename(savedFilePath),
          title: rawTitle,
          sourceIndex: i,
        ));
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