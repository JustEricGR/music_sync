import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
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
import 'themes/theme_provider.dart';
import 'themes/app_themes.dart';
import 'widgets/dynamic_player.dart';

import 'download_service.dart';

// just_audio_background handles the OS media session, notification controls,
// lock screen, headphone buttons, and wake lock automatically.
// No custom AudioHandler needed.

// ==========================================
// UTILITY: EXTRAGERE ARTIST & TITLU
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
}


void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // just_audio_background initialises the foreground service, media session,
  // notification controls, lock screen, headphone buttons, and wake lock.
  await JustAudioBackground.init(
    androidNotificationChannelId: 'com.example.musicsync_app.audio',
    androidNotificationChannelName: 'MusicSync Player',
    androidNotificationOngoing: true,
    androidStopForegroundOnPause: true,
  );

  // Configure audio_session for music playback focus.
  try {
    final session = await AudioSession.instance;
    await session.configure(const AudioSessionConfiguration.music());
  } catch (e) {
    debugPrint('[AudioSession] configure failed: \$e');
  }

  await DownloadNotificationManager.init();

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

// ADAUGAT: greekAesthetic și turkicAesthetic în listă
enum AppThemeMode { light, dark, jetbrainsHighContrast, nordic, neon, greekAesthetic, turkicAesthetic }
enum SongSortOrder { oldestFirst, newestFirst }
enum SongMood { chill, energetic, happy, sad }

// ==========================================
// GLOBAL AUDIO PLAYER STATE
// ==========================================
class GlobalAudioState extends ChangeNotifier {
  static final GlobalAudioState instance = GlobalAudioState._internal();
  factory GlobalAudioState() => instance;
  GlobalAudioState._internal() {
    _initListeners();
  }

  // just_audio's AudioPlayer — works with just_audio_background for
  // screen-off playback, notification controls, and wake lock automatically.
  final AudioPlayer audioPlayer = AudioPlayer();

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

  void _initListeners() {
    // just_audio uses streams instead of callbacks.
    audioPlayer.playerStateStream.listen((state) {
      isPlaying = state.playing;
      notifyListeners();
    });

    audioPlayer.durationStream.listen((d) {
      duration = d ?? Duration.zero;
      notifyListeners();
    });

    audioPlayer.positionStream.listen((p) {
      position = p;
      notifyListeners();
    });

    // Autoplay: when a song finishes, advance to the next one.
    // just_audio fires processingState == completed when the track ends.
    audioPlayer.playerStateStream.listen((state) {
      if (state.processingState == ProcessingState.completed) {
        playNext();
      }
    });
  }

  Future<void> loadPlaylist(LocalPlaylistModel playlistModel, int initialIndex) async {
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
    final file = playlistFiles[currentIndex];

    final fileName = file.path.split(Platform.pathSeparator).last;
    final meta = parseArtistAndTitle(fileName);
    currentSongTitle = meta.title;
    currentArtist = meta.artist;

    // AudioSource.file with tag — just_audio_background reads the tag to
    // populate the notification with title, artist, and album automatically.
    final source = AudioSource.file(
      file.path,
      tag: MediaItem(
        id: file.path,
        title: currentSongTitle,
        artist: currentArtist,
        album: currentPlaylistTitle ?? '',
      ),
    );

    await audioPlayer.setAudioSource(source);
    await audioPlayer.play();

    notifyListeners();
  }

  Future<void> togglePlayPause({bool? forcePlay, bool? forcePause}) async {
    if (forcePlay == true) {
      await audioPlayer.play();
    } else if (forcePause == true) {
      await audioPlayer.pause();
    } else {
      isPlaying ? await audioPlayer.pause() : await audioPlayer.play();
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

  Future<void> stop() async {
    await audioPlayer.stop();
    playlistFiles.clear();
    currentSongTitle = "";
    currentArtist = "";
    currentPlaylistTitle = null;
    currentPlaylistModel = null;
    notifyListeners();
  }
}

// ==========================================
// APP INITIALIZATION & THEMES
// ==========================================
class MusicSyncApp extends StatefulWidget {
  const MusicSyncApp({super.key});

  @override
  State<MusicSyncApp> createState() => _MusicSyncAppState();
}

class _MusicSyncAppState extends State<MusicSyncApp> {
  AppThemeMode _currentTheme = AppThemeMode.jetbrainsHighContrast;

  @override
  void initState() {
    super.initState();
    _loadSavedTheme();
  }

  // Ajutător pentru sincronizarea cu noul tău motor de teme din lib/
  void _syncWithLibraryThemeProvider(AppThemeMode mode) {
    if (!mounted) return;
    final provider = Provider.of<ThemeProvider>(context, listen: false);
    
    if (mode == AppThemeMode.greekAesthetic) {
      provider.switchTheme('grecia');
    } else if (mode == AppThemeMode.turkicAesthetic) {
      provider.switchTheme('iran');
    }
  }

  Future<void> _loadSavedTheme() async {
    final prefs = await SharedPreferences.getInstance();
    final themeIndex = prefs.getInt('app_theme') ?? AppThemeMode.jetbrainsHighContrast.index;
    
    setState(() {
      _currentTheme = AppThemeMode.values[themeIndex];
    });

    // Sincronizează tema estetică la pornirea aplicației
    _syncWithLibraryThemeProvider(_currentTheme);
  }

  Future<void> _setTheme(AppThemeMode theme) async {
    setState(() {
      _currentTheme = theme;
    });
    
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt('app_theme', theme.index);

    // Sincronizează tema estetică imediat ce userul o schimbă din Hub
    _syncWithLibraryThemeProvider(theme);
  }

  ThemeData _getThemeData() {
    switch (_currentTheme) {
      case AppThemeMode.light:
        return ThemeData(
          brightness: Brightness.light,
          primarySwatch: Colors.deepPurple,
          scaffoldBackgroundColor: const Color(0xFFF5F5F7),
          cardColor: Colors.white,
          appBarTheme: const AppBarTheme(backgroundColor: Colors.deepPurple, foregroundColor: Colors.white),
        );
      case AppThemeMode.dark:
        return ThemeData(
          brightness: Brightness.dark,
          scaffoldBackgroundColor: const Color(0xFF121212),
          cardColor: const Color(0xFF1E1E1E),
          appBarTheme: const AppBarTheme(backgroundColor: Color(0xFF1F1F1F), foregroundColor: Colors.white),
        );
      case AppThemeMode.jetbrainsHighContrast:
        return ThemeData(
          brightness: Brightness.dark,
          scaffoldBackgroundColor: Colors.black,
          cardColor: const Color(0xFF141414),
          colorScheme: const ColorScheme.dark(
            primary: Color(0xFFFFE600),
            secondary: Color(0xFF00FF66),
          ),
          appBarTheme: const AppBarTheme(
            backgroundColor: Colors.black,
            foregroundColor: Color(0xFFFFE600),
          ),
        );
      case AppThemeMode.nordic:
        return ThemeData(
          brightness: Brightness.dark,
          scaffoldBackgroundColor: const Color(0xFF2E3440),
          cardColor: const Color(0xFF3B4252),
          colorScheme: const ColorScheme.dark(
            primary: Color(0xFF88C0D0),
            secondary: Color(0xFFA3BE8C),
          ),
          appBarTheme: const AppBarTheme(backgroundColor: Color(0xFF242933), foregroundColor: Color(0xFF88C0D0)),
        );
      case AppThemeMode.neon:
        return ThemeData(
          brightness: Brightness.dark,
          scaffoldBackgroundColor: const Color(0xFF0F051D),
          cardColor: const Color(0xFF29104D),
          colorScheme: const ColorScheme.dark(
            primary: Color(0xFFFF007F),
            secondary: Color(0xFF00F0FF),
          ),
          appBarTheme: const AppBarTheme(backgroundColor: Color(0xFF1A0933), foregroundColor: Color(0xFF00F0FF)),
        );
      case AppThemeMode.greekAesthetic:
        return ThemeData(
          brightness: Brightness.light,
          scaffoldBackgroundColor: const Color(0xFFF4F7F6),
          cardColor: Colors.white,
          colorScheme: const ColorScheme.light(
            primary: Color(0xFF0D47A1), 
            secondary: Color(0xFF4FC3F7),
          ),
          appBarTheme: const AppBarTheme(backgroundColor: Color(0xFF0D47A1), foregroundColor: Colors.white),
        );
      case AppThemeMode.turkicAesthetic:
        return ThemeData(
          brightness: Brightness.dark,
          scaffoldBackgroundColor: const Color(0xFF1C1310),
          cardColor: const Color(0xFF2E1F1A),
          colorScheme: const ColorScheme.dark(
            primary: Color(0xFFD84315), 
            secondary: Color(0xFF00ACC1),
          ),
          appBarTheme: const AppBarTheme(backgroundColor: Color(0xFF2E1F1A), foregroundColor: Color(0xFF00ACC1)),
        );
    }
  }


  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'MusicSync',
      debugShowCheckedModeBanner: false,
      theme: _getThemeData(),
      home: MainHubScreen(
        currentTheme: _currentTheme,
        onThemeChanged: _setTheme,
      ),
    );
  }
}

// ==========================================
// MAIN HUB SCREEN (REPARAT ALINIERE / OFFSET ICONURI)
// ==========================================
class MainHubScreen extends StatefulWidget {
  final AppThemeMode currentTheme;
  final Function(AppThemeMode) onThemeChanged;

  const MainHubScreen({
    super.key,
    required this.currentTheme,
    required this.onThemeChanged,
  });

  @override
  State<MainHubScreen> createState() => _MainHubScreenState();
}

class _MainHubScreenState extends State<MainHubScreen> {
  bool _isOffline = false;
  late StreamSubscription<List<ConnectivityResult>> _connectivitySubscription;
  String? _userEmail;
  String? _userName;

  @override
  void initState() {
    super.initState();
    _checkInitialConnectivity();
    _loadUserEmail();
    _connectivitySubscription = Connectivity().onConnectivityChanged.listen((results) {
      setState(() {
        _isOffline = results.contains(ConnectivityResult.none);
      });
    });
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
    _connectivitySubscription.cancel();
    super.dispose();
  }

  void _showThemePicker() {
    showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('Selectează Tema'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                ListTile(
                  leading: const Icon(Icons.bolt, color: Color(0xFFFFE600)),
                  title: const Text('JetBrains High Contrast (Dark)'),
                  onTap: () {
                    widget.onThemeChanged(AppThemeMode.jetbrainsHighContrast);
                    Navigator.pop(context);
                  },
                ),
                ListTile(
                  leading: const Icon(Icons.ac_unit, color: Color(0xFF88C0D0)),
                  title: const Text('JetBrains Nordic Frost'),
                  onTap: () {
                    widget.onThemeChanged(AppThemeMode.nordic);
                    Navigator.pop(context);
                  },
                ),
                ListTile(
                  leading: const Icon(Icons.color_lens, color: Color(0xFFFF007F)),
                  title: const Text('Vivid Cyber Neon'),
                  onTap: () {
                    widget.onThemeChanged(AppThemeMode.neon);
                    Navigator.pop(context);
                  },
                ),
                ListTile(
                  leading: const Icon(Icons.account_balance, color: Color(0xFF0D47A1)),
                  title: const Text('Greek Statue Aesthetic'),
                  onTap: () {
                    widget.onThemeChanged(AppThemeMode.greekAesthetic);
                    Navigator.pop(context);
                  },
                ),
                ListTile(
                  leading: const Icon(Icons.brightness_low, color: Color(0xFFD84315)),
                  title: const Text('Turkic Nomad Aesthetic'),
                  onTap: () {
                    widget.onThemeChanged(AppThemeMode.turkicAesthetic);
                    Navigator.pop(context);
                  },
                ),
                ListTile(
                  leading: const Icon(Icons.nightlight_round, color: Colors.blueGrey),
                  title: const Text('Dark Standard'),
                  onTap: () {
                    widget.onThemeChanged(AppThemeMode.dark);
                    Navigator.pop(context);
                  },
                ),
                ListTile(
                  leading: const Icon(Icons.wb_sunny, color: Colors.orange),
                  title: const Text('Light Classic'),
                  onTap: () {
                    widget.onThemeChanged(AppThemeMode.light);
                    Navigator.pop(context);
                  },
                ),
              ],
            ),
          ),
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

    final moodColors = (currentCountryTheme != null && currentCountryTheme.playerMoods[currentMood] != null)
        ? currentCountryTheme.playerMoods[currentMood]!
        : PlayerColors(
            gradientColors: [theme.colorScheme.primary, theme.colorScheme.secondary],
            textColor: theme.colorScheme.onPrimary,
            accentColor: theme.colorScheme.secondary,
          );

    return Scaffold(
      backgroundColor: currentCountryTheme?.scaffoldBackground ?? theme.scaffoldBackgroundColor,
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
            alignment: Alignment.center,
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 40, minHeight: 40),
            icon: const Icon(Icons.palette_outlined),
            onPressed: _showThemePicker,
            tooltip: "Schimbă Tema",
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(24.0),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  // STATUT CONEXIUNE (ONLINE / OFFLINE)
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
                        crossAxisAlignment: CrossAxisAlignment.center,
                        children: [
                          Icon(
                            _isOffline ? Icons.wifi_off : Icons.wifi, 
                            color: Colors.white, 
                            size: 20
                          ),
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
                  const SizedBox(height: 32),

                  // CARD 1: DOWNLOADER & SYNC
                  Center(
                    child: Container(
                      constraints: const BoxConstraints(maxWidth: 800, maxHeight: 180),
                      child: Card(
                        elevation: 4,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(16),
                          side: BorderSide(
                            color: _isOffline ? Colors.grey : (moodColors.gradientColors.firstOrNull ?? theme.colorScheme.primary), 
                            width: 2,
                          ),
                        ),
                        child: Stack(
                          children: [
                            InkWell(
                              onTap: _isOffline
                                  ? null
                                  : () async {
                                      await Navigator.push(
                                        context,
                                        MaterialPageRoute(
                                          builder: (context) => const MusicSyncHomePage(),
                                        ),
                                      );
                                      _loadUserEmail();
                                    },
                              borderRadius: BorderRadius.circular(16),
                              child: Padding(
                                padding: const EdgeInsets.all(24.0),
                                child: Column(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  crossAxisAlignment: CrossAxisAlignment.center,
                                  children: [
                                    SizedBox(
                                      height: 54,
                                      child: Center(
                                        child: Icon(
                                          Icons.cloud_download, 
                                          size: 54, 
                                          color: _isOffline ? Colors.grey : (moodColors.gradientColors.firstOrNull ?? theme.colorScheme.primary)
                                        ),
                                      ),
                                    ),
                                    const SizedBox(height: 12),
                                    Text(
                                      "Downloader & Sync",
                                      style: TextStyle(
                                        fontSize: 22, 
                                        fontWeight: FontWeight.bold, 
                                        color: _isOffline ? Colors.grey : null
                                      ),
                                    ),
                                    const SizedBox(height: 6),
                                    Text(
                                      "Music downloader",
                                      textAlign: TextAlign.center,
                                      style: TextStyle(color: _isOffline ? Colors.grey : Colors.grey.shade400, fontSize: 13),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                            if (_isOffline)
                              Container(
                                decoration: BoxDecoration(
                                  color: Colors.black.withOpacity(0.8),
                                  borderRadius: BorderRadius.circular(16),
                                ),
                                child: const Center(
                                  child: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    crossAxisAlignment: CrossAxisAlignment.center,
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
                  ),

                  const SizedBox(height: 24),

                  // CARD 2: LIBRARY & MUSIC PLAYER
                  Center(
                    child: Container(
                      constraints: const BoxConstraints(maxWidth: 800, maxHeight: 180),
                      child: Card(
                        elevation: 4,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(16),
                          side: BorderSide(
                            color: moodColors.gradientColors.lastOrNull ?? theme.colorScheme.secondary, 
                            width: 2,
                          ),
                        ),
                        child: InkWell(
                          onTap: () {
                            Navigator.push(
                              context,
                              MaterialPageRoute(
                                builder: (context) => const LocalLibraryScreen(),
                              ),
                            );
                          },
                          borderRadius: BorderRadius.circular(16),
                          child: Padding(
                            padding: const EdgeInsets.all(24.0),
                            child: Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              crossAxisAlignment: CrossAxisAlignment.center,
                              children: [
                                SizedBox(
                                  height: 54,
                                  child: Center(
                                    child: Icon(
                                      Icons.library_music, 
                                      size: 54, 
                                      color: moodColors.gradientColors.lastOrNull ?? theme.colorScheme.secondary
                                    ),
                                  ),
                                ),
                                const SizedBox(height: 12),
                                const Text("Library & Music Player", style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold)),
                                const SizedBox(height: 6),
                                Text(
                                  "Listen music",
                                  textAlign: TextAlign.center,
                                  style: TextStyle(color: Colors.grey.shade400, fontSize: 13),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          const PersistentBottomMiniPlayer(),
        ],
      ),
    );
  }
}

// ==========================================
// PERSISTENT MINI PLAYER WITH CLICK-TO-OPEN
// ==========================================
class PersistentBottomMiniPlayer extends StatelessWidget {
  const PersistentBottomMiniPlayer({super.key});

  @override
  Widget build(BuildContext context) {
    // These must be fetched here in build(), not inside AnimatedBuilder,
    // because StatelessWidget has no state and no field to store them.
    final audioState = Provider.of<GlobalAudioState>(context);
    final theme = Theme.of(context);

    return AnimatedBuilder(
      animation: audioState,
      builder: (context, child) {
        if (audioState.currentPlaylistTitle == null || audioState.currentPlaylistModel == null) {
          return const SizedBox.shrink();
        }

        final totalCount = audioState.playlistFiles.length;
        final currentPos = audioState.currentIndex + 1;

        return InkWell(
          onTap: () {
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
                Icon(Icons.music_note, color: theme.colorScheme.primary),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        audioState.currentSongTitle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
                      ),
                      Text(
                        "🎤 ${audioState.currentArtist} • 📁 ${audioState.currentPlaylistTitle} ($currentPos/$totalCount)",
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
                IconButton(
                  icon: const Icon(Icons.skip_next),
                  onPressed: () => audioState.playNext(),
                ),
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
// LOCAL LIBRARY & PLAYER MODELS
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
          
          final files = entity.listSync().whereType<File>().where((f) {
            final ext = f.path.toLowerCase();
            return ext.endsWith('.mp3') || ext.endsWith('.m4a') || ext.endsWith('.wav');
          }).toList();

          files.sort((a, b) => a.lastModifiedSync().compareTo(b.lastModifiedSync()));

          final totalYt = prefs.getInt('playlist_total_$folderName');

          if (files.isNotEmpty) {
            foundPlaylists.add(LocalPlaylistModel(
              title: folderName,
              directory: entity,
              audioFiles: files,
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

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final audioState = Provider.of<GlobalAudioState>(context);
    final themeProvider = Provider.of<ThemeProvider>(context);
    final currentCountryTheme = themeProvider.currentTheme;
    final moodColors = (currentCountryTheme != null && currentCountryTheme.playerMoods[audioState.currentMood] != null)
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
                                  ? "${playlist.audioFiles.length} / ${playlist.totalYoutubeCount} piese descărcate"
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
                                  trailing: const Icon(Icons.play_circle_fill, size: 36),
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

// ==========================================
// PLAYER SCREEN WITH SORTING, SEARCHING & COLORING
// ==========================================
class PlaylistPlayerScreen extends StatefulWidget {
  final LocalPlaylistModel playlist;

  const PlaylistPlayerScreen({super.key, required this.playlist});

  @override
  State<PlaylistPlayerScreen> createState() => _PlaylistPlayerScreenState();
}

class _PlaylistPlayerScreenState extends State<PlaylistPlayerScreen> {
  final audioState = GlobalAudioState.instance;
  SongSortOrder _sortOrder = SongSortOrder.oldestFirst;
  
  // ADAUGAT: Liste pentru filtrarea la căutare
  List<File> _allFiles = [];
  List<File> _displayedFiles = [];
  final TextEditingController _searchController = TextEditingController();
  String _searchQuery = "";

  @override
  void initState() {
    super.initState();
    _allFiles = List.from(widget.playlist.audioFiles);
    _applySortingAndFiltering(shouldLoadPlaylist: true);
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  // ADAUGAT: Logică combinată de sortare și filtrare text
  void _applySortingAndFiltering({bool shouldLoadPlaylist = false}) {
    List<File> filtered = _allFiles.where((file) {
      final fileName = file.path.split(Platform.pathSeparator).last.toLowerCase();
      return fileName.contains(_searchQuery.toLowerCase());
    }).toList();

    filtered.sort((a, b) {
      final modA = a.lastModifiedSync();
      final modB = b.lastModifiedSync();
      return _sortOrder == SongSortOrder.oldestFirst ? modA.compareTo(modB) : modB.compareTo(modA);
    });

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

  void _toggleSortOrder() {
    setState(() {
      _sortOrder = _sortOrder == SongSortOrder.oldestFirst ? SongSortOrder.newestFirst : SongSortOrder.oldestFirst;
    });
    _applySortingAndFiltering();
  }

  String _formatDuration(Duration d) {
    final minutes = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final seconds = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return "$minutes:$seconds";
  }

  Color _getSongAgeColor(BuildContext context, int index, int totalCount) {
    if (totalCount <= 1) return Theme.of(context).cardColor;

    double ratio = index / (totalCount - 1);
    if (_sortOrder == SongSortOrder.newestFirst) {
      ratio = 1.0 - ratio;
    }

    final isDark = Theme.of(context).brightness == Brightness.dark;
    
    final baseDark = isDark ? const Color(0xFF16181D) : const Color(0xFFE2E4E9);
    final baseLight = isDark ? const Color(0xFF2E3545) : const Color(0xFFFFFFFF);

    return Color.lerp(baseDark, baseLight, ratio)!;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(widget.playlist.title, style: const TextStyle(fontSize: 16)),
            Text(
              widget.playlist.totalYoutubeCount != null
                  ? "${_allFiles.length} din ${widget.playlist.totalYoutubeCount} piese salvate"
                  : "${_allFiles.length} piese locale",
              style: const TextStyle(fontSize: 11, color: Colors.white70),
            ),
          ],
        ),
        actions: [
          IconButton(
            icon: Icon(_sortOrder == SongSortOrder.oldestFirst ? Icons.sort_by_alpha : Icons.swap_vert),
            tooltip: _sortOrder == SongSortOrder.oldestFirst ? "Sortează: Cele mai Noi Primele" : "Sortează: Cele mai Vechi Primele",
            onPressed: _toggleSortOrder,
          ),
        ],
      ),
      body: AnimatedBuilder(
        animation: audioState,
        builder: (context, child) {
          return Column(
            children: [
              // ADAUGAT: Caseta de căutare intuitivă
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 8.0),
                child: TextField(
                  controller: _searchController,
                  onChanged: (value) {
                    _searchQuery = value;
                    _applySortingAndFiltering();
                  },
                  decoration: InputDecoration(
                    hintText: "Caută o melodie în playlist...",
                    prefixIcon: const Icon(Icons.search),
                    suffixIcon: _searchQuery.isNotEmpty 
                        ? IconButton(
                            icon: const Icon(Icons.clear),
                            onPressed: () {
                              _searchController.clear();
                              _searchQuery = "";
                              _applySortingAndFiltering();
                            },
                          )
                        : null,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                    contentPadding: const EdgeInsets.symmetric(vertical: 8),
                  ),
                ),
              ),

              Padding(
                padding: const EdgeInsets.all(16.0),
                child: Column(
                  children: [
                    Container(
                      width: 60,
                      height: 60,
                      decoration: BoxDecoration(
                        color: theme.colorScheme.primary.withOpacity(0.15),
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(color: theme.colorScheme.primary, width: 2),
                      ),
                      child: Icon(Icons.music_note, size: 32, color: theme.colorScheme.primary),
                    ),
                    const SizedBox(height: 10),
                    Text(
                      audioState.currentSongTitle.isNotEmpty ? audioState.currentSongTitle : "Nicio piesă",
                      textAlign: TextAlign.center,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      audioState.currentArtist.isNotEmpty ? audioState.currentArtist : "Artist Necunoscut",
                      style: TextStyle(color: theme.colorScheme.secondary, fontSize: 13, fontWeight: FontWeight.bold),
                    ),
                  ],
                ),
              ),

              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: Column(
                  children: [
                    Slider(
                      value: audioState.position.inSeconds.toDouble().clamp(0.0, audioState.duration.inSeconds.toDouble()),
                      max: audioState.duration.inSeconds > 0 ? audioState.duration.inSeconds.toDouble() : 1.0,
                      activeColor: theme.colorScheme.primary,
                      onChanged: (val) {
                        audioState.audioPlayer.seek(Duration(seconds: val.toInt()));
                      },
                    ),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(_formatDuration(audioState.position), style: const TextStyle(fontSize: 11)),
                        Text(_formatDuration(audioState.duration), style: const TextStyle(fontSize: 11)),
                      ],
                    ),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        IconButton(
                          iconSize: 32,
                          icon: const Icon(Icons.skip_previous),
                          onPressed: () => audioState.playPrevious(),
                        ),
                        const SizedBox(width: 16),
                        IconButton(
                          iconSize: 48,
                          icon: Icon(audioState.isPlaying ? Icons.pause_circle_filled : Icons.play_circle_filled),
                          color: theme.colorScheme.primary,
                          onPressed: () => audioState.togglePlayPause(),
                        ),
                        const SizedBox(width: 16),
                        IconButton(
                          iconSize: 32,
                          icon: const Icon(Icons.skip_next),
                          onPressed: () => audioState.playNext(),
                        ),
                      ],
                    ),
                  ],
                ),
              ),

              const Divider(height: 1),

              Expanded(
                child: _displayedFiles.isEmpty
                    ? const Center(child: Text("Nu s-a găsit nicio melodie."))
                    : ListView.builder(
                        itemCount: _displayedFiles.length,
                        itemBuilder: (context, idx) {
                          final file = _displayedFiles[idx];
                          final fileName = file.path.split(Platform.pathSeparator).last;
                          final meta = parseArtistAndTitle(fileName);
                          
                          final isSelected = audioState.playlistFiles.isNotEmpty &&
                              audioState.currentIndex < audioState.playlistFiles.length &&
                              audioState.playlistFiles[audioState.currentIndex].path == file.path &&
                              audioState.currentPlaylistTitle == widget.playlist.title;
                              
                          final tileBgColor = _getSongAgeColor(context, idx, _displayedFiles.length);

                          return ListTile(
                            tileColor: isSelected ? theme.colorScheme.primary.withOpacity(0.2) : tileBgColor,
                            dense: true,
                            leading: isSelected
                                ? Icon(Icons.graphic_eq, color: theme.colorScheme.primary)
                                : Text("${idx + 1}", style: const TextStyle(color: Colors.grey, fontSize: 11)),
                            title: Text(
                              meta.title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                                color: isSelected ? theme.colorScheme.primary : null,
                              ),
                            ),
                            subtitle: Text(
                              meta.artist,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(fontSize: 11, color: isSelected ? theme.colorScheme.primary.withOpacity(0.8) : Colors.grey),
                            ),
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
                        },
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
// DOWNLOADER SCREEN
// ==========================================
class MusicSyncHomePage extends StatefulWidget {
  const MusicSyncHomePage({super.key});

  @override
  State<MusicSyncHomePage> createState() => _MusicSyncHomePageState();
}

class _MusicSyncHomePageState extends State<MusicSyncHomePage> {
  final GoogleSignIn _googleSignIn = GoogleAuthManager.instance;
  final DownloadSyncService _downloadService = DownloadSyncService();

  GoogleSignInCredentials? _credentials;
  List<youtube.Playlist> _playlists = [];
  Set<String> _customPlaylistIds = {};
  bool _isLoading = false;
  String? _userDisplayName;

  String? _syncingPlaylistId;
  String _currentSongTitle = '';
  String _syncStatusText = '';
  double _overallProgress = 0.0;
  double _songProgress = 0.0;
  bool _isCancelling = false;

  final List<String> _logs = [];
  final ScrollController _logScrollController = ScrollController();

  String? _selectedDirectoryPath;

  @override
  void initState() {
    super.initState();
    _autoRestoreLogin();
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
    _logScrollController.dispose();
    _downloadService.dispose();
    super.dispose();
  }

  void _addLog(String message) {
    if (message.isEmpty) return;
    setState(() {
      _logs.add("${DateTime.now().toString().split('.').first.split(' ').last} - $message");
    });
    Future.delayed(const Duration(milliseconds: 100), () {
      if (_logScrollController.hasClients) {
        _logScrollController.jumpTo(_logScrollController.position.maxScrollExtent);
      }
    });
  }

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
        
        if (email != null && email.isNotEmpty) {
          await prefs.setString('user_logged_email', email);
        }
        if (name != null && name.isNotEmpty) {
          await prefs.setString('user_logged_name', name);
        }

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
        setState(() {
          _credentials = creds;
        });

        if (creds.accessToken != null) {
          await _fetchAndSaveUserEmail(creds.accessToken!);
        }

        await _fetchPlaylists();
      } else if (!isAutoLogin) {
        _showErrorDialog('Autentificare', 'Conectarea a fost anulată.');
      }
    } catch (e) {
      if (!isAutoLogin) {
        _showErrorDialog('Eroare Google Sign-In', e);
      }
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
        _logs.clear();
      });
    } catch (e) {
      _showErrorDialog('Eroare la Deconectare', e);
    }
  }

  Future<youtube.YouTubeApi?> _getYouTubeApi() async {
    if (_credentials == null || _credentials!.accessToken == null) return null;

    final authClient = authenticatedClient(
      http.Client(),
      AccessCredentials(
        AccessToken('Bearer', _credentials!.accessToken!, DateTime.now().toUtc().add(const Duration(hours: 1))),
        null,
        [
          youtube.YouTubeApi.youtubeReadonlyScope,
          'https://www.googleapis.com/auth/userinfo.email',
        ],
      ),
    );

    return youtube.YouTubeApi(authClient);
  }

  Future<void> _fetchPlaylists() async {
    final youtubeApi = await _getYouTubeApi();
    if (youtubeApi == null) return;

    setState(() {
      _isLoading = true;
    });

    try {
      final response = await youtubeApi.playlists.list(
        ['snippet', 'contentDetails'],
        mine: true,
        maxResults: 50,
      );

      List<youtube.Playlist> fetched = response.items ?? [];

      final prefs = await SharedPreferences.getInstance();
      final savedIds = prefs.getStringList('custom_playlists') ?? [];
      _customPlaylistIds = savedIds.toSet();

      for (String customId in _customPlaylistIds) {
        if (!fetched.any((p) => p.id == customId)) {
          final loadedCustom = await _fetchSinglePlaylist(youtubeApi, customId);
          if (loadedCustom != null) {
            fetched.insert(0, loadedCustom);
          }
        }
      }

      setState(() {
        _playlists = fetched;
      });

      _addLog('S-au încărcat ${_playlists.length} playlist-uri.');
    } catch (e) {
      _showErrorDialog('Eroare YouTube Playlists', e);
    } finally {
      setState(() {
        _isLoading = false;
      });
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
      setState(() {
        _selectedDirectoryPath = folder;
      });

      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('saved_output_dir', folder);

      _addLog('Folder salvat: $folder');
    }
  }

  Future<void> _stopDownload() async {
    _addLog('[USER ACTION] Butonul STOP a fost apăsat.');
    setState(() {
      _isCancelling = true;
      _syncStatusText = 'Oprire în curs...';
    });
    _downloadService.cancelDownload();

    Future.delayed(const Duration(seconds: 2), () {
      if (mounted && _syncingPlaylistId != null) {
        setState(() {
          _syncingPlaylistId = null;
          _isCancelling = false;
        });
        _addLog('[INFO] Interfața a fost deblocată forțat.');
      }
    });
  }

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
      _addLog('[SUCCESS] S-a adăugat și salvat pe disc: "${newPlaylist.snippet?.title}"!');
    } else {
      _addLog('[ERROR] Nu s-au putut prelua detaliile playlist-ului.');
      _showErrorDialog('Eroare adăugare playlist', 'Nu s-a putut găsi playlist-ul cu acest link.');
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

    final playlistId = playlist.id!;
    final playlistTitle = playlist.snippet?.title ?? 'Playlist';

    setState(() {
      _syncingPlaylistId = playlistId;
      _currentSongTitle = '';
      _syncStatusText = 'Obținere melodii de la API YouTube...';
      _overallProgress = 0.0;
      _songProgress = 0.0;
      _isCancelling = false;
    });

    _addLog('Inițiere descărcare playlist: "$playlistTitle"');

    try {
      List<youtube.PlaylistItem> itemsList = [];
      String? nextPageToken;

      do {
        final res = await youtubeApi.playlistItems.list(
          ['snippet', 'contentDetails'],
          playlistId: playlistId,
          maxResults: 50,
          pageToken: nextPageToken,
        );
        if (res.items != null) itemsList.addAll(res.items!);
        nextPageToken = res.nextPageToken;
      } while (nextPageToken != null && !_isCancelling);

      if (_isCancelling) return;

      if (itemsList.isEmpty) {
        _addLog('Playlist-ul este gol.');
        _showErrorDialog('Sync', 'Playlistul este gol.');
        return;
      }

      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt('playlist_total_$playlistTitle', itemsList.length);

      await _executeDownloadProcess(playlistTitle, itemsList);
    } catch (e) {
      _addLog('[EXCEPȚIE GENERALĂ] $e');
      _showErrorDialog('Eroare Descărcare', e);
    } finally {
      if (mounted) {
        setState(() {
          _syncingPlaylistId = null;
          _overallProgress = 0.0;
          _songProgress = 0.0;
          _isCancelling = false;
        });
      }
    }
  }

  Future<void> _executeDownloadProcess(String playlistTitle, List<youtube.PlaylistItem> itemsList) async {
    _addLog('S-au găsit ${itemsList.length} piese în playlist.');

    final result = await _downloadService.downloadPlaylistWithProgress(
      playlistTitle: playlistTitle,
      items: itemsList,
      targetDirectoryPath: _selectedDirectoryPath!,
      onProgress: (DownloadProgressInfo info) {
        if (mounted) {
          setState(() {
            _currentSongTitle = info.currentSongTitle;
            _syncStatusText = info.statusMessage;
            _overallProgress = info.overallProgress;
            _songProgress = info.songProgress;
          });
          if (info.logMessage.isNotEmpty) _addLog(info.logMessage);
        }
      },
    );

    if (mounted) {
      if (result.isCancelled) {
        _addLog('[STOP] Descărcare oprită de utilizator.');
      } else {
        final totalDone = result.successCount + result.skippedCount;
        _addLog('Finalizat! Descărcate noi: ${result.successCount}, Existente deja: ${result.skippedCount}');

        if (result.failedSongs.isNotEmpty) {
          _showErrorDialog(
            'Rezultat Descărcare',
            'S-au procesat $totalDone din ${itemsList.length} piese.\n\n'
            'Erori:\n• ' + result.failedSongs.join('\n• '),
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
                                      title: Text(item.snippet?.title ?? 'Fără titlu'),
                                      subtitle: Text("${item.contentDetails?.itemCount ?? 0} piese pe YouTube ${isCustomSaved ? '• (Salvat)' : ''}"),
                                      trailing: Row(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          if (isCustomSaved && _syncingPlaylistId == null)
                                            IconButton(
                                              icon: const Icon(Icons.delete_outline, color: Colors.redAccent),
                                              onPressed: () => _removeCustomPlaylist(item.id!),
                                            ),
                                          ElevatedButton.icon(
                                            icon: Icon(isThisSyncing ? Icons.sync : Icons.download),
                                            label: Text(isThisSyncing ? 'În curs...' : 'Descărcă'),
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