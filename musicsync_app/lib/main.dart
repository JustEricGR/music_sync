import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle, MethodChannel;
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:http/http.dart' as http;
import 'package:googleapis/youtube/v3.dart' as youtube;
import 'package:googleapis_auth/auth_io.dart';
import 'package:google_sign_in_all_platforms/google_sign_in_all_platforms.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:just_audio/just_audio.dart';
import 'package:just_audio_background/just_audio_background.dart';
import 'package:audio_session/audio_session.dart';
import 'package:provider/provider.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'dart:math';

// Importurile tale de teme și widget-uri
import 'themes/theme_provider.dart';
import 'themes/app_themes.dart';
import 'widgets/dynamic_player.dart';
import 'download_service.dart';
import 'playlist_manifest.dart';
import 'library_sync.dart';
import 'library_sync_screen.dart';
import 'background_jobs.dart';
import 'themes/country_detector.dart';
import 'themes/theme_photos.dart';
import 'themes/theme_photos_screen.dart';
import 'radio/disk_cache.dart';
import 'radio/radio_screen.dart';
import 'radio/radio_station.dart';
import 'radio/radio_favorites.dart';

// ==========================================
// ENUMERATIONS
// ==========================================
enum SongMood {
  chill,
  hype,
  energetic,
  acoustic,
  party,
}

enum SongSortOrder { oldestFirst, newestFirst, custom }

// ==========================================
// METADATA PARSER
// ==========================================
class SongMetadata {
  final String artist;
  final String title;

  SongMetadata({required this.artist, required this.title});
}

SongMetadata parseArtistAndTitle(String rawName) {
  final cleanName = rawName.replaceAll(RegExp(r'\.(mp3|m4a|wav)$', caseSensitive: false), '').trim();

  final separators = [' - ', ' – ', ' — ', ' : ', ' ~ '];
  for (var sep in separators) {
    if (cleanName.contains(sep)) {
      final parts = cleanName.split(sep);
      if (parts.length >= 2) {
        return SongMetadata(
          artist: parts[0].trim(),
          title: parts.sublist(1).join(sep).trim(),
        );
      }
    }
  }

  return SongMetadata(
    artist: 'Artist Necunoscut',
    title: cleanName,
  );
}

// ==========================================
// LOCAL LIBRARY DATA MODEL
// ==========================================
class LocalPlaylistModel {
  final String title;
  final Directory directory;
  final List<File> audioFiles;
  final int? totalYoutubeCount;

  LocalPlaylistModel({
    required this.title,
    required this.directory,
    required this.audioFiles,
    this.totalYoutubeCount,
  });
}

// ==========================================
// SINGLETON GOOGLE SIGN IN MANAGER
// ==========================================
class GoogleAuthManager {
  static GoogleSignIn? _instance;

  static GoogleSignIn get instance {
    if (_instance == null) {
      const String webClientId = '1088119046091-88mnpgv9gbj9991uuhiqi1iidl3pbu2i.apps.googleusercontent.com';
      const String desktopClientId = '1088119046091-es03n3ils67dt7kf2s97h7rt8u97bevq.apps.googleusercontent.com';

      if (kIsWeb) {
        _instance = GoogleSignIn(
          params: const GoogleSignInParams(
            clientId: webClientId,
            scopes: [
              youtube.YouTubeApi.youtubeReadonlyScope,
              'https://www.googleapis.com/auth/userinfo.email',
            ],
          ),
        );
      } else if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
        _instance = GoogleSignIn(
          params: const GoogleSignInParams(
            clientId: desktopClientId,
            clientSecret: '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',
            scopes: [
              youtube.YouTubeApi.youtubeReadonlyScope,
              'https://www.googleapis.com/auth/userinfo.email',
            ],
          ),
        );
      } else {
        _instance = GoogleSignIn(
          params: const GoogleSignInParams(
            clientId: webClientId,
            scopes: [
              youtube.YouTubeApi.youtubeReadonlyScope,
              'https://www.googleapis.com/auth/userinfo.email',
            ],
          ),
        );
      }
    }
    return _instance!;
  }

  static youtube.YouTubeApi youtubeApiFor(GoogleSignInCredentials credentials) {
    final authClient = authenticatedClient(
      http.Client(),
      AccessCredentials(
        AccessToken('Bearer', credentials.accessToken, DateTime.now().toUtc().add(const Duration(hours: 1))),
        null,
        [youtube.YouTubeApi.youtubeReadonlyScope, 'https://www.googleapis.com/auth/userinfo.email'],
      ),
    );
    return youtube.YouTubeApi(authClient);
  }
}

// ==========================================
// GLOBAL AUDIO PLAYER STATE (PROVIDER)
// ==========================================
class GlobalAudioState extends ChangeNotifier {
  static final GlobalAudioState instance = GlobalAudioState._internal();
  factory GlobalAudioState() => instance;
  GlobalAudioState._internal() {
    _initListeners();
    // Sincronizare imediată din player: dacă acest singleton e reconstruit
    // (de ex. Activity-ul Android a fost recreat) în timp ce serviciul de
    // redare în fundal era deja activ, câmpurile de mai sus altfel ar
    // rămâne la valorile implicite (poziție 0 etc.) până la următorul
    // eveniment din stream — ceea ce arăta "cântă de la început" în UI deși
    // redarea efectivă continua corect de unde rămăsese.
    _syncFromPlayer();
  }

  void _syncFromPlayer() {
    position = audioPlayer.position;
    duration = audioPlayer.duration ?? Duration.zero;
    isPlaying = audioPlayer.playing;

    final seqState = audioPlayer.sequenceState;
    if (seqState != null && seqState.currentIndex >= 0) {
      currentIndex = seqState.currentIndex;
    }
  }

  final AudioPlayer audioPlayer = AudioPlayer(
    // Buffer mai mare: stream-urile radio rezistă la scurte căderi de rețea
    // (implicit ~50 s maxim și pornire după 2,5 s).
    audioLoadConfiguration: const AudioLoadConfiguration(
      androidLoadControl: AndroidLoadControl(
        minBufferDuration: Duration(seconds: 30),
        maxBufferDuration: Duration(seconds: 120),
        bufferForPlaybackDuration: Duration(seconds: 3),
        bufferForPlaybackAfterRebufferDuration: Duration(seconds: 8),
      ),
    ),
  );

  static const MethodChannel _wifiLockChannel = MethodChannel('musicsync/wifilock');
  bool _wifiLockHeld = false;

  /// Crește la fiecare post nou pornit — răspunsurile întârziate ale
  /// postului anterior (încărcare, metadate) sunt ignorate.
  int _radioGeneration = 0;

  /// Utilizatorul vrea radio pornit (nu l-a pus pe pauză) — doar atunci
  /// reconectăm automat când stream-ul cade.
  bool _radioWanted = false;
  int _reconnectAttempts = 0;
  Timer? _reconnectTimer;

  /// Mesaj de stare pentru radio (ex. "Reconectare..."), afișat în mini-player.
  String? radioStatus;

  /// De unde a fost pornit postul pe hartă (orașul), ca mini-playerul să
  /// poată redeschide lista acelui oraș cu postul selectat.
  ({double lat, double lon, double zoom})? radioMapContext;

  List<File> playlistFiles = [];
  int currentIndex = 0;
  bool isPlaying = false;
  SongMood currentMood = SongMood.chill;

  String currentSongTitle = "";
  String currentArtist = "";
  String? currentPlaylistTitle;
  LocalPlaylistModel? currentPlaylistModel;

  Duration duration = Duration.zero;
  Duration position = Duration.zero;

  /// Postul de radio care rulează (null când se redă un playlist local).
  RadioStation? currentRadio;

  /// Titlul transmis de post în stream (metadate ICY), dacă există.
  String? radioNowPlaying;

  void _initListeners() {
    audioPlayer.icyMetadataStream.listen((icy) {
      final radio = currentRadio;
      if (radio == null) return;
      // Metadatele întârziate ale postului anterior nu au voie să le
      // suprascrie pe ale celui curent.
      final tag = audioPlayer.sequenceState?.currentSource?.tag;
      if (tag is! MediaItem || tag.id != 'radio:${radio.uuid}') return;
      final title = icy?.info?.title?.trim();
      radioNowPlaying = (title == null || title.isEmpty) ? null : title;
      notifyListeners();
    });

    audioPlayer.playerStateStream.listen((state) {
      isPlaying = state.playing;
      final radioActive = currentRadio != null;
      _setWifiLock(radioActive && state.playing);

      if (radioActive) {
        if (state.playing && state.processingState == ProcessingState.ready) {
          _reconnectAttempts = 0;
          radioStatus = null;
        } else if (state.processingState == ProcessingState.completed) {
          // Un stream live nu se "termină" — conexiunea a căzut.
          _scheduleRadioReconnect();
        }
      }
      notifyListeners();
    });

    audioPlayer.playbackEventStream.listen(
      (_) {},
      onError: (Object e, StackTrace _) {
        debugPrint('[Audio] eroare redare: $e');
        if (currentRadio != null) _scheduleRadioReconnect();
      },
    );

    audioPlayer.durationStream.listen((d) {
      duration = d ?? Duration.zero;
      notifyListeners();
    });

    audioPlayer.positionStream.listen((p) {
      position = p;
      notifyListeners();
    });

    audioPlayer.sequenceStateStream.listen((seqState) {
      if (seqState == null) return;
      currentIndex = seqState.currentIndex;
      if (currentIndex >= 0 && currentIndex < playlistFiles.length) {
        final file = playlistFiles[currentIndex];
        final fileName = file.path.split(Platform.pathSeparator).last;
        final meta = parseArtistAndTitle(fileName);
        currentSongTitle = meta.title;
        currentArtist = meta.artist;
        notifyListeners();
      }
    });
  }

  Uri? _artUriCache;

  /// Extrage assetul Flutter `assets/yugoslavia.jpg` într-un fișier real pe
  /// disc și întoarce un URI `file://` către el. Notificarea de redare
  /// Android (audio_service) NU poate rezolva scheme `asset:///` — acelea
  /// sunt înțelese doar de widget-urile Flutter, nu de codul nativ care
  /// încarcă imaginea pentru notificare/lock screen; are nevoie fie de
  /// `content://`, fie de un fișier real (`file://`), altfel imaginea nu
  /// apare deloc (eșuează silențios).
  Future<Uri> _resolveArtUri() async {
    if (_artUriCache != null) return _artUriCache!;

    final byteData = await rootBundle.load('assets/yugoslavia.jpg');
    final dir = await getTemporaryDirectory();
    final file = File('${dir.path}${Platform.pathSeparator}notification_art_yugoslavia.jpg');

    if (!await file.exists()) {
      await file.writeAsBytes(
        byteData.buffer.asUint8List(byteData.offsetInBytes, byteData.lengthInBytes),
        flush: true,
      );
    }

    _artUriCache = Uri.file(file.path);
    return _artUriCache!;
  }

  void _setWifiLock(bool held) {
    if (!Platform.isAndroid || held == _wifiLockHeld) return;
    _wifiLockHeld = held;
    _wifiLockChannel.invokeMethod(held ? 'acquire' : 'release').catchError((Object e) {
      debugPrint('[WifiLock] $e');
    });
  }

  /// [mapContext] = poziția/zoom-ul hărții de unde a fost ales postul.
  Future<void> playRadio(RadioStation station, {({double lat, double lon, double zoom})? mapContext}) async {
    final generation = ++_radioGeneration;
    _reconnectTimer?.cancel();
    _reconnectAttempts = 0;
    _radioWanted = true;
    radioStatus = null;
    radioMapContext = mapContext;

    // just_audio_background trimite notificării titlul nou doar când se schimbă
    // indexul piesei — de la un post la altul e mereu 0, așa că notificarea
    // rămânea cu postul vechi (ex. Bitola în loc de Ioannina). Oprirea
    // playerului îl reinițializează și titlul nou ajunge sigur în notificare.
    final previous = currentRadio;
    if (previous != null && previous.uuid != station.uuid) {
      await audioPlayer.stop();
      if (generation != _radioGeneration) return;
    }

    playlistFiles.clear();
    currentPlaylistTitle = null;
    currentPlaylistModel = null;
    currentRadio = station;
    radioNowPlaying = null;
    currentSongTitle = station.name;
    currentArtist = station.country.isNotEmpty ? station.country : 'Radio';
    notifyListeners();

    await _startRadio(station, generation);
  }

  Future<void> _startRadio(RadioStation station, int generation) async {
    await audioPlayer.setLoopMode(LoopMode.off);
    final logo = Uri.tryParse(station.favicon);
    final artUri = (logo != null && logo.scheme.startsWith('http')) ? logo : await _resolveArtUri();
    if (generation != _radioGeneration) return; // între timp s-a ales alt post

    await audioPlayer.setAudioSource(
      AudioSource.uri(
        Uri.parse(station.streamUrl),
        tag: MediaItem(
          id: 'radio:${station.uuid}',
          title: station.name,
          artist: station.fmFrequency ?? 'Radio',
          album: station.country,
          artUri: artUri,
        ),
      ),
    );
    if (generation != _radioGeneration) return;
    unawaited(audioPlayer.play()); // play() se termină abia la pauză/stop — nu-l așteptăm
    notifyListeners();
  }

  /// Stream-ul a căzut (rețea, server) — reîncercăm cu pauze tot mai mari
  /// (2, 4, 8, 16, 30 s...), cât timp utilizatorul vrea radio pornit.
  void _scheduleRadioReconnect() {
    final station = currentRadio;
    if (station == null || !_radioWanted || _reconnectTimer?.isActive == true) return;
    if (_reconnectAttempts >= 10) {
      radioStatus = 'Stream-ul nu mai răspunde — apasă play pentru a reîncerca';
      _radioWanted = false;
      notifyListeners();
      return;
    }
    final delay = Duration(seconds: min(30, 2 << _reconnectAttempts));
    _reconnectAttempts++;
    radioStatus = 'Reconectare...';
    notifyListeners();

    final generation = _radioGeneration;
    _reconnectTimer = Timer(delay, () async {
      if (generation != _radioGeneration || !_radioWanted) return;
      try {
        await _startRadio(station, generation);
      } catch (e) {
        debugPrint('[Radio] reconectare eșuată: $e');
        _scheduleRadioReconnect();
      }
    });
  }

  void _stopRadioSession() {
    _radioGeneration++;
    _radioWanted = false;
    _reconnectTimer?.cancel();
    radioStatus = null;
    radioMapContext = null;
    _setWifiLock(false);
  }

  /// Apelat după ce sync-ul a redenumit un playlist sau i-a mutat melodii
  /// în "Removed Songs": dacă e playlistul încărcat, refacem sursa audio cu
  /// noile căi, păstrând piesa și poziția curente (dacă piesa mai există).
  Future<void> refreshPlaylistFromDisk(String oldTitle, Directory newDir) async {
    if (currentPlaylistTitle != oldTitle || currentPlaylistModel == null) return;

    final newTitle = newDir.path.split(Platform.pathSeparator).last;
    String rebase(File f) => '${newDir.path}${Platform.pathSeparator}${f.path.split(Platform.pathSeparator).last}';

    final currentPath = currentIndex < playlistFiles.length ? rebase(playlistFiles[currentIndex]) : null;
    final kept = playlistFiles.map((f) => File(rebase(f))).where((f) => f.existsSync()).toList();

    currentPlaylistTitle = newTitle;
    currentPlaylistModel = LocalPlaylistModel(
      title: newTitle,
      directory: newDir,
      audioFiles: kept,
      totalYoutubeCount: currentPlaylistModel!.totalYoutubeCount,
    );
    await reconcileAfterLocalEdit(playlistTitle: newTitle, newFiles: kept, keepPlayingPath: currentPath);
  }

  Future<void> loadPlaylist(LocalPlaylistModel playlistModel, int initialIndex) async {
    _stopRadioSession();
    currentRadio = null;
    radioNowPlaying = null;
    playlistFiles = List.from(playlistModel.audioFiles);
    currentIndex = initialIndex;
    currentPlaylistTitle = playlistModel.title;
    currentPlaylistModel = playlistModel;
    if (playlistFiles.isNotEmpty) {
      await playSongAtIndex(currentIndex);
    }
  }

  Future<void> playSongAtIndex(int index) async {
    if (index < 0 || index >= playlistFiles.length) return;
    currentIndex = index;

    final artUri = await _resolveArtUri();

    final audioSources = playlistFiles.map((file) {
      final fileName = file.path.split(Platform.pathSeparator).last;
      final meta = parseArtistAndTitle(fileName);

      return AudioSource.file(
        file.path,
        tag: MediaItem(
          id: file.path,
          title: meta.title,
          artist: meta.artist,
          album: currentPlaylistTitle ?? '',
          artUri: artUri,
        ),
      );
    }).toList();

    final playlistSource = ConcatenatingAudioSource(children: audioSources);

    // Playlistul se reia de la capăt (ca butoanele Next/Prev din aplicație) —
    // așa notificarea arată mereu toate cele 4 butoane, inclusiv "Previous".
    await audioPlayer.setLoopMode(LoopMode.all);
    await audioPlayer.setAudioSource(playlistSource, initialIndex: index);
    unawaited(audioPlayer.play()); // play() se termină abia la pauză/stop — nu-l așteptăm
    notifyListeners();
  }

  Future<void> togglePlayPause({bool? forcePlay, bool? forcePause}) async {
    if (currentRadio != null) {
      final willPlay = forcePlay == true || (forcePause != true && !isPlaying);
      _radioWanted = willPlay;
      if (!willPlay) _reconnectTimer?.cancel();
      // Stream căzut definitiv sau oprit de mult: repornim conexiunea, nu doar play().
      if (willPlay && audioPlayer.processingState != ProcessingState.ready) {
        _reconnectAttempts = 0;
        radioStatus = null;
        await _startRadio(currentRadio!, _radioGeneration);
        return;
      }
    }
    if (forcePlay == true) {
      unawaited(audioPlayer.play());
    } else if (forcePause == true) {
      await audioPlayer.pause();
    } else {
      isPlaying ? await audioPlayer.pause() : unawaited(audioPlayer.play());
    }
    notifyListeners();
  }

  Future<void> playNext() async {
    if (playlistFiles.isEmpty) return;
    await playSongAtIndex((currentIndex + 1) % playlistFiles.length);
  }

  Future<void> playPrevious() async {
    if (playlistFiles.isEmpty) return;
    await playSongAtIndex(currentIndex > 0 ? currentIndex - 1 : playlistFiles.length - 1);
  }

  /// Recompune sursa audio după o editare locală (elimină/reordonare) care
  /// afectează playlistul curent încărcat, păstrând poziția și starea de
  /// redare — spre deosebire de loadPlaylist/playSongAtIndex, care mereu
  /// repornesc de la 0. Dacă playlistul editat nu e cel încărcat acum, nu
  /// face nimic (nu există stare de sincronizat).
  Future<void> reconcileAfterLocalEdit({
    required String playlistTitle,
    required List<File> newFiles,
    String? keepPlayingPath,
  }) async {
    if (currentPlaylistTitle != playlistTitle) return;

    if (newFiles.isEmpty) {
      await stop();
      return;
    }

    final wasPlaying = isPlaying;
    final resumePosition = position;

    playlistFiles = List.from(newFiles);
    final idx = keepPlayingPath == null ? -1 : playlistFiles.indexWhere((f) => f.path == keepPlayingPath);
    currentIndex = (idx >= 0 ? idx : 0).clamp(0, playlistFiles.length - 1);

    final artUri = await _resolveArtUri();

    final audioSources = playlistFiles.map((file) {
      final fileName = file.path.split(Platform.pathSeparator).last;
      final meta = parseArtistAndTitle(fileName);

      return AudioSource.file(
        file.path,
        tag: MediaItem(
          id: file.path,
          title: meta.title,
          artist: meta.artist,
          album: currentPlaylistTitle ?? '',
          artUri: artUri,
        ),
      );
    }).toList();

    await audioPlayer.setAudioSource(
      ConcatenatingAudioSource(children: audioSources),
      initialIndex: currentIndex,
      initialPosition: idx >= 0 ? resumePosition : Duration.zero,
    );

    if (wasPlaying) {
      unawaited(audioPlayer.play()); // play() se termină abia la pauză/stop — nu-l așteptăm
    } else {
      await audioPlayer.pause();
    }

    notifyListeners();
  }

  Future<void> stop() async {
    _stopRadioSession();
    await audioPlayer.stop();
    playlistFiles.clear();
    currentSongTitle = "";
    currentArtist = "";
    currentPlaylistTitle = null;
    currentPlaylistModel = null;
    currentRadio = null;
    radioNowPlaying = null;
    notifyListeners();
  }
}

/// Fișierele playlistului în ordinea din manifest — după descărcare și
/// sync, aceasta e exact ordinea din playlistul YouTube.
Future<List<File>> orderFilesByManifest(Directory dir, List<File> files) async {
  final entries = await PlaylistManifest.getOrderedSongs(dir);
  final byName = {for (final f in files) f.path.split(Platform.pathSeparator).last: f};
  final ordered = <File>[];
  for (final e in entries) {
    final f = byName.remove(e.fileName);
    if (f != null) ordered.add(f);
  }
  ordered.addAll(byName.values);
  return ordered;
}

/// Tema pentru un playlist local: cea aleasă manual (din Bibliotecă), altfel
/// detectată din titlu și numele melodiilor; Grecia implicit.
Future<String> resolvePlaylistTheme(LocalPlaylistModel playlist) async {
  final override = await loadThemeOverride(playlist.directory);
  if (override != null && appThemes.containsKey(override)) {
    return override;
  }
  return detectThemeForPlaylist(
    title: playlist.title,
    songNames: playlist.audioFiles.map((f) => f.path.split(Platform.pathSeparator).last),
  );
}

/// Schimbă tema automat când pornește alt playlist sau alt post de radio.
class AutoThemeBinder extends StatefulWidget {
  final Widget child;
  const AutoThemeBinder({super.key, required this.child});

  @override
  State<AutoThemeBinder> createState() => _AutoThemeBinderState();
}

class _AutoThemeBinderState extends State<AutoThemeBinder> {
  final GlobalAudioState _audio = GlobalAudioState.instance;
  String? _lastSourceKey;

  @override
  void initState() {
    super.initState();
    _audio.addListener(_onAudioChanged);
  }

  @override
  void dispose() {
    _audio.removeListener(_onAudioChanged);
    super.dispose();
  }

  Future<void> _onAudioChanged() async {
    final radio = _audio.currentRadio;
    final playlist = _audio.currentPlaylistModel;
    final key = radio != null ? 'radio:${radio.uuid}' : (playlist != null ? 'pl:${playlist.directory.path}' : null);
    if (key == null) {
      _lastSourceKey = null; // oprit -> la următoarea pornire se re-detectează
      return;
    }
    if (key == _lastSourceKey) return;
    _lastSourceKey = key;

    final themeId = radio != null ? themeForCountryCode(radio.countryCode) : await resolvePlaylistTheme(playlist!);
    if (!mounted || key != _lastSourceKey) return;
    Provider.of<ThemeProvider>(context, listen: false).applyAutoTheme(themeId);
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

// ==========================================
// APPLICATION MAIN ENTRY POINT
// ==========================================
void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await JustAudioBackground.init(
    // Canal creat nativ în MainActivity (importanță normală -> steluța apare în bara de stare).
    androidNotificationChannelId: 'com.example.musicsync_app.player',
    androidNotificationChannelName: 'MusicSync Player',
    androidNotificationOngoing: true,
    androidStopForegroundOnPause: true,
    androidNotificationIcon: 'drawable/ic_notification_star',
  );

  try {
    final session = await AudioSession.instance;
    await session.configure(const AudioSessionConfiguration.music());
  } catch (e) {
    debugPrint('[AudioSession] configure failed: $e');
  }

  await DownloadNotificationManager.init();
  await DiskCache.init();
  JobForegroundService.init();
  await ThemePhotos.instance.init();
  await RadioFavorites.instance.load();
  LibraryEvents.onPlaylistChanged = GlobalAudioState.instance.refreshPlaylistFromDisk;
  LibraryEvents.onPlaylistRemoved = (title) async {
    if (GlobalAudioState.instance.currentPlaylistTitle == title) await GlobalAudioState.instance.stop();
  };

  runApp(
    MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => ThemeProvider()),
        ChangeNotifierProvider(create: (_) => GlobalAudioState.instance),
      ],
      child: const MusicSyncApp(),
    ),
  );
}

class MusicSyncApp extends StatelessWidget {
  const MusicSyncApp({super.key});

  @override
  Widget build(BuildContext context) {
    final themeProvider = Provider.of<ThemeProvider>(context);

    return MaterialApp(
      title: 'MusicSync',
      debugShowCheckedModeBanner: false,
      theme: themeProvider.themeData,
      builder: (context, child) => AutoThemeBinder(child: child ?? const SizedBox.shrink()),
      home: const MainHubScreen(),
    );
  }
}

// ==========================================
// MAIN HUB SCREEN
// ==========================================
class MainHubScreen extends StatefulWidget {
  const MainHubScreen({super.key});

  @override
  State<MainHubScreen> createState() => _MainHubScreenState();
}

class _MainHubScreenState extends State<MainHubScreen> with WidgetsBindingObserver {
  bool _isOffline = false;
  bool _notificationsDenied = false;
  late StreamSubscription<List<ConnectivityResult>> _connectivitySubscription;
  String? _userEmail;
  String? _userName;

  @override
  void initState() {
    super.initState();
    _checkInitialConnectivity();
    WidgetsBinding.instance.addObserver(this);
    _ensureNotificationPermission();
    _loadUserEmail();
    _connectivitySubscription = Connectivity().onConnectivityChanged.listen((results) {
      setState(() {
        _isOffline = results.contains(ConnectivityResult.none);
      });
    });
  }

