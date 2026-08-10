import 'dart:async';
import 'package:youtube_explode_dart/youtube_explode_dart.dart';
import 'dart:convert';
import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:googleapis/youtube/v3.dart' as youtube;
import 'package:path/path.dart' as p;
import 'package:http/http.dart' as http;
import 'package:dio/dio.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

// ─────────────────────────────────────────────────────────────────────────────
// NOTIFICATION MINIPLAYER
//
// How it works:
//   • flutter_foreground_task keeps the process alive (foreground service).
//   • flutter_local_notifications (FLN) drives the visible notification with:
//       - a progress bar  (setProgress)
//       - song title + "X / N" subtitle
//       - a "Cancel" action button
//
// Required setup (do these ONCE in your app, before any download starts):
//
// 1. pubspec.yaml — add:
//      flutter_local_notifications: ^18.0.0   # or latest
//
// 2. AndroidManifest.xml — inside <manifest>:
//      <uses-permission android:name="android.permission.POST_NOTIFICATIONS"/>
//      <uses-permission android:name="android.permission.FOREGROUND_SERVICE"/>
//      <uses-permission android:name="android.permission.FOREGROUND_SERVICE_DATA_SYNC"/>
//
//    And inside <application>:
//      <receiver android:name="com.dexterous.flutterlocalnotifications.ActionBroadcastReceiver"
//                android:exported="false"/>
//
// 3. Call DownloadNotificationManager.init() once at app startup (e.g. main.dart):
//      await DownloadNotificationManager.init();
//
// 4. To handle the Cancel button tap from a terminated/background app, add in
//    main() before runApp():
//      DownloadNotificationManager.listenForCancelAction(onCancel: () {
//        // call your DownloadSyncService.cancelDownload() here
//      });
// ─────────────────────────────────────────────────────────────────────────────

/// Manages the download progress notification (miniplayer in the status bar).
class DownloadNotificationManager {
  DownloadNotificationManager._();

  static const int _notifId = 888;
  static const String _channelId = 'musicsync_download';
  static const String _channelName = 'MusicSync Downloads';
  // Action identifier sent when the user taps "Cancel" in the notification.
  static const String cancelActionId = 'MUSICSYNC_CANCEL_DOWNLOAD';

  static final FlutterLocalNotificationsPlugin _fln =
      FlutterLocalNotificationsPlugin();

  static Function()? _onCancelCallback;

  /// Call once at app startup.
  static Future<void> init() async {
    const androidSettings =
        AndroidInitializationSettings('@mipmap/ic_launcher');
    const initSettings = InitializationSettings(android: androidSettings);

    await _fln.initialize(
      initSettings,
      onDidReceiveNotificationResponse: _onNotificationResponse,
      onDidReceiveBackgroundNotificationResponse: _onNotificationResponse,
    );

    // Android 13+ (API 33+) requires an explicit runtime permission request.
    // Declaring POST_NOTIFICATIONS in the manifest is NOT enough on its own —
    // the user must see and accept the system popup at least once.
    // requestNotificationsPermission() is a no-op on older Android versions.
    await _fln
        .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>()
        ?.requestNotificationsPermission();
  }

  /// Register a callback that fires when the user taps "Cancel" in the notification.
  static void listenForCancelAction({required Function() onCancel}) {
    _onCancelCallback = onCancel;
  }

  @pragma('vm:entry-point')
  static void _onNotificationResponse(NotificationResponse response) {
    if (response.actionId == cancelActionId) {
      _onCancelCallback?.call();
    }
  }

  /// Show or update the miniplayer notification.
  ///
  /// [progress] and [maxProgress] drive the progress bar.
  /// Pass [indeterminate] = true while fetching the manifest (unknown progress).
  static Future<void> update({
    required String title,
    required String body,
    required int progress,
    required int maxProgress,
    bool indeterminate = false,
    bool showCancelButton = true,
  }) async {
    final androidDetails = AndroidNotificationDetails(
      _channelId,
      _channelName,
      channelDescription: 'Shows download progress for MusicSync',
      importance: Importance.low,        // low = no sound, no heads-up pop-up
      priority: Priority.low,
      onlyAlertOnce: true,               // don't re-alert on every update
      showProgress: true,
      maxProgress: maxProgress,
      progress: progress,
      indeterminate: indeterminate,
      ongoing: true,                     // user can't swipe it away mid-download
      autoCancel: false,
      // The Cancel action button:
      actions: showCancelButton
          ? [
              const AndroidNotificationAction(
                cancelActionId,
                'Anulează',               // "Cancel" in Romanian
                showsUserInterface: false,
                cancelNotification: false, // we handle cleanup ourselves
              ),
            ]
          : [],
    );

    await _fln.show(
      _notifId,
      title,
      body,
      NotificationDetails(android: androidDetails),
    );
  }

  /// Dismiss the notification when the download finishes or is cancelled.
  static Future<void> dismiss() async {
    await _fln.cancel(_notifId);
  }
}

// ─────────────────────────────────────────────────────────────────────────────

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

class DownloadSyncService {
  bool _isCancelled = false;
  Process? _activeProcess;
  YoutubeExplode? _yt;

  void cancelDownload() {
    _isCancelled = true;
    try {
      if (Platform.isWindows) {
        _activeProcess?.kill(ProcessSignal.sigkill);
      }
    } catch (_) {}
    _activeProcess = null;
  }

  void dispose() {
    cancelDownload();
    _yt?.close();
    _yt = null;
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

  String _getYtDlpPath() {
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

    final safePlaylistTitle = _cleanFileName(playlistTitle);
    final playlistFolder =
        Directory(p.join(targetDirectoryPath, safePlaylistTitle));
    if (!await playlistFolder.exists()) {
      await playlistFolder.create(recursive: true);
    }

    int successCount = 0;
    int skippedCount = 0;
    List<String> failedSongs = [];
    final totalSongs = items.length;
    final ytDlpExecutable = _getYtDlpPath();

    if (Platform.isAndroid) {
      _yt = YoutubeExplode();

      // Register cancel callback so the notification button works.
      DownloadNotificationManager.listenForCancelAction(
        onCancel: cancelDownload,
      );

      // Start the foreground service (keeps process alive when app is backgrounded).
      try {
        if (!await FlutterForegroundTask.isRunningService) {
          await FlutterForegroundTask.startService(
            notificationTitle: 'MusicSync',
            notificationText: 'Se pregătește descărcarea...',
          );
        }
      } catch (e) {
        print('Eroare la pornirea serviciului foreground: $e');
      }

      // Show the initial miniplayer notification.
      await DownloadNotificationManager.update(
        title: 'MusicSync — Se pregătește...',
        body: 'Playlist: $playlistTitle',
        progress: 0,
        maxProgress: totalSongs,
        indeterminate: true,
      );
    }

    try {
      for (int i = 0; i < totalSongs; i++) {
        if (_isCancelled) break;

        final item = items[i];
        final rawTitle = item.snippet?.title ?? 'Piesa ${i + 1}';
        final videoId = item.snippet?.resourceId?.videoId;

        if (videoId == null ||
            videoId.isEmpty ||
            rawTitle == 'Private video' ||
            rawTitle == 'Deleted video') {
          failedSongs.add('$rawTitle (Indisponibil / Șters pe YouTube)');
          onProgress(DownloadProgressInfo(
            currentSongTitle: rawTitle,
            statusMessage: 'Videoclip indisponibil pe YouTube',
            songProgress: 0.0,
            overallProgress: (i + 1) / totalSongs,
            currentIndex: i + 1,
            totalCount: totalSongs,
            logMessage: '[ERROR] "$rawTitle" este privat sau șters de pe YouTube.',
          ));
          continue;
        }

        final videoUrl = 'https://www.youtube.com/watch?v=$videoId';
        final safeSongTitle = _cleanFileName(rawTitle);
        final fileExtension = Platform.isAndroid ? 'm4a' : 'mp3';
        final outputFilePath =
            p.join(playlistFolder.path, '$safeSongTitle.$fileExtension');

        if (await File(outputFilePath).exists()) {
          skippedCount++;
          onProgress(DownloadProgressInfo(
            currentSongTitle: rawTitle,
            statusMessage: 'Există deja pe disc (Sărit)',
            songProgress: 1.0,
            overallProgress: (i + 1) / totalSongs,
            currentIndex: i + 1,
            totalCount: totalSongs,
            logMessage: '[SKIP] "$rawTitle" există deja în folder. Se continuă...',
          ));
          continue;
        }

        onProgress(DownloadProgressInfo(
          currentSongTitle: rawTitle,
          statusMessage: 'Inițializare...',
          songProgress: 0.0,
          overallProgress: i / totalSongs,
          currentIndex: i + 1,
          totalCount: totalSongs,
          logMessage: '[START] Piesa ${i + 1}/$totalSongs: "$rawTitle"',
        ));

        bool downloadedSuccessfully = false;
        String lastErrorMsg = '';

        // ── WINDOWS ────────────────────────────────────────────────────────
        if (Platform.isWindows) {
          for (int attempt = 1; attempt <= 2; attempt++) {
            if (_isCancelled) break;

            try {
              _activeProcess = await Process.start(ytDlpExecutable, [
                '-x',
                '--audio-format', 'mp3',
                '--audio-quality', '0',
                '--no-check-certificates',
                '--prefer-free-formats',
                '-o', outputFilePath,
                '--no-playlist',
                '--newline',
                videoUrl,
              ]);

              double currentSongProg = 0.0;

              final stdoutStream = _activeProcess!.stdout
                  .transform(utf8.decoder)
                  .transform(const LineSplitter());

              final sub = stdoutStream.listen((line) {
                if (_isCancelled) return;
                if (line.contains('[download]') && line.contains('%')) {
                  final match =
                      RegExp(r'(\d+(?:\.\d+)?)%').firstMatch(line);
                  if (match != null) {
                    final parsedPercent =
                        double.tryParse(match.group(1)!) ?? 0.0;
                    currentSongProg = parsedPercent / 100.0;
                    onProgress(DownloadProgressInfo(
                      currentSongTitle: rawTitle,
                      statusMessage: 'Descărcare: ${match.group(1)}%',
                      songProgress: currentSongProg.clamp(0.0, 1.0),
                      overallProgress:
                          ((i + currentSongProg) / totalSongs).clamp(0.0, 1.0),
                      currentIndex: i + 1,
                      totalCount: totalSongs,
                      logMessage: '',
                    ));
                  }
                }
              });

              final exitCode = await _activeProcess!.exitCode;
              await sub.cancel();

              if (_isCancelled) break;

              if (exitCode == 0 && await File(outputFilePath).exists()) {
                downloadedSuccessfully = true;
                break;
              } else {
                lastErrorMsg = 'yt-dlp s-a oprit cu codul: $exitCode';
              }
            } catch (e) {
              lastErrorMsg = e.toString().split('\n').first;
            } finally {
              _activeProcess = null;
            }

            if (attempt == 1 && !_isCancelled) {
              onProgress(DownloadProgressInfo(
                currentSongTitle: rawTitle,
                statusMessage: 'Reîncercare (Attempt 2)...',
                songProgress: 0.0,
                overallProgress: i / totalSongs,
                currentIndex: i + 1,
                totalCount: totalSongs,
                logMessage:
                    '[RETRY] Se reîncearcă descărcarea pentru "$rawTitle"...',
              ));
              await Future.delayed(const Duration(seconds: 2));
            }
          }

        // ── ANDROID ────────────────────────────────────────────────────────
        } else if (Platform.isAndroid) {
          final preferredClients = [
            YoutubeApiClient.ios,
            YoutubeApiClient.androidVr,
          ];

          for (int attempt = 1; attempt <= 2; attempt++) {
            if (_isCancelled) break;

            final partialFile = File(outputFilePath);
            if (await partialFile.exists()) await partialFile.delete();

            try {
              // Notification: indeterminate while fetching manifest.
              await DownloadNotificationManager.update(
                title: rawTitle,
                body: 'Conectare... • Piesa ${i + 1} din $totalSongs',
                progress: 0,
                maxProgress: 100,
                indeterminate: true,
              );

              onProgress(DownloadProgressInfo(
                currentSongTitle: rawTitle,
                statusMessage: 'Conectare la YouTube...',
                songProgress: 0.1,
                overallProgress: i / totalSongs,
                currentIndex: i + 1,
                totalCount: totalSongs,
                logMessage: 'Se extrag metadatele audio (attempt $attempt)...',
              ));

              final manifest = await _yt!.videos.streams
                  .getManifest(
                    videoId.trim(),
                    ytClients: preferredClients,
                  )
                  .timeout(
                    const Duration(seconds: 20),
                    onTimeout: () => throw TimeoutException(
                        'Manifest timeout după 20s. Se reîncearcă...'),
                  );

              final audioStreams = manifest.audioOnly;
              if (audioStreams.isEmpty) {
                throw Exception(
                    'Niciun flux audio disponibil pentru acest videoclip.');
              }
              final audioStreamInfo = audioStreams.withHighestBitrate();

              final stream = _yt!.videos.streams.get(audioStreamInfo);
              final file = File(outputFilePath);
              final sink = file.openWrite();

              final totalBytes = audioStreamInfo.size.totalBytes;
              int bytesDownloaded = 0;
              bool streamError = false;

              // Throttle notification updates to at most once per 1 %
              // to avoid flooding the Android notification manager.
              int lastNotifPercent = -1;

              try {
                await for (final chunk in stream) {
                  if (_isCancelled) {
                    streamError = true;
                    break;
                  }
                  sink.add(chunk);
                  bytesDownloaded += chunk.length as int;

                  final currentSongProg =
                      (bytesDownloaded / totalBytes).clamp(0.0, 1.0);
                  final currentOverall =
                      ((i + currentSongProg) / totalSongs).clamp(0.0, 1.0);
                  final percent = (currentSongProg * 100).toInt();

                  // Only push a notification update when the integer % changes.
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
                }
              } finally {
                await sink.flush();
                await sink.close();
              }

              if (streamError || _isCancelled) {
                if (await file.exists()) await file.delete();
                break;
              }

              downloadedSuccessfully = true;
              break;
            } catch (e) {
              lastErrorMsg = e.toString().split('\n').first;

              if (attempt < 2 && !_isCancelled) {
                final delay = Duration(seconds: 3 * attempt);
                onProgress(DownloadProgressInfo(
                  currentSongTitle: rawTitle,
                  statusMessage: 'Reîncercare în ${delay.inSeconds}s...',
                  songProgress: 0.0,
                  overallProgress: i / totalSongs,
                  currentIndex: i + 1,
                  totalCount: totalSongs,
                  logMessage:
                      '[RETRY] "$rawTitle" attempt $attempt eșuat: $lastErrorMsg',
                ));
                await Future.delayed(delay);
              }
            }
          }
        }

        // ── Result reporting ──────────────────────────────────────────────
        if (downloadedSuccessfully) {
          successCount++;
          onProgress(DownloadProgressInfo(
            currentSongTitle: rawTitle,
            statusMessage: 'Salvat cu succes!',
            songProgress: 1.0,
            overallProgress: (i + 1) / totalSongs,
            currentIndex: i + 1,
            totalCount: totalSongs,
            logMessage:
                '[SUCCESS] Salvare audio în "$safePlaylistTitle/$safeSongTitle.$fileExtension"',
          ));
        } else if (!_isCancelled) {
          failedSongs.add('$rawTitle ($lastErrorMsg)');
          onProgress(DownloadProgressInfo(
            currentSongTitle: rawTitle,
            statusMessage: 'Eroare la descărcare',
            songProgress: 0.0,
            overallProgress: (i + 1) / totalSongs,
            currentIndex: i + 1,
            totalCount: totalSongs,
            logMessage: '[ERROR] "$rawTitle": $lastErrorMsg',
          ));
        }
      }
    } finally {
      try {
        if (Platform.isWindows) _activeProcess?.kill();
      } catch (_) {}

      if (Platform.isAndroid) {
        // Dismiss the progress notification.
        await DownloadNotificationManager.dismiss();

        // Stop the foreground service.
        try {
          if (await FlutterForegroundTask.isRunningService) {
            await FlutterForegroundTask.stopService();
          }
        } catch (_) {}
      }

      _yt?.close();
      _yt = null;
    }

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