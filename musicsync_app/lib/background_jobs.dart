import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:googleapis/youtube/v3.dart' as youtube;

import 'download_service.dart';
import 'library_sync.dart';

// ============================================================================
// Descărcările și sync-ul rulează aici, nu în ecrane: continuă și dacă
// părăsești ecranul, asculți muzică sau ieși din aplicație. Cât timp merg,
// un serviciu foreground (notificare "Descărcare..." / "Sync...") împiedică
// Android să oprească aplicația în fundal.
// ============================================================================

String _timestamp() => DateTime.now().toString().split('.').first.split(' ').last;

/// Serviciul foreground comun: pornit cât timp rulează cel puțin un job.
class JobForegroundService {
  JobForegroundService._();

  static bool _initialized = false;
  static bool _running = false;
  static DateTime _lastUpdate = DateTime.fromMillisecondsSinceEpoch(0);

  static bool get _supported => Platform.isAndroid;

  static void init() {
    if (!_supported || _initialized) return;
    FlutterForegroundTask.init(
      androidNotificationOptions: AndroidNotificationOptions(
        channelId: 'musicsync_jobs',
        channelName: 'Descărcări și sync',
        channelDescription: 'Progresul descărcărilor și al sincronizării bibliotecii',
        // Importanță normală (fără sunet) — altfel Samsung ascunde iconița din bara de stare.
        channelImportance: NotificationChannelImportance.DEFAULT,
        priority: NotificationPriority.DEFAULT,
        playSound: false,
        enableVibration: false,
        onlyAlertOnce: true,
      ),
      iosNotificationOptions: const IOSNotificationOptions(showNotification: false),
      foregroundTaskOptions: ForegroundTaskOptions(
        eventAction: ForegroundTaskEventAction.nothing(),
        allowWakeLock: true,
        allowWifiLock: true,
      ),
    );
    _initialized = true;
  }

  /// Arată/actualizează notificarea; [force] = ignoră limitarea la o
  /// actualizare pe secundă (pentru mesajele importante).
  static Future<void> show(String title, String text, {bool force = false}) async {
    if (!_supported) return;
    init();
    try {
      if (!_running) {
        _running = true;
        _lastUpdate = DateTime.now();
        await FlutterForegroundTask.startService(
          serviceId: 4242,
          serviceTypes: [ForegroundServiceTypes.dataSync],
          notificationTitle: title,
          notificationText: text,
        );
        return;
      }
      final now = DateTime.now();
      if (!force && now.difference(_lastUpdate) < const Duration(seconds: 1)) return;
      _lastUpdate = now;
      await FlutterForegroundTask.updateService(notificationTitle: title, notificationText: text);
    } catch (e) {
      debugPrint('[ForegroundService] $e');
    }
  }

  static Future<void> stopIfIdle() async {
    if (!_supported || !_running) return;
    if (DownloadJob.instance.isRunning || SyncJob.instance.isRunning) return;
    _running = false;
    try {
      await FlutterForegroundTask.stopService();
    } catch (e) {
      debugPrint('[ForegroundService] $e');
    }
  }
}

// ── Descărcarea unui playlist ───────────────────────────────────────────────

class DownloadOutcome {
  final DownloadResult? result;
  final int itemCount;
  final String? error;
  final bool emptyPlaylist;

  const DownloadOutcome({this.result, this.itemCount = 0, this.error, this.emptyPlaylist = false});
}

class DownloadJob extends ChangeNotifier {
  DownloadJob._();
  static final DownloadJob instance = DownloadJob._();

  final DownloadSyncService service = DownloadSyncService();

  String? playlistId;
  String playlistTitle = '';
  String currentSongTitle = '';
  String statusText = '';
  double overallProgress = 0;
  double songProgress = 0;
  bool isCancelling = false;
  final List<String> logs = [];

  bool get isRunning => playlistId != null;

  void addLog(String message) {
    if (message.isEmpty) return;
    debugPrint('[DOWNLOAD] $message');
    logs.add('${_timestamp()} - $message');
    if (logs.length > 1000) logs.removeRange(0, logs.length - 1000);
    notifyListeners();
  }

  void clearLogs() {
    logs.clear();
    notifyListeners();
  }

  void cancel() {
    if (!isRunning) return;
    addLog('[USER ACTION] Butonul STOP a fost apăsat.');
    isCancelling = true;
    statusText = 'Oprire în curs...';
    service.cancelDownload();
    notifyListeners();
  }

  Future<List<youtube.PlaylistItem>> _fetchItems(youtube.YouTubeApi api, String id) async {
    final items = <youtube.PlaylistItem>[];
    final seenTokens = <String>{};
    String? pageToken;
    try {
      do {
        final res = await api.playlistItems.list(
          ['snippet', 'contentDetails'],
          playlistId: id,
          maxResults: 50,
          pageToken: pageToken,
        ).timeout(const Duration(seconds: 30));
        items.addAll(res.items ?? []);
        pageToken = res.nextPageToken;
        // Unele playlisturi (cu videoclipuri ascunse/indisponibile) fac API-ul
        // să repete aceeași pagină la nesfârșit — descărcarea "înghețea".
        if (pageToken != null && !seenTokens.add(pageToken)) throw StateError('pagini repetate');
      } while (pageToken != null && !isCancelling);
      return items;
    } catch (e) {
      if (isCancelling) return items;
      addLog('[INFO] API-ul YouTube nu poate citi lista complet ($e) — o citesc prin yt-dlp...');
      final songs = await DownloadSyncService.listPlaylistWithYtDlp(id);
      return [
        for (final song in songs)
          youtube.PlaylistItem()
            ..snippet = (youtube.PlaylistItemSnippet()
              ..title = song.title
              ..resourceId = (youtube.ResourceId()..videoId = song.videoId)),
      ];
    }
  }

  /// Descarcă un playlist în fundal. Întoarce null dacă rulează deja altă descărcare.
  Future<DownloadOutcome?> run({
    required youtube.YouTubeApi api,
    required String playlistId,
    required String playlistTitle,
    required String targetDirectoryPath,
  }) async {
    if (isRunning) return null;
    this.playlistId = playlistId;
    this.playlistTitle = playlistTitle;
    currentSongTitle = '';
    statusText = 'Obținere melodii de la YouTube...';
    overallProgress = 0;
    songProgress = 0;
    isCancelling = false;
    notifyListeners();

    addLog('Inițiere descărcare playlist: "$playlistTitle"');
    await JobForegroundService.show('Descărcare: $playlistTitle', 'Se citește lista de melodii...', force: true);

    try {
      final items = await _fetchItems(api, playlistId);
      if (isCancelling) return DownloadOutcome(itemCount: items.length);
      if (items.isEmpty) {
        addLog('Playlist-ul este gol.');
        return const DownloadOutcome(emptyPlaylist: true);
      }
      addLog('S-au găsit ${items.length} piese în playlist.');

      final result = await service.downloadPlaylistWithProgress(
        playlistTitle: playlistTitle,
        playlistId: playlistId,
        items: items,
        targetDirectoryPath: targetDirectoryPath,
        onProgress: (info) {
          currentSongTitle = info.currentSongTitle;
          statusText = info.statusMessage;
          overallProgress = info.overallProgress;
          songProgress = info.songProgress;
          if (info.logMessage.isNotEmpty) {
            addLog(info.logMessage);
          } else {
            notifyListeners();
          }
          JobForegroundService.show(
            'Descărcare: $playlistTitle (${info.currentIndex}/${info.totalCount})',
            '${info.currentSongTitle} • ${info.statusMessage}',
          );
        },
      );

      if (result.isCancelled) {
        addLog('[STOP] Descărcare oprită de utilizator.');
      } else {
        addLog('Finalizat! Noi: ${result.successCount}, Existente: ${result.skippedCount}'
            '${result.failedSongs.isNotEmpty ? ', Erori: ${result.failedSongs.length}' : ''}');
      }
      return DownloadOutcome(result: result, itemCount: items.length);
    } catch (e) {
      addLog('[EXCEPȚIE GENERALĂ] $e');
      return DownloadOutcome(error: e.toString());
    } finally {
      this.playlistId = null;
      overallProgress = 0;
      songProgress = 0;
      isCancelling = false;
      notifyListeners();
      await JobForegroundService.stopIfIdle();
    }
  }
}

// ── Sync bibliotecă ──────────────────────────────────────────────────────────

class SyncJob extends ChangeNotifier {
  SyncJob._();
  static final SyncJob instance = SyncJob._();

  LibrarySyncService? _service;
  bool isRunning = false;
  bool isDryRun = false;
  LibrarySyncReport? lastReport;
  final List<String> logs = [];

  void _log(String message) {
    debugPrint('[SYNC] $message');
    logs.add('${_timestamp()} - $message');
    notifyListeners();
    if (isRunning && !message.startsWith('    pagina')) {
      JobForegroundService.show(isDryRun ? 'Previzualizare sync' : 'Sync bibliotecă', message.trim());
    }
  }

  void addLog(String message) => _log(message);

  void cancel() => _service?.cancel();

  Future<void> run({
    required youtube.YouTubeApi api,
    required Directory root,
    required Set<String> customPlaylistIds,
    required bool dryRun,
  }) async {
    if (isRunning) return;
    isRunning = true;
    isDryRun = dryRun;
    lastReport = null;
    logs.clear();
    notifyListeners();
    await JobForegroundService.show(dryRun ? 'Previzualizare sync' : 'Sync bibliotecă', 'Pornire...', force: true);

    final service = LibrarySyncService(api, fallbackLister: DownloadSyncService.listPlaylistWithYtDlp);
    _service = service;
    try {
      final report = await service.syncAll(
        root: root,
        customPlaylistIds: customPlaylistIds,
        onLog: _log,
        dryRun: dryRun,
      );
      lastReport = report;
      _log(report.cancelled ? '[STOP] Sync oprit.' : (dryRun ? 'Previzualizare finalizată.' : 'Sync finalizat.'));
    } catch (e) {
      _log('[EXCEPȚIE] $e');
    } finally {
      _service = null;
      isRunning = false;
      notifyListeners();
      await JobForegroundService.stopIfIdle();
    }
  }
}