  /// Android 13+ cere permisiune explicită pentru notificări — fără ea
  /// dispare notificarea playerului (controale pe ecranul de blocare) și
  /// redarea în fundal e mai ușor oprită de sistem. După o reinstalare
  /// permisiunea se pierde, deci o cerem la fiecare pornire dacă lipsește.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Revenit din Setări -> actualizăm bannerul fără să mai întrebăm.
    if (state == AppLifecycleState.resumed && _notificationsDenied && Platform.isAndroid) {
      Permission.notification.status.then((status) {
        if (mounted) setState(() => _notificationsDenied = !status.isGranted);
      });
    }
  }

  Future<void> _ensureNotificationPermission() async {
    if (!Platform.isAndroid) return;
    var status = await Permission.notification.status;
    if (!status.isGranted) status = await Permission.notification.request();
    if (mounted) setState(() => _notificationsDenied = !status.isGranted);
  }

  Future<void> _loadUserEmail() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _userEmail = prefs.getString('user_logged_email');
      _userName = prefs.getString('user_logged_name');
    });
  }

  Future<void> _checkInitialConnectivity() async {
    final results = await Connectivity().checkConnectivity();
    setState(() {
      _isOffline = results.contains(ConnectivityResult.none);
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _connectivitySubscription.cancel();
    super.dispose();
  }

  void _showThemePicker() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) {
        final themeProvider = Provider.of<ThemeProvider>(ctx, listen: false);

        final themes = [
          ('grecia', 'Grecia', '🇬🇷', const Color(0xFF1A5FA8), const Color(0xFFF4EED8)),
          ('armenia', 'Armenia', '🇦🇲', const Color(0xFFC8241A), const Color(0xFF1A100A)),
          ('iran', 'Iran', '🇮🇷', const Color(0xFFD4890A), const Color(0xFF1A0F00)),
          ('turcia', 'Turcia', '🇹🇷', const Color(0xFF1B6CA8), const Color(0xFF1C1208)),
          ('azerbaidjan', 'Azerbaidjan', '🇦🇿', const Color(0xFF00B9E4), const Color(0xFF180A10)),
          ('kurdistan', 'Kurdistan', '☀️', const Color(0xFF00B9E4), const Color(0xFF180A10)),
          ('bosnia', 'Bosnia', '🇧🇦', const Color(0xFF00B9E4), const Color(0xFF180A10)),
          ('central asia', 'Central Asia', '🌍', const Color(0xFF00B9E4), const Color(0xFF180A10)),
        ];

        return DraggableScrollableSheet(
          initialChildSize: 0.75,
          minChildSize: 0.4,
          maxChildSize: 0.95,
          builder: (_, controller) {
            return Container(
              decoration: const BoxDecoration(
                color: Color(0xFF0A0A0A),
                borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
              ),
              child: Column(
                children: [
                  const SizedBox(height: 8),
                  Container(width: 40, height: 4, decoration: BoxDecoration(color: Colors.white24, borderRadius: BorderRadius.circular(2))),
                  const SizedBox(height: 16),
                  const Text('Alege Tema', style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold)),
                  Consumer<ThemeProvider>(
                    builder: (context, provider, _) => SwitchListTile(
                      contentPadding: const EdgeInsets.symmetric(horizontal: 20),
                      value: provider.autoThemeEnabled,
                      onChanged: provider.setAutoThemeEnabled,
                      title: const Text('Temă automată', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
                      subtitle: const Text(
                        'Se schimbă după țara playlistului sau a postului de radio (implicit Grecia)',
                        style: TextStyle(color: Colors.white60, fontSize: 12),
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Expanded(
                    child: AnimatedBuilder(
                      animation: ThemePhotos.instance,
                      builder: (context, _) => ListView.builder(
                      controller: controller,
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      itemCount: themes.length,
                      itemBuilder: (context, i) {
                        final t = themes[i];
                        final id = t.$1; final name = t.$2; final emoji = t.$3;
                        final accent = t.$4; final bg = t.$5;
                        final photos = ThemePhotos.instance.photosFor(appThemes[id]!).take(7).toList();

                        final isSelected = Provider.of<ThemeProvider>(context).currentTheme.id == id;
                        
                        return GestureDetector(
                          onTap: () { 
                            themeProvider.switchTheme(id); 
                            Navigator.pop(ctx); 
                          },
                          child: Container(
                            margin: const EdgeInsets.only(bottom: 12),
                            height: 110,
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(18),
                              border: Border.all(color: isSelected ? accent : Colors.white12, width: isSelected ? 2.5 : 1),
                              boxShadow: isSelected ? [BoxShadow(color: accent.withOpacity(0.5), blurRadius: 16, spreadRadius: 2)] : [],
                            ),
                            child: ClipRRect(
                              borderRadius: BorderRadius.circular(17),
                              child: Stack(
                                fit: StackFit.expand,
                                children: [
                                  Row(
                                    children: photos.isEmpty
                                        ? [Expanded(child: Container(color: bg))]
                                        : photos.map((photo) => Expanded(
                                            child: Image(
                                              image: photo.image,
                                              fit: BoxFit.cover,
                                              errorBuilder: (_, __, ___) => Container(color: bg),
                                            ),
                                          )).toList(),
                                  ),
                                  Container(decoration: BoxDecoration(gradient: LinearGradient(begin: Alignment.centerLeft, end: Alignment.centerRight, colors: [bg.withOpacity(0.92), bg.withOpacity(0.55), Colors.transparent]))),
                                  Padding(
                                    padding: const EdgeInsets.all(16),
                                    child: Row(
                                      children: [
                                        Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisAlignment: MainAxisAlignment.center, children: [
                                          Text(emoji, style: const TextStyle(fontSize: 28)),
                                          const SizedBox(height: 4),
                                          Text(name, style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold, shadows: [Shadow(color: Colors.black, blurRadius: 8)])),
                                        ]),
                                        const Spacer(),
                                        if (isSelected) Container(padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6), decoration: BoxDecoration(color: accent, borderRadius: BorderRadius.circular(20)), child: const Text('Activ', style: TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.bold))),
                                        const SizedBox(width: 8),
                                        IconButton.filled(
                                          style: IconButton.styleFrom(backgroundColor: Colors.black54),
                                          icon: const Icon(Icons.add_a_photo, color: Colors.white, size: 20),
                                          tooltip: 'Poze $name',
                                          onPressed: () => Navigator.push(
                                            ctx,
                                            MaterialPageRoute(builder: (_) => ThemePhotosScreen(theme: appThemes[id]!)),
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        );
                      },
                    ),
                    ),
                  ),
                  const SizedBox(height: 16),
                ],
              ),
            );
          },
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final audioState = Provider.of<GlobalAudioState>(context);
    final themeProvider = Provider.of<ThemeProvider>(context);
    
    final currentCountryTheme = themeProvider.currentTheme;
    final currentMood = audioState.currentMood;

    final moodColors = (currentCountryTheme.playerMoods != null && currentCountryTheme.playerMoods[currentMood] != null)
        ? currentCountryTheme.playerMoods[currentMood]!
        : PlayerColors(
            gradientColors: [theme.colorScheme.primary, theme.colorScheme.secondary],
            textColor: theme.colorScheme.onPrimary,
            accentColor: theme.colorScheme.secondary,
          );

    return Scaffold(
      backgroundColor: currentCountryTheme.scaffoldBackground,
      appBar: AppBar(
        title: const Text("MusicSync Hub", style: TextStyle(fontWeight: FontWeight.bold)),
        actions: [
          if (_userEmail != null && _userEmail!.isNotEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8.0),
              child: Center(
                child: Chip(
                  avatar: const Icon(Icons.person, size: 16),
                  label: Text(
                    _userName ?? _userEmail!, 
                    style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold)
                  ),
                ),
              ),
            ),
          IconButton(
            icon: const Icon(Icons.palette_outlined),
            onPressed: _showThemePicker,
            tooltip: "Schimbă Tema",
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(24.0),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    Center(
                      child: Container(
                        constraints: const BoxConstraints(maxWidth: 600),
                        padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 24),
                        decoration: BoxDecoration(
                          color: _isOffline ? const Color(0xFF4A1010) : const Color(0xFF154314),
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(
                            color: _isOffline ? Colors.redAccent : Colors.greenAccent,
                            width: 1.5,
                          ),
                        ),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(_isOffline ? Icons.wifi_off : Icons.wifi, color: Colors.white, size: 20),
                            const SizedBox(width: 12),
                            Flexible(
                              child: Text(
                                _isOffline
                                    ? "MOD OFFLINE - Player-ul Local este disponibil"
                                    : "CONECTAT - Downloader & Player activated",
                                textAlign: TextAlign.center,
                                style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 13),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    if (_notificationsDenied) ...[
                      const SizedBox(height: 12),
                      Center(
                        child: Container(
                          constraints: const BoxConstraints(maxWidth: 600),
                          child: Material(
                            color: Colors.orange.withValues(alpha: 0.2),
                            borderRadius: BorderRadius.circular(8),
                            child: ListTile(
                              leading: const Icon(Icons.notifications_off, color: Colors.orange),
                              title: const Text('Notificările sunt oprite', style: TextStyle(fontWeight: FontWeight.bold)),
                              subtitle: const Text('Fără ele nu apar controalele playerului și radioul se poate opri în fundal.'),
                              trailing: FilledButton(
                                style: FilledButton.styleFrom(backgroundColor: Colors.orange, foregroundColor: Colors.black),
                                onPressed: () async {
                                  await openAppSettings();
                                },
                                child: const Text('Pornește'),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ],
                    const SizedBox(height: 32),

                    // CARD 1: DOWNLOADER & SYNC
                    _HubCard(
                      icon: Icons.cloud_download,
                      title: "Downloader & Sync",
                      subtitle: "Music downloader",
                      color: moodColors.gradientColors.first,
                      offline: _isOffline,
                      onTap: () async {
                        await Navigator.push(
                          context,
                          MaterialPageRoute(builder: (context) => const MusicSyncHomePage()),
                        );
                        _loadUserEmail();
                      },
                    ),
                    const SizedBox(height: 24),

                    // CARD 2: LIBRARY & MUSIC PLAYER
                    _HubCard(
                      icon: Icons.library_music,
                      title: "Library & Music Player",
                      subtitle: "Listen music",
                      color: moodColors.gradientColors.last,
                      onTap: () => Navigator.push(
                        context,
                        MaterialPageRoute(builder: (context) => const LocalLibraryScreen()),
                      ),
                    ),
                    const SizedBox(height: 24),

                    // CARD 3: RADIO & SHAZAM (harta și lista merg și offline, din cache)
                    _HubCard(
                      icon: Icons.radio,
                      title: "Radio & Shazam",
                      subtitle: _isOffline ? "Hartă și posturi salvate (offline)" : "Posturi din jurul tău • recunoaștere melodii",
                      color: moodColors.accentColor,
                      onTap: () => Navigator.push(
                        context,
                        MaterialPageRoute(
                          settings: const RouteSettings(name: RadioScreen.routeName),
                          builder: (context) => const RadioScreen(),
                        ),
                      ),
                    ),
                    const SizedBox(height: 24),

                    // CARD 4: SYNC BIBLIOTECĂ (redenumiri + melodii scoase de pe YouTube)
                    _HubCard(
                      icon: Icons.sync,
                      title: "Sync Bibliotecă",
                      subtitle: "Nume noi de playlist și melodii scoase de pe YouTube",
                      color: moodColors.gradientColors.first,
                      offline: _isOffline,
                      onTap: () => Navigator.push(
                        context,
                        MaterialPageRoute(builder: (context) => const LibrarySyncScreen()),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const PersistentBottomMiniPlayer(),
          ],
        ),
      ),
    );
  }
}

/// Card de pe ecranul principal. Toate au aceeași mărime, indiferent de
/// lungimea textului.
class _HubCard extends StatelessWidget {
  static const double height = 168;

  final IconData icon;
  final String title;
  final String subtitle;
  final Color color;
  final VoidCallback onTap;

  /// Necesită internet și suntem offline -> card blocat cu mesaj.
  final bool offline;

  const _HubCard({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.color,
    required this.onTap,
    this.offline = false,
  });

  @override
  Widget build(BuildContext context) {
    final accent = offline ? Colors.grey : color;
    return Center(
      child: Container(
        constraints: const BoxConstraints(maxWidth: 800),
        height: height,
        child: Card(
          elevation: 4,
          clipBehavior: Clip.antiAlias,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
            side: BorderSide(color: accent, width: 2),
          ),
          child: Stack(
            fit: StackFit.expand,
            children: [
              InkWell(
                onTap: offline ? null : onTap,
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 16.0, horizontal: 16.0),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(icon, size: 50, color: accent),
                      const SizedBox(height: 10),
                      Text(
                        title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: offline ? Colors.grey : null),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        subtitle,
                        textAlign: TextAlign.center,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: offline ? Colors.grey : Theme.of(context).colorScheme.onSurfaceVariant,
                          fontSize: 13,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              if (offline)
                Container(
                  color: Colors.black.withValues(alpha: 0.8),
                  child: const Center(
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.block, color: Colors.redAccent, size: 28),
                        SizedBox(width: 10),
                        Text(
                          "Indisponibil Offline",
                          style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 16),
                        ),
                      ],
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

// ==========================================
// PERSISTENT MINI PLAYER
// ==========================================
class PersistentBottomMiniPlayer extends StatelessWidget {
  const PersistentBottomMiniPlayer({super.key});

  @override
  Widget build(BuildContext context) {
    final audioState = Provider.of<GlobalAudioState>(context);
    final theme = Theme.of(context);

    return AnimatedBuilder(
      animation: audioState,
      builder: (context, child) {
        final radio = audioState.currentRadio;
        if (radio == null && (audioState.currentPlaylistTitle == null || audioState.currentPlaylistModel == null)) {
          return const SizedBox.shrink();
        }

        final totalCount = audioState.playlistFiles.length;
        final currentPos = audioState.currentIndex + 1;

        final titleText = radio != null ? (audioState.radioNowPlaying ?? radio.name) : audioState.currentSongTitle;
        final subtitleText = radio != null
            ? (audioState.radioStatus ??
                "📻 ${radio.name}${radio.fmFrequency != null ? ' • ${radio.fmFrequency}' : ''}")
            : "🎤 ${audioState.currentArtist} • 📁 ${audioState.currentPlaylistTitle} ($currentPos/$totalCount)";

        return InkWell(
          onTap: () {
            if (radio != null) {
              // Înapoi la lista orașului de unde a fost ales postul, cu el selectat.
              if (ModalRoute.of(context)?.settings.name == RadioScreen.routeName) {
                RadioScreen.focusPlayingRequests.value++;
                return;
              }
              Navigator.push(
                context,
                MaterialPageRoute(
                  settings: const RouteSettings(name: RadioScreen.routeName),
                  builder: (context) => const RadioScreen(focusPlaying: true),
                ),
              );
              return;
            }
            Navigator.push(
              context,
              MaterialPageRoute(
                builder: (context) => PlaylistPlayerScreen(playlist: audioState.currentPlaylistModel!),
              ),
            );
          },
          child: Container(
            decoration: BoxDecoration(
              color: theme.cardColor,
              boxShadow: const [BoxShadow(color: Colors.black54, blurRadius: 10, offset: Offset(0, -3))],
              border: Border(top: BorderSide(color: theme.colorScheme.primary, width: 2)),
            ),
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Row(
              children: [
                Icon(radio != null ? Icons.radio : Icons.music_note, color: theme.colorScheme.primary),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        titleText,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
                      ),
                      Text(
                        subtitleText,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(color: theme.colorScheme.secondary, fontSize: 11, fontWeight: FontWeight.bold),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  icon: Icon(audioState.isPlaying ? Icons.pause : Icons.play_arrow),
                  onPressed: () => audioState.togglePlayPause(),
                ),
                if (radio == null)
                  IconButton(
                    icon: const Icon(Icons.skip_next),
                    onPressed: () => audioState.playNext(),
                  )
                else
                  FavoriteButton(station: radio),
                IconButton(
                  icon: const Icon(Icons.close, size: 18),
                  onPressed: () => audioState.stop(),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

// ==========================================
// LOCAL LIBRARY SCREEN
// ==========================================
class LocalLibraryScreen extends StatefulWidget {
  const LocalLibraryScreen({super.key});

  @override
  State<LocalLibraryScreen> createState() => _LocalLibraryScreenState();
}

class _LocalLibraryScreenState extends State<LocalLibraryScreen> {
  final DownloadSyncService _downloadService = DownloadSyncService();
  String? _rootFolderPath;
  List<LocalPlaylistModel> _localPlaylists = [];
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _scanLocalLibrary();
  }

  Future<void> _scanLocalLibrary() async {
    setState(() => _isLoading = true);

    final prefs = await SharedPreferences.getInstance();
    _rootFolderPath = prefs.getString('saved_output_dir');

    List<LocalPlaylistModel> foundPlaylists = [];

    if (_rootFolderPath != null && Directory(_rootFolderPath!).existsSync()) {
      final rootDir = Directory(_rootFolderPath!);
      final entities = rootDir.listSync();

      for (var entity in entities) {
        if (entity is Directory) {
          final folderName = entity.path.split(Platform.pathSeparator).last;
          if (folderName.toLowerCase() == kRemovedSongsFolderName.toLowerCase()) continue;

          final files = entity.listSync().whereType<File>().where((f) {
            final ext = f.path.toLowerCase();
            return ext.endsWith('.mp3') || ext.endsWith('.m4a') || ext.endsWith('.wav');
          }).toList();

          // Ordinea din manifest = ordinea din playlistul YouTube.
          final orderedFiles = await orderFilesByManifest(entity, files);

          final totalYt = prefs.getInt('playlist_total_$folderName');

          if (files.isNotEmpty) {
            foundPlaylists.add(LocalPlaylistModel(
              title: folderName,
              directory: entity,
              audioFiles: orderedFiles,
              totalYoutubeCount: totalYt,
            ));
          }
        }
      }
    }

    setState(() {
      _localPlaylists = foundPlaylists;
      _isLoading = false;
    });
  }

  Future<void> _selectFolder() async {
    final folder = await _downloadService.selectOutputDirectory();
    if (folder != null) {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('saved_output_dir', folder);
      await _scanLocalLibrary();
    }
  }

  Future<void> _confirmDeletePlaylist(LocalPlaylistModel playlist) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Șterge playlistul?'),
        content: Text(
          '"${playlist.title}" și cele ${playlist.audioFiles.length} melodii ale lui vor fi șterse '
          'definitiv de pe dispozitiv. Playlistul de pe YouTube nu este afectat — îl poți descărca din nou oricând.\n\n'
          'Temele (țările) și pozele lor rămân neschimbate, iar țara aleasă pentru acest playlist '
          'revine automat dacă îl descarci din nou.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialogContext, false), child: const Text('Anulează')),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.redAccent, foregroundColor: Colors.white),
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Șterge'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    final audioState = GlobalAudioState.instance;
    if (audioState.currentPlaylistTitle == playlist.title) {
      await audioState.stop();
    }

    try {
      await deleteLocalPlaylist(playlist.directory);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Nu am putut șterge playlistul: $e')));
      }
    }
    await _scanLocalLibrary();
  }

  Future<void> _choosePlaylistTheme(LocalPlaylistModel playlist) async {
    final override = await loadThemeOverride(playlist.directory);
    final detected = detectThemeForPlaylist(
      title: playlist.title,
      songNames: playlist.audioFiles.map((f) => f.path.split(Platform.pathSeparator).last),
    );
    if (!mounted) return;

    // '' = automat
    final choice = await showDialog<String>(
      context: context,
      builder: (dialogContext) => SimpleDialog(
        title: Text('Țara pentru "${playlist.title}"'),
        children: [
          RadioGroup<String>(
            groupValue: override ?? '',
            onChanged: (v) => Navigator.pop(dialogContext, v),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                RadioListTile<String>(
                  value: '',
                  title: const Text('Automat'),
                  subtitle: Text('Detectat: ${appThemes[detected]?.name ?? detected}'),
                ),
                for (final t in appThemes.values) RadioListTile<String>(value: t.id, title: Text(t.name)),
              ],
            ),
          ),
        ],
      ),
    );
    if (choice == null) return;

    await saveThemeOverride(playlist.directory, choice.isEmpty ? null : choice);

    // Dacă rulează chiar acum, aplicăm imediat noua temă.
    if (GlobalAudioState.instance.currentPlaylistTitle == playlist.title && mounted) {
      final themeId = choice.isEmpty ? detected : choice;
      Provider.of<ThemeProvider>(context, listen: false).applyAutoTheme(themeId);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final audioState = Provider.of<GlobalAudioState>(context);
    final themeProvider = Provider.of<ThemeProvider>(context);
    final currentCountryTheme = themeProvider.currentTheme;

    final moodColors = (currentCountryTheme.playerMoods != null && currentCountryTheme.playerMoods[audioState.currentMood] != null)
        ? currentCountryTheme.playerMoods[audioState.currentMood]!
        : PlayerColors(
            gradientColors: [theme.colorScheme.primary, theme.colorScheme.secondary],
            textColor: theme.colorScheme.onPrimary,
            accentColor: theme.colorScheme.secondary,
          );

    return Scaffold(
      appBar: AppBar(
        title: const Text("Bibliotecă Locală"),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _scanLocalLibrary,
            tooltip: "Rescanează",
          ),
          IconButton(
            icon: const Icon(Icons.folder_open),
            onPressed: _selectFolder,
            tooltip: "Schimbă Folderul",
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: _isLoading
                ? const Center(child: CircularProgressIndicator())
                : _rootFolderPath == null
                    ? Center(
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            const Icon(Icons.folder_off, size: 64, color: Colors.grey),
                            const SizedBox(height: 16),
                            const Text("Nu ai selectat încă un folder de salvare.", style: TextStyle(fontSize: 16)),
                            const SizedBox(height: 12),
                            ElevatedButton.icon(
                              icon: const Icon(Icons.folder),
                              label: const Text("Alege Folderul Muzical"),
                              onPressed: _selectFolder,
                            )
                          ],
                        ),
                      )
                    : _localPlaylists.isEmpty
                        ? Center(
                            child: Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                const Icon(Icons.music_off, size: 64, color: Colors.grey),
                                const SizedBox(height: 16),
                                Text(
                                  "Nu s-au găsit playlist-uri descărcate în:\n$_rootFolderPath",
                                  textAlign: TextAlign.center,
                                  style: const TextStyle(color: Colors.grey),
                                ),
                              ],
                            ),
                          )
                        : ListView.builder(
                            itemCount: _localPlaylists.length,
                            itemBuilder: (context, index) {
                              final playlist = _localPlaylists[index];

                              final subtitleText = playlist.totalYoutubeCount != null
                                  ? (playlist.audioFiles.length > playlist.totalYoutubeCount!
                                      ? "${playlist.audioFiles.length} piese • ${playlist.totalYoutubeCount} disponibile pe YouTube"
                                      : "${playlist.audioFiles.length} / ${playlist.totalYoutubeCount} piese descărcate")
                                  : "${playlist.audioFiles.length} piese descărcate local";

                              return Card(
                                margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                                child: ListTile(
                                  contentPadding: const EdgeInsets.all(12),
                                  leading: Container(
                                    width: 50,
                                    height: 50,
                                    decoration: BoxDecoration(
                                      gradient: LinearGradient(
                                        colors: moodColors.gradientColors, 
                                        begin: Alignment.topLeft, 
                                        end: Alignment.bottomRight
                                      ),
                                      borderRadius: BorderRadius.circular(8),
                                    ),
                                    child: Icon(Icons.album, color: theme.colorScheme.primary, size: 30),
                                  ),
                                  title: Text(
                                    playlist.title,
                                    style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                                  ),
                                  subtitle: Padding(
                                    padding: const EdgeInsets.only(top: 6.0),
                                    child: Text(
                                      subtitleText,
                                      style: TextStyle(color: theme.colorScheme.secondary, fontWeight: FontWeight.bold),
                                    ),
                                  ),
                                  trailing: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      PopupMenuButton<String>(
                                        tooltip: 'Opțiuni playlist',
                                        onSelected: (action) {
                                          if (action == 'theme') _choosePlaylistTheme(playlist);
                                          if (action == 'delete') _confirmDeletePlaylist(playlist);
                                        },
                                        itemBuilder: (_) => const [
                                          PopupMenuItem(
                                            value: 'theme',
                                            child: ListTile(leading: Icon(Icons.flag_outlined), title: Text('Țară / temă')),
                                          ),
                                          PopupMenuItem(
                                            value: 'delete',
                                            child: ListTile(
                                              leading: Icon(Icons.delete_forever, color: Colors.redAccent),
                                              title: Text('Șterge playlistul'),
                                            ),
                                          ),
                                        ],
                                      ),
                                      const Icon(Icons.play_circle_fill, size: 36),
                                    ],
                                  ),
                                  onTap: () {
                                    Navigator.push(
                                      context,
                                      MaterialPageRoute(
                                        builder: (context) => PlaylistPlayerScreen(playlist: playlist),
                                      ),
                                    );
                                  },
                                ),
                              );
                            },
                          ),
          ),
          const PersistentBottomMiniPlayer(),
        ],
      ),
    );
  }
}

class PlaylistPlayerScreen extends StatefulWidget {
  final LocalPlaylistModel playlist;

  const PlaylistPlayerScreen({super.key, required this.playlist});

  @override
  State<PlaylistPlayerScreen> createState() => _PlaylistPlayerScreenState();
}

class _PlaylistPlayerScreenState extends State<PlaylistPlayerScreen> {
  final audioState = GlobalAudioState.instance;
  // Implicit: ordinea din playlistul YouTube (manifest).
  SongSortOrder _sortOrder = SongSortOrder.custom;

  List<File> _allFiles = [];
  List<File> _displayedFiles = [];
  late List<File> _customOrderFiles = List.from(widget.playlist.audioFiles);
  final TextEditingController _searchController = TextEditingController();
  String _searchQuery = "";

  // Imaginea de fundal aleasă random din tema curentă
  ThemePhoto? _randomBackgroundImage;
  String? _backgroundThemeId;

  @override
  void initState() {
    super.initState();
    _allFiles = List.from(widget.playlist.audioFiles);
    _applySortingAndFiltering(shouldLoadPlaylist: true);
    _loadCustomOrder();
  }

  Future<void> _loadCustomOrder() async {
    final entries = await PlaylistManifest.getOrderedSongs(widget.playlist.directory);

    final byName = {
      for (final f in _allFiles) f.path.split(Platform.pathSeparator).last: f,
    };

    final ordered = <File>[];
    for (final entry in entries) {
      final file = byName[entry.fileName];
      if (file != null) ordered.add(file);
    }

    // Orice fișier de pe disc absent din manifest (rar — doar dacă
    // reconcilierea încă nu a rulat) e adăugat la final, ca să nu dispară
    // pur și simplu din listă.
    final orderedNames = ordered.map((f) => f.path.split(Platform.pathSeparator).last).toSet();
    for (final f in _allFiles) {
      final name = f.path.split(Platform.pathSeparator).last;
      if (!orderedNames.contains(name)) ordered.add(f);
    }

    if (!mounted) return;
    setState(() {
      _customOrderFiles = ordered;
    });
    if (_sortOrder == SongSortOrder.custom) {
      _applySortingAndFiltering();
    }
  }

  /// Alege o poză random din tema curentă; se re-alege când tema se schimbă
  /// (ex. comutare automată pe Turcia la pornirea unui playlist turcesc).
  void _ensureBackgroundFor(CountryTheme theme) {
    if (_backgroundThemeId == theme.id) return;
    _backgroundThemeId = theme.id;
    final photos = ThemePhotos.instance.photosFor(theme);
    _randomBackgroundImage = photos.isEmpty ? null : photos[Random().nextInt(photos.length)];
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  void _applySortingAndFiltering({bool shouldLoadPlaylist = false}) {
    final baseList = _sortOrder == SongSortOrder.custom ? _customOrderFiles : _allFiles;

    List<File> filtered = baseList.where((file) {
      final fileName = file.path.split(Platform.pathSeparator).last.toLowerCase();
      return fileName.contains(_searchQuery.toLowerCase());
    }).toList();

    if (_sortOrder != SongSortOrder.custom) {
      filtered.sort((a, b) {
        final modA = a.lastModifiedSync();
        final modB = b.lastModifiedSync();
        return _sortOrder == SongSortOrder.oldestFirst ? modA.compareTo(modB) : modB.compareTo(modA);
      });
    }

    setState(() {
      _displayedFiles = filtered;
    });

    if (shouldLoadPlaylist && audioState.currentPlaylistTitle != widget.playlist.title) {
      final updatedModel = LocalPlaylistModel(
        title: widget.playlist.title,
        directory: widget.playlist.directory,
        audioFiles: _displayedFiles,
        totalYoutubeCount: widget.playlist.totalYoutubeCount,
      );
      audioState.loadPlaylist(updatedModel, 0);
    }
  }

  IconData _sortIcon() {
    switch (_sortOrder) {
      case SongSortOrder.oldestFirst:
        return Icons.sort_by_alpha;
      case SongSortOrder.newestFirst:
        return Icons.swap_vert;
      case SongSortOrder.custom:
        return Icons.smart_display;
    }
  }

  String _sortTooltip() {
    switch (_sortOrder) {
      case SongSortOrder.oldestFirst:
        return "Sortează: Cele mai noi descărcate primele";
      case SongSortOrder.newestFirst:
        return "Sortează: Ordinea din playlistul YouTube";
      case SongSortOrder.custom:
        return "Sortează: Cele mai vechi descărcate primele";
    }
  }

  Future<void> _confirmRemoveSong(File file) async {
    final fileName = file.path.split(Platform.pathSeparator).last;
    final meta = parseArtistAndTitle(fileName);

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Elimină melodia?'),
        content: Text(
          '"${meta.title}" va fi mutată în folderul "Removed Songs" '
          '(nu este ștearsă definitiv).',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Anulează'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Elimină'),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

    final isLoadedHere = audioState.currentPlaylistTitle == widget.playlist.title;
    final currentlyPlayingPath = isLoadedHere &&
            audioState.playlistFiles.isNotEmpty &&
            audioState.currentIndex < audioState.playlistFiles.length
        ? audioState.playlistFiles[audioState.currentIndex].path
        : null;
    final wasCurrentlyPlaying = currentlyPlayingPath == file.path;

    try {
      await PlaylistManifest.moveToRemovedSongs(
        rootDir: widget.playlist.directory.parent,
        source: file,
        sourcePlaylistFolderName: widget.playlist.title,
      );
      await PlaylistManifest.removeByFileName(widget.playlist.directory, fileName);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Nu am putut elimina melodia: $e')),
        );
      }
      return;
    }

    setState(() {
      _allFiles.removeWhere((f) => f.path == file.path);
      _customOrderFiles.removeWhere((f) => f.path == file.path);
    });
    _applySortingAndFiltering();

    await audioState.reconcileAfterLocalEdit(
      playlistTitle: widget.playlist.title,
      newFiles: _displayedFiles,
      keepPlayingPath: wasCurrentlyPlaying ? null : currentlyPlayingPath,
    );
  }

  Future<void> _handleReorder(int oldIndex, int newIndex) async {
    if (oldIndex == newIndex) return;

    final isLoadedHere = audioState.currentPlaylistTitle == widget.playlist.title;
    final currentlyPlayingPath = isLoadedHere &&
            audioState.playlistFiles.isNotEmpty &&
            audioState.currentIndex < audioState.playlistFiles.length
        ? audioState.playlistFiles[audioState.currentIndex].path
        : null;

    setState(() {
      final file = _displayedFiles.removeAt(oldIndex);
      _displayedFiles.insert(newIndex, file);
      _customOrderFiles = List.from(_displayedFiles);
    });

    await PlaylistManifest.reorder(widget.playlist.directory, oldIndex, newIndex);

    await audioState.reconcileAfterLocalEdit(
      playlistTitle: widget.playlist.title,
      newFiles: _displayedFiles,
      keepPlayingPath: currentlyPlayingPath,
    );
  }

  void _toggleSortOrder() {
    setState(() {
      switch (_sortOrder) {
        case SongSortOrder.oldestFirst:
          _sortOrder = SongSortOrder.newestFirst;
          break;
        case SongSortOrder.newestFirst:
          _sortOrder = SongSortOrder.custom;
          break;
        case SongSortOrder.custom:
          _sortOrder = SongSortOrder.oldestFirst;
          break;
      }
    });
    _applySortingAndFiltering();
  }

  String _formatDuration(Duration d) {
    final minutes = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final seconds = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return "$minutes:$seconds";
  }

  Widget _buildSongTile({
    required int idx,
    required File file,
    required PlayerColors moodColors,
    required Key key,
    required Widget trailing,
  }) {
    final fileName = file.path.split(Platform.pathSeparator).last;
    final meta = parseArtistAndTitle(fileName);

    final isSelected = audioState.playlistFiles.isNotEmpty &&
        audioState.currentIndex < audioState.playlistFiles.length &&
        audioState.playlistFiles[audioState.currentIndex].path == file.path &&
        audioState.currentPlaylistTitle == widget.playlist.title;

    return ListTile(
      key: key,
      // Folosim tileColor dinamic integrat cu poza de fundal
      tileColor: isSelected
          ? moodColors.accentColor.withOpacity(0.18)
          : Colors.white.withOpacity(0.02),
      dense: true,
      leading: isSelected
          ? Icon(Icons.graphic_eq, color: moodColors.accentColor)
          : Text("${idx + 1}", style: const TextStyle(color: Colors.white60, fontSize: 11)),
      title: Text(
        meta.title,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
          color: isSelected ? moodColors.accentColor : Colors.white,
        ),
      ),
      subtitle: Text(
        meta.artist,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(fontSize: 11, color: isSelected ? moodColors.accentColor.withOpacity(0.8) : Colors.white54),
      ),
      trailing: trailing,
      onTap: () {
        final updatedModel = LocalPlaylistModel(
          title: widget.playlist.title,
          directory: widget.playlist.directory,
          audioFiles: _displayedFiles,
          totalYoutubeCount: widget.playlist.totalYoutubeCount,
        );
        audioState.loadPlaylist(updatedModel, idx);
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final themeProvider = Provider.of<ThemeProvider>(context);
    final countryTheme = themeProvider.currentTheme;
    _ensureBackgroundFor(countryTheme);

    return Scaffold(
      backgroundColor: countryTheme.scaffoldBackground,
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(widget.playlist.title, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Colors.white, shadows: [Shadow(color: Colors.black, blurRadius: 4)])),
            Text(
              widget.playlist.totalYoutubeCount != null
                  ? (_allFiles.length > widget.playlist.totalYoutubeCount!
                      ? "${_allFiles.length} piese • ${widget.playlist.totalYoutubeCount} disponibile pe YouTube"
                      : "${_allFiles.length} din ${widget.playlist.totalYoutubeCount} piese salvate")
                  : "${_allFiles.length} piese locale",
              style: const TextStyle(fontSize: 11, color: Colors.white70, shadows: [Shadow(color: Colors.black, blurRadius: 4)]),
            ),
          ],
        ),
        actions: [
          IconButton(
            icon: Icon(_sortIcon(), color: Colors.white),
            tooltip: _sortTooltip(),
            onPressed: _toggleSortOrder,
          ),
        ],
      ),
      body: AnimatedBuilder(
        animation: audioState,
        builder: (context, child) {
          final mood = audioState.currentMood;
          final moodColors = countryTheme.playerMoods[mood] ??
              PlayerColors(
                gradientColors: [theme.colorScheme.primary, theme.colorScheme.secondary],
                textColor: Colors.white,
                accentColor: theme.colorScheme.primary,
              );

          return Stack(
            children: [
              // 1. IMAGINEA RANDOM PE TOT ECRANUL
              Positioned.fill(
                child: _randomBackgroundImage != null
                    ? Image(
                        image: _randomBackgroundImage!.image,
                        fit: BoxFit.cover,
                        errorBuilder: (_, __, ___) => Container(color: countryTheme.scaffoldBackground),
                      )
                    : Container(color: countryTheme.scaffoldBackground),
              ),

              // 2. FILTRU DE BLUR ȘI DE ÎNTUNECARE (Pentru integrarea culorilor și lizibilitate)
              Positioned.fill(
                child: Container(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [
                        Colors.black.withOpacity(0.4),
                        moodColors.gradientColors.first.withOpacity(0.5), // Pune subtil tenta temei alese
                        Colors.black.withOpacity(0.85),
                      ],
                    ),
                  ),
                ),
              ),

              // 3. INTERFAȚA ȘI CONTROALELE COMPACTATE + LISTA MAI MARE
              SafeArea(
                child: Column(
                  children: [
                    // Căutare minimalistă semi-transparentă
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 8.0),
                      child: TextField(
                        controller: _searchController,
                        onChanged: (value) {
                          _searchQuery = value;
                          _applySortingAndFiltering();
                        },
                        style: const TextStyle(color: Colors.white, fontSize: 14),
                        decoration: InputDecoration(
                          hintText: "Caută o melodie...",
                          hintStyle: const TextStyle(color: Colors.white60),
                          prefixIcon: const Icon(Icons.search, color: Colors.white70, size: 20),
                          suffixIcon: _searchQuery.isNotEmpty 
                              ? IconButton(
                                  icon: const Icon(Icons.clear, color: Colors.white70, size: 18),
                                  onPressed: () {
                                    _searchController.clear();
                                    _searchQuery = "";
                                    _applySortingAndFiltering();
                                  },
                                )
                              : null,
                          filled: true,
                          fillColor: Colors.black.withOpacity(0.4),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(12),
                            borderSide: BorderSide.none,
                          ),
                          contentPadding: const EdgeInsets.symmetric(vertical: 6),
                        ),
                      ),
                    ),

                    // CONTROALE MINIMALISTE (Ocupă spațiu vertical mult mai mic pe ecran)
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 20.0, vertical: 12.0),
                      child: Card(
                        color: Colors.black.withOpacity(0.5),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                        child: Padding(
                          padding: const EdgeInsets.all(12.0),
                          child: Column(
                            children: [
                              // Info piesa curentă în stânga, butoane în dreapta
                              Row(
                                children: [
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          audioState.currentSongTitle.isNotEmpty ? audioState.currentSongTitle : 'Selectează o melodie',
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: TextStyle(
                                            color: moodColors.textColor,
                                            fontSize: 16,
                                            fontWeight: FontWeight.bold,
                                          ),
                                        ),
                                        const SizedBox(height: 2),
                                        Text(
                                          audioState.currentArtist.isNotEmpty ? audioState.currentArtist : 'Artist Necunoscut',
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: TextStyle(
                                            color: moodColors.textColor.withOpacity(0.7),
                                            fontSize: 13,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                  // Controale media compacte
                                  IconButton(
                                    icon: const Icon(Icons.skip_previous, color: Colors.white, size: 24),
                                    onPressed: () => audioState.playPrevious(),
                                  ),
                                  IconButton(
                                    icon: Icon(audioState.isPlaying ? Icons.pause_circle_filled : Icons.play_circle_filled),
                                    color: moodColors.accentColor,
                                    iconSize: 38,
                                    onPressed: () => audioState.togglePlayPause(),
                                  ),
                                  IconButton(
                                    icon: const Icon(Icons.skip_next, color: Colors.white, size: 24),
                                    onPressed: () => audioState.playNext(),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 4),
                              // Slider-ul compact dedesubt
                              Row(
                                children: [
                                  Text(_formatDuration(audioState.position), style: const TextStyle(fontSize: 10, color: Colors.white60)),
                                  Expanded(
                                    child: SliderTheme(
                                      data: SliderTheme.of(context).copyWith(
                                        trackHeight: 3,
                                        thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
                                        overlayShape: const RoundSliderOverlayShape(overlayRadius: 12),
                                      ),
                                      child: Slider(
                                        value: audioState.position.inSeconds.toDouble().clamp(0.0, audioState.duration.inSeconds.toDouble()),
                                        max: audioState.duration.inSeconds > 0 ? audioState.duration.inSeconds.toDouble() : 1.0,
                                        activeColor: moodColors.accentColor,
                                        inactiveColor: Colors.white24,
                                        onChanged: (val) {
                                          audioState.audioPlayer.seek(Duration(seconds: val.toInt()));
                                        },
                                      ),
                                    ),
                                  ),
                                  Text(_formatDuration(audioState.duration), style: const TextStyle(fontSize: 10, color: Colors.white60)),
                                ],
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),

                    // LISTA EXTINSĂ DE PIESE (Ocupă majoritatea ecranului acum)
                    Expanded(
                      child: Container(
                        decoration: BoxDecoration(
                          color: Colors.black.withOpacity(0.35),
                          borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
                        ),
                        child: _displayedFiles.isEmpty
                            ? const Center(child: Text("Nu s-a găsit nicio melodie.", style: TextStyle(color: Colors.white70)))
                            : (_sortOrder == SongSortOrder.custom && _searchQuery.isEmpty)
                                ? ReorderableListView.builder(
                                    padding: const EdgeInsets.only(top: 12, bottom: 16),
                                    buildDefaultDragHandles: false,
                                    itemCount: _displayedFiles.length,
                                    onReorderItem: _handleReorder,
                                    itemBuilder: (context, idx) {
                                      final file = _displayedFiles[idx];
                                      return _buildSongTile(
                                        idx: idx,
                                        file: file,
                                        moodColors: moodColors,
                                        key: ValueKey(file.path),
                                        trailing: Row(
                                          mainAxisSize: MainAxisSize.min,
                                          children: [
                                            IconButton(
                                              icon: const Icon(Icons.remove_circle_outline, color: Colors.white54, size: 20),
                                              tooltip: 'Elimină din playlist',
                                              onPressed: () => _confirmRemoveSong(file),
                                            ),
                                            ReorderableDragStartListener(
                                              index: idx,
                                              child: const Padding(
                                                padding: EdgeInsets.only(left: 4),
                                                child: Icon(Icons.drag_handle, color: Colors.white38, size: 20),
                                              ),
                                            ),
                                          ],
                                        ),
                                      );
                                    },
                                  )
                                : ListView.builder(
                                    padding: const EdgeInsets.only(top: 12, bottom: 16),
                                    itemCount: _displayedFiles.length,
                                    itemBuilder: (context, idx) {
                                      final file = _displayedFiles[idx];
                                      return _buildSongTile(
                                        idx: idx,
                                        file: file,
                                        moodColors: moodColors,
                                        key: ValueKey(file.path),
                                        trailing: IconButton(
                                          icon: const Icon(Icons.remove_circle_outline, color: Colors.white54, size: 20),
                                          tooltip: 'Elimină din playlist',
                                          onPressed: () => _confirmRemoveSong(file),
                                        ),
                                      );
                                    },
                                  ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}



// ==========================================
// DOWNLOADER & SYNC CONTENT SCREEN
// ==========================================
class MusicSyncHomePage extends StatefulWidget {
  const MusicSyncHomePage({super.key});

  @override
  State<MusicSyncHomePage> createState() => _MusicSyncHomePageState();
}

class _MusicSyncHomePageState extends State<MusicSyncHomePage> {
  final GoogleSignIn _googleSignIn = GoogleAuthManager.instance;
  // Descărcarea rulează în DownloadJob (global) — continuă și dacă ieși din
  // ecran sau din aplicație; ecranul doar o afișează.
  final DownloadJob _job = DownloadJob.instance;
  DownloadSyncService get _downloadService => _job.service;

  GoogleSignInCredentials? _credentials;
  List<youtube.Playlist> _playlists = [];
  Set<String> _customPlaylistIds = {};
  bool _isLoading = false;
  String? _userDisplayName;

  String? get _syncingPlaylistId => _job.playlistId;
  String get _currentSongTitle => _job.currentSongTitle;
  String get _syncStatusText => _job.statusText;
  double get _overallProgress => _job.overallProgress;
  double get _songProgress => _job.songProgress;
  bool get _isCancelling => _job.isCancelling;
  List<String> get _logs => _job.logs;

  final ScrollController _logScrollController = ScrollController();
  String? _selectedDirectoryPath;

  @override
  void initState() {
    super.initState();
    _job.addListener(_onJobChanged);
    _loadSavedFolder();
    _autoRestoreLogin();
  }

  /// Folderul ales o dată (aici sau în Bibliotecă) rămâne folosit la descărcări.
  Future<void> _loadSavedFolder() async {
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getString('saved_output_dir');
    if (!mounted || saved == null || !Directory(saved).existsSync()) return;
    setState(() => _selectedDirectoryPath = saved);
  }

  void _onJobChanged() {
    if (!mounted) return;
    setState(() {});
    Future.delayed(const Duration(milliseconds: 100), () {
      if (_logScrollController.hasClients) {
        _logScrollController.jumpTo(_logScrollController.position.maxScrollExtent);
      }
    });
  }

  Future<void> _autoRestoreLogin() async {
    final prefs = await SharedPreferences.getInstance();
    final savedEmail = prefs.getString('user_logged_email');
    if (savedEmail != null) {
      await _handleSignIn(isAutoLogin: true);
    }
  }

  @override
  void dispose() {
    // NU oprim descărcarea — continuă în fundal.
    _job.removeListener(_onJobChanged);
    _logScrollController.dispose();
    super.dispose();
  }

  void _addLog(String message) => _job.addLog(message);

  void _showErrorDialog(String title, dynamic error) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: SingleChildScrollView(child: Text(error.toString())),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('OK')),
        ],
      ),
    );
  }

  Future<void> _fetchAndSaveUserEmail(String accessToken) async {
    try {
      final res = await http.get(
        Uri.parse('https://www.googleapis.com/oauth2/v2/userinfo'),
        headers: {'Authorization': 'Bearer $accessToken'},
      );
      if (res.statusCode == 200) {
        final data = json.decode(res.body);
        final email = data['email'] as String?;
        final name = data['name'] as String?;
        
        final prefs = await SharedPreferences.getInstance();
        if (email != null && email.isNotEmpty) await prefs.setString('user_logged_email', email);
        if (name != null && name.isNotEmpty) await prefs.setString('user_logged_name', name);

        setState(() {
          if (name != null && name.isNotEmpty) {
            _userDisplayName = name;
          } else if (email != null && email.isNotEmpty) {
            _userDisplayName = email.split('@').first;
          }
        });
      }
    } catch (_) {}
  }

  Future<void> _handleSignIn({bool isAutoLogin = false}) async {
    try {
      final creds = await _googleSignIn.signIn();
      if (creds != null) {
        setState(() => _credentials = creds);
        if (creds.accessToken != null) await _fetchAndSaveUserEmail(creds.accessToken!);
        await _fetchPlaylists();
      } else if (!isAutoLogin) {
        _showErrorDialog('Autentificare', 'Conectarea a fost anulată.');
      }
    } catch (e) {
      if (!isAutoLogin) _showErrorDialog('Eroare Google Sign-In', e);
    }
  }

  Future<void> _handleSignOut() async {
    try {
      await _googleSignIn.signOut();
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove('user_logged_email');

      setState(() {
        _credentials = null;
        _playlists = [];
        _job.clearLogs();
      });
    } catch (e) {
      _showErrorDialog('Eroare la Deconectare', e);
    }
  }

  Future<youtube.YouTubeApi?> _getYouTubeApi() async {
    final creds = _credentials;
    if (creds == null) return null;
    return GoogleAuthManager.youtubeApiFor(creds);
  }

  Future<void> _fetchPlaylists() async {
    final youtubeApi = await _getYouTubeApi();
    if (youtubeApi == null) return;

    setState(() => _isLoading = true);

    try {
      final response = await youtubeApi.playlists.list(['snippet', 'contentDetails'], mine: true, maxResults: 50);
      List<youtube.Playlist> fetched = response.items ?? [];

      final prefs = await SharedPreferences.getInstance();
      final savedIds = prefs.getStringList('custom_playlists') ?? [];
      _customPlaylistIds = savedIds.toSet();

      // Playlisturile deja descărcate (ID-ul e ținut în folderul lor) apar
      // mereu în listă — chiar dacă lista salvată s-a pierdut (ex. reinstalare).
      final root = prefs.getString('saved_output_dir');
      if (root != null) {
        for (final dir in listPlaylistFolders(Directory(root))) {
          final id = (await PlaylistMetaStore.read(dir)).playlistId;
          if (id != null && !fetched.any((p) => p.id == id) && _customPlaylistIds.add(id)) {
            await prefs.setStringList('custom_playlists', _customPlaylistIds.toList());
          }
        }
      }

      for (String customId in _customPlaylistIds) {
        if (!fetched.any((p) => p.id == customId)) {
          final loadedCustom = await _fetchSinglePlaylist(youtubeApi, customId);
          if (loadedCustom != null) fetched.insert(0, loadedCustom);
        }
      }

      setState(() => _playlists = fetched);
      _addLog('S-au încărcat ${_playlists.length} playlist-uri.');
    } catch (e) {
      _showErrorDialog('Eroare YouTube Playlists', e);
    } finally {
      setState(() => _isLoading = false);
    }
  }

  Future<youtube.Playlist?> _fetchSinglePlaylist(youtube.YouTubeApi api, String cleanId) async {
    try {
      String title = 'Playlist Colaborativ';
      int itemCount = 0;

      final playlistDetails = await api.playlists.list(['snippet', 'contentDetails'], id: [cleanId]);
      if (playlistDetails.items != null && playlistDetails.items!.isNotEmpty) {
        final item = playlistDetails.items!.first;
        title = item.snippet?.title ?? title;
        itemCount = item.contentDetails?.itemCount ?? 0;
      } else {
        final items = await api.playlistItems.list(['snippet'], playlistId: cleanId, maxResults: 50);
        itemCount = items.items?.length ?? 0;
      }

      return youtube.Playlist()
        ..id = cleanId
        ..snippet = (youtube.PlaylistSnippet()..title = title)
        ..contentDetails = (youtube.PlaylistContentDetails()..itemCount = itemCount);
    } catch (_) {
      return null;
    }
  }

  Future<void> _saveCustomPlaylistsToDisk() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList('custom_playlists', _customPlaylistIds.toList());
  }

  Future<void> _pickFolder() async {
    final folder = await _downloadService.selectOutputDirectory();
    if (folder != null) {
      setState(() => _selectedDirectoryPath = folder);
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('saved_output_dir', folder);
      _addLog('Folder salvat: $folder');
    }
  }

  Future<void> _stopDownload() async => _job.cancel();

  String _extractPlaylistId(String input) {
    String clean = input.trim();
    if (clean.contains('list=')) {
      try {
        final uri = Uri.parse(clean);
        clean = uri.queryParameters['list'] ?? clean;
      } catch (_) {
        final regExp = RegExp(r'list=([a-zA-Z0-9_-]+)');
        final match = regExp.firstMatch(clean);
        if (match != null) clean = match.group(1) ?? clean;
      }
    }
    return clean;
  }

  Future<void> _addCollaborativePlaylistToList(String input) async {
    final api = await _getYouTubeApi();
    if (api == null) return;

    final cleanId = _extractPlaylistId(input);
    if (_playlists.any((p) => p.id == cleanId)) {
      _addLog('[INFO] Playlist-ul există deja în listă.');
      return;
    }

    _addLog('[INFO] Preluare informații pentru playlist-ul $cleanId...');
    final newPlaylist = await _fetchSinglePlaylist(api, cleanId);

    if (newPlaylist != null) {
      setState(() {
        _playlists.insert(0, newPlaylist);
        _customPlaylistIds.add(cleanId);
      });
      await _saveCustomPlaylistsToDisk();
      _addLog('[SUCCESS] S-a adăugat: "${newPlaylist.snippet?.title}"!');
    } else {
      _addLog('[ERROR] Nu s-au putut prelua detaliile playlist-ului $cleanId.');
      _showErrorDialog(
        'Eroare adăugare playlist',
        'Nu s-a putut citi playlistul cu ID-ul:\n$cleanId\n\n'
        '• Playlistul trebuie să fie Public sau Nepublicat (Unlisted) — cele Private ale altor conturi nu pot fi citite.\n'
        '• Mixurile generate automat de YouTube (ID care începe cu "RD") nu sunt accesibile prin API.\n'
        '• Verifică să fi copiat linkul întreg (cu "list=...").',
      );
    }
  }

  Future<void> _removeCustomPlaylist(String id) async {
    setState(() {
      _playlists.removeWhere((p) => p.id == id);
      _customPlaylistIds.remove(id);
    });
    await _saveCustomPlaylistsToDisk();
    _addLog('[INFO] Playlist-ul a fost șters de pe disc.');
  }

  void _showAddCollaborativePlaylistDialog() {
    final TextEditingController urlController = TextEditingController();

    showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('Adaugă Playlist Colaborativ / Link'),
          content: TextField(
            controller: urlController,
            autofocus: true,
            maxLines: 3,
            minLines: 1,
            decoration: const InputDecoration(
              hintText: 'Lipește link-ul sau ID-ul playlist-ului',
              border: OutlineInputBorder(),
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context), child: const Text('Anulează')),
            ElevatedButton(
              onPressed: () async {
                final input = urlController.text.trim();
                if (input.isNotEmpty) {
                  Navigator.pop(context);
                  await _addCollaborativePlaylistToList(input);
                }
              },
              child: const Text('Adaugă & Salvează'),
            ),
          ],
        );
      },
    );
  }

  Future<void> _syncPlaylistLocal(youtube.Playlist playlist) async {
    final youtubeApi = await _getYouTubeApi();
    if (youtubeApi == null) return;

    if (_selectedDirectoryPath == null) {
      await _pickFolder();
      if (_selectedDirectoryPath == null) {
        _showErrorDialog('Atenție', 'Trebuie să selectezi un folder de salvare.');
        return;
      }
    }

    final playlistTitle = playlist.snippet?.title ?? 'Playlist';
    final outcome = await _job.run(
      api: youtubeApi,
      playlistId: playlist.id!,
      playlistTitle: playlistTitle,
      targetDirectoryPath: _selectedDirectoryPath!,
    );

    // Ecranul poate fi închis între timp — descărcarea a continuat în fundal.
    if (outcome == null || !mounted) return;
    final result = outcome.result;
    if (outcome.error != null) {
      _showErrorDialog('Eroare Descărcare', outcome.error);
    } else if (outcome.emptyPlaylist) {
      _showErrorDialog('Sync', 'Playlistul este gol.');
    } else if (result != null && !result.isCancelled) {
      final totalDone = result.successCount + result.skippedCount;
      if (result.failedSongs.isNotEmpty) {
        _showErrorDialog(
          'Rezultat Descărcare',
          'S-au procesat $totalDone din ${outcome.itemCount} piese.\n\nErori:\n• ${result.failedSongs.join('\n• ')}',
        );
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Playlist "$playlistTitle" sincronizat cu succes!'),
            backgroundColor: Colors.green,
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final isLoggedIn = _credentials != null;

    return Scaffold(
      appBar: AppBar(
        title: const Text("Downloader & Sync"),
        actions: [
          if (isLoggedIn)
            IconButton(
              icon: const Icon(Icons.add_link),
              onPressed: _syncingPlaylistId != null ? null : _showAddCollaborativePlaylistDialog,
              tooltip: "Adaugă playlist (Link/ID)",
            ),
          if (isLoggedIn)
            IconButton(
              icon: const Icon(Icons.folder_open),
              onPressed: _syncingPlaylistId != null ? null : _pickFolder,
              tooltip: "Alege folderul",
            ),
          if (isLoggedIn)
            IconButton(
              icon: const Icon(Icons.logout),
              onPressed: _syncingPlaylistId != null ? null : _handleSignOut,
              tooltip: "Deconectare",
            )
        ],
      ),
      body: !isLoggedIn
          ? Center(
              child: ElevatedButton.icon(
                icon: const Icon(Icons.login),
                label: const Text('Conectează-te cu Google'),
                onPressed: () => _handleSignIn(),
              ),
            )
          : Column(
              children: [
                Expanded(
                  child: _isLoading
                      ? const Center(child: CircularProgressIndicator())
                      : Column(
                          children: [
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                              child: Row(
                                children: [
                                  const Icon(Icons.folder),
                                  const SizedBox(width: 10),
                                  Expanded(
                                    child: Text(
                                      _selectedDirectoryPath != null
                                          ? 'Salvare în: $_selectedDirectoryPath'
                                          : 'Niciun folder selectat',
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                                  TextButton.icon(
                                    icon: const Icon(Icons.edit, size: 16),
                                    label: const Text('Schimbă'),
                                    onPressed: _syncingPlaylistId != null ? null : _pickFolder,
                                  )
                                ],
                              ),
                            ),
                            if (_syncingPlaylistId != null)
                              Card(
                                margin: const EdgeInsets.all(12),
                                child: Padding(
                                  padding: const EdgeInsets.all(16.0),
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Row(
                                        children: [
                                          const CircularProgressIndicator(),
                                          const SizedBox(width: 12),
                                          Expanded(
                                            child: Text(
                                              _currentSongTitle.isNotEmpty ? '🎵 $_currentSongTitle' : 'Se conectează...',
                                              overflow: TextOverflow.ellipsis,
                                            ),
                                          ),
                                          ElevatedButton.icon(
                                            icon: const Icon(Icons.stop),
                                            label: Text(_isCancelling ? 'Se oprește...' : 'STOP'),
                                            onPressed: _isCancelling ? null : _stopDownload,
                                          ),
                                        ],
                                      ),
                                      const SizedBox(height: 8),
                                      Text(_syncStatusText),
                                      const SizedBox(height: 6),
                                      LinearProgressIndicator(value: _songProgress > 0 ? _songProgress : null),
                                      const SizedBox(height: 6),
                                      LinearProgressIndicator(value: _overallProgress),
                                    ],
                                  ),
                                ),
                              ),
                            Expanded(
                              flex: 3,
                              child: ListView.builder(
                                itemCount: _playlists.length,
                                itemBuilder: (context, index) {
                                  final item = _playlists[index];
                                  final isThisSyncing = _syncingPlaylistId == item.id;
                                  final isCustomSaved = _customPlaylistIds.contains(item.id);

                                  return Card(
                                    margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                                    child: ListTile(
                                      leading: const Icon(Icons.queue_music, size: 32),
                                      title: Text(
                                        item.snippet?.title ?? 'Fără titlu',
                                        maxLines: 2,
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                      subtitle: Text("${item.contentDetails?.itemCount ?? 0} piese pe YouTube ${isCustomSaved ? '• (Salvat)' : ''}"),
                                      // Butoane doar cu iconițe: cu text, titlul rămânea strivit într-o coloană îngustă.
                                      trailing: Row(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          if (isCustomSaved && _syncingPlaylistId == null)
                                            IconButton(
                                              icon: const Icon(Icons.delete_outline, color: Colors.redAccent),
                                              tooltip: 'Scoate din listă',
                                              onPressed: () => _removeCustomPlaylist(item.id!),
                                            ),
                                          isThisSyncing
                                              ? const Padding(
                                                  padding: EdgeInsets.all(12),
                                                  child: SizedBox(
                                                    width: 24,
                                                    height: 24,
                                                    child: CircularProgressIndicator(strokeWidth: 3),
                                                  ),
                                                )
                                              : IconButton.filledTonal(
                                                  icon: const Icon(Icons.download),
                                                  tooltip: 'Descarcă',
                                                  onPressed: _syncingPlaylistId != null ? null : () => _syncPlaylistLocal(item),
                                                ),
                                        ],
                                      ),
                                    ),
                                  );
                                },
                              ),
                            ),
                            Container(
                              height: 100,
                              width: double.infinity,
                              margin: const EdgeInsets.all(8),
                              padding: const EdgeInsets.all(8),
                              color: Colors.black87,
                              child: ListView.builder(
                                controller: _logScrollController,
                                itemCount: _logs.length,
                                itemBuilder: (context, idx) => Text(
                                  _logs[idx],
                                  style: const TextStyle(color: Colors.greenAccent, fontSize: 11, fontFamily: 'monospace'),
                                ),
                              ),
                            ),
                          ],
                        ),
                ),
                const PersistentBottomMiniPlayer(),
              ],
            ),
    );
  }
}