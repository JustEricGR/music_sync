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

// Importurile tale de teme și widget-uri
import 'themes/theme_provider.dart';
import 'themes/app_themes.dart';
import 'widgets/dynamic_player.dart';
import 'download_service.dart';

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

enum SongSortOrder { oldestFirst, newestFirst }

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
}

// ==========================================
// GLOBAL AUDIO PLAYER STATE (PROVIDER)
// ==========================================
class GlobalAudioState extends ChangeNotifier {
  static final GlobalAudioState instance = GlobalAudioState._internal();
  factory GlobalAudioState() => instance;
  GlobalAudioState._internal() {
    _initListeners();
  }

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
          artUri: Uri.parse('asset:///assets/yugoslavia.jpg'),
        ),
      );
    }).toList();

    final playlistSource = ConcatenatingAudioSource(children: audioSources);

    await audioPlayer.setAudioSource(playlistSource, initialIndex: index);
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
// APPLICATION MAIN ENTRY POINT
// ==========================================
void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await JustAudioBackground.init(
    androidNotificationChannelId: 'com.example.musicsync_app.audio',
    androidNotificationChannelName: 'MusicSync Player',
    androidNotificationOngoing: true,
    androidStopForegroundOnPause: true,
    androidNotificationIcon: 'mipmap/ic_launcher',
  );

  try {
    final session = await AudioSession.instance;
    await session.configure(const AudioSessionConfiguration.music());
  } catch (e) {
    debugPrint('[AudioSession] configure failed: $e');
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

class MusicSyncApp extends StatelessWidget {
  const MusicSyncApp({super.key});

  @override
  Widget build(BuildContext context) {
    final themeProvider = Provider.of<ThemeProvider>(context);

    return MaterialApp(
      title: 'MusicSync',
      debugShowCheckedModeBanner: false,
      theme: themeProvider.themeData,
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
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) {
        final themeProvider = Provider.of<ThemeProvider>(ctx, listen: false);

        final themes = [
          ('grecia', 'Grecia', '🇬🇷', const Color(0xFF1A5FA8), const Color(0xFFF4EED8), [
            'assets/images/greece/greece1.jpg',
            'assets/images/greece/greece2.jpg',
            'assets/images/greece/greece3.jpg',
            'assets/images/greece/greece4.jpg',
            'assets/images/greece/greece5.jpg',
            'assets/images/greece/greece6.jpg',
            'assets/images/greece/greece7.jpg'
          ]),
          ('armenia', 'Armenia', '🇦🇲', const Color(0xFFC8241A), const Color(0xFF1A100A), [
            'assets/images/armenia/armenia1.jpg',
            'assets/images/armenia/armenia2.jpg',
            'assets/images/armenia/armenia3.jpg',
            'assets/images/armenia/armenia4.jpg',
            'assets/images/armenia/armenia5.jpg'
          ]),
          ('iran', 'Iran', '🇮🇷', const Color(0xFFD4890A), const Color(0xFF1A0F00), [
            'assets/images/iran/iran1.jpg',
            'assets/images/iran/iran2.jpg',
            'assets/images/iran/iran3.jpg',
            'assets/images/iran/iran4.jpg',
            'assets/images/iran/iran5.jpg',
            'assets/images/iran/iran6.jpg',
            'assets/images/iran/iran7.jpg',
            'assets/images/iran/iran8.jpg'
          ]),
          ('turcia', 'Turcia', '🇹🇷', const Color(0xFF1B6CA8), const Color(0xFF1C1208), [
            'assets/images/turkey/turkey1.jpg',
            'assets/images/turkey/turkey2.jpg',
            'assets/images/turkey/turkey3.jpg',
            'assets/images/turkey/turkey4.jpg',
            'assets/images/turkey/turkey5.jpg',
            'assets/images/turkey/turkey6.jpg'
          ]),
          ('azerbaidjan', 'Azerbaidjan', '🇦🇿', const Color(0xFF00B9E4), const Color(0xFF180A10), [
            'assets/images/azerbaijan/azerbaijan1.jpg'
          ]),
          ('kurdistan', 'Kurdistan', '☀️', const Color(0xFF00B9E4), const Color(0xFF180A10), [
            'assets/images/kurdistan/kurdistan1.jpg',
            'assets/images/kurdistan/kurdistan2.jpg',
            'assets/images/kurdistan/kurdistan3.jpg',
            'assets/images/kurdistan/kurdistan4.jpg'
          ]),
          ('bosnia', 'Bosnia', '🇧🇦', const Color(0xFF00B9E4), const Color(0xFF180A10), [
            'assets/images/bosnia/bosnia1.jpg'
          ]),
          ('central asia', 'Central Asia', '🌍', const Color(0xFF00B9E4), const Color(0xFF180A10), [
            'assets/images/central_asia/central_asia1.jpg'
          ]),
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
                  const SizedBox(height: 16),
                  Expanded(
                    child: ListView.builder(
                      controller: controller,
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      itemCount: themes.length,
                      itemBuilder: (context, i) {
                        final t = themes[i];
                        final id = t.$1; final name = t.$2; final emoji = t.$3;
                        final accent = t.$4; final bg = t.$5; final urls = t.$6;
                        
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
                                    children: urls.map((url) => Expanded(
                                      child: Image.asset(
                                        url, 
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
                    const SizedBox(height: 32),

                    // CARD 1: DOWNLOADER & SYNC
                    Center(
                      child: Container(
                        constraints: const BoxConstraints(maxWidth: 800),
                        child: Card(
                          elevation: 4,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(16),
                            side: BorderSide(
                              color: _isOffline ? Colors.grey : moodColors.gradientColors.first, 
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
                                  padding: const EdgeInsets.symmetric(vertical: 20.0, horizontal: 16.0),
                                  child: Column(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Icon(
                                        Icons.cloud_download, 
                                        size: 54, 
                                        color: _isOffline ? Colors.grey : moodColors.gradientColors.first
                                      ),
                                      const SizedBox(height: 12),
                                      Text(
                                        "Downloader & Sync",
                                        style: TextStyle(
                                          fontSize: 20, 
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
                                Positioned.fill(
                                  child: Container(
                                    decoration: BoxDecoration(
                                      color: Colors.black.withOpacity(0.8),
                                      borderRadius: BorderRadius.circular(16),
                                    ),
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
                        constraints: const BoxConstraints(maxWidth: 800),
                        child: Card(
                          elevation: 4,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(16),
                            side: BorderSide(
                              color: moodColors.gradientColors.last, 
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
                              padding: const EdgeInsets.symmetric(vertical: 20.0, horizontal: 16.0),
                              child: Column(
                                children: [
                                  Icon(
                                    Icons.library_music, 
                                    size: 54, 
                                    color: moodColors.gradientColors.last
                                  ),
                                  const SizedBox(height: 12),
                                  const Text("Library & Music Player", style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
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
// DETAILED PLAYLIST PLAYER SCREEN (FULLSCREEN BACKGROUND)
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
    if (totalCount <= 1) return Colors.transparent;

    double ratio = index / (totalCount - 1);
    if (_sortOrder == SongSortOrder.newestFirst) {
      ratio = 1.0 - ratio;
    }

    // Folosim culori foarte transparente pentru rânduri ca să se vadă fundalul din spate
    return Colors.black.withOpacity(0.05 + (ratio * 0.1));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final themeProvider = Provider.of<ThemeProvider>(context);
    final countryTheme = themeProvider.currentTheme;

    // Map-ul tău complet cu pozele locale din assets
    final Map<String, List<String>> countryPhotos = {
      'grecia': [
        'assets/images/greece/greece1.jpg',
        'assets/images/greece/greece2.jpg',
        'assets/images/greece/greece3.jpg',
        'assets/images/greece/greece4.jpg',
        'assets/images/greece/greece5.jpg',
        'assets/images/greece/greece6.jpg',
        'assets/images/greece/greece7.jpg'
      ],
      'armenia': [
        'assets/images/armenia/armenia1.jpg',
        'assets/images/armenia/armenia2.jpg',
        'assets/images/armenia/armenia3.jpg',
        'assets/images/armenia/armenia4.jpg',
        'assets/images/armenia/armenia5.jpg'
      ],
      'iran': [
        'assets/images/iran/iran1.jpg',
        'assets/images/iran/iran2.jpg',
        'assets/images/iran/iran3.jpg',
        'assets/images/iran/iran4.jpg',
        'assets/images/iran/iran5.jpg',
        'assets/images/iran/iran6.jpg',
        'assets/images/iran/iran7.jpg',
        'assets/images/iran/iran8.jpg'
      ],
      'turcia': [
        'assets/images/turkey/turkey1.jpg',
        'assets/images/turkey/turkey2.jpg',
        'assets/images/turkey/turkey3.jpg',
        'assets/images/turkey/turkey4.jpg',
        'assets/images/turkey/turkey5.jpg',
        'assets/images/turkey/turkey6.jpg'
      ],
      'azerbaidjan': [
        'assets/images/azerbaijan/azerbaijan1.jpg'
      ],
      'kurdistan': [
        'assets/images/kurdistan/kurdistan1.jpg',
        'assets/images/kurdistan/kurdistan2.jpg',
        'assets/images/kurdistan/kurdistan3.jpg',
        'assets/images/kurdistan/kurdistan4.jpg'
      ],
      'bosnia': [
        'assets/images/bosnia/bosnia1.jpg'
      ],
      'central asia': [
        'assets/images/central_asia/central_asia1.jpg'
      ],
    };

    final urls = countryPhotos[countryTheme.id] ?? [];

    return Scaffold(
      backgroundColor: countryTheme.scaffoldBackground,
      // Folosim extendBodyBehindAppBar pentru ca fundalul să urce și sub bara de sus
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
                  ? "${_allFiles.length} din ${widget.playlist.totalYoutubeCount} piese salvate"
                  : "${_allFiles.length} piese locale",
              style: const TextStyle(fontSize: 11, color: Colors.white70, shadows: [Shadow(color: Colors.black, blurRadius: 4)]),
            ),
          ],
        ),
        actions: [
          IconButton(
            icon: Icon(_sortOrder == SongSortOrder.oldestFirst ? Icons.sort_by_alpha : Icons.swap_vert, color: Colors.white),
            tooltip: _sortOrder == SongSortOrder.oldestFirst ? "Sortează: Cele mai Noi Primele" : "Sortează: Cele mai Vechi Primele",
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
              // 1. IMAGINILE PE TOT ECRANUL (FUNDALUL)
              Positioned.fill(
                child: urls.isNotEmpty
                    ? Row(
                        children: urls.map((url) => Expanded(
                          child: Image.asset(
                            url, 
                            fit: BoxFit.cover,
                            errorBuilder: (_, __, ___) => Container(color: countryTheme.scaffoldBackground),
                          ),
                        )).toList(),
                      )
                    : Container(color: countryTheme.scaffoldBackground),
              ),

              // 2. FILTRU DE INTUNECARE ȘI GRADIENT PENTRU CITIBILITATE TEXT
              Positioned.fill(
                child: Container(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [
                        Colors.black.withOpacity(0.5), // Sus, sub AppBar
                        moodColors.gradientColors.first.withOpacity(0.75), // La mijloc împrumută culoarea temei
                        Colors.black.withOpacity(0.92), // Jos, unde e textul și butoanele mari
                      ],
                    ),
                  ),
                ),
              ),

              // 3. INTERFAȚA ȘI CONTROALELE (STRATUL DIN FAȚĂ)
              SafeArea(
                child: Column(
                  children: [
                    // Căutarea - o facem semi-transparentă elegantă
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 8.0),
                      child: TextField(
                        controller: _searchController,
                        onChanged: (value) {
                          _searchQuery = value;
                          _applySortingAndFiltering();
                        },
                        style: const TextStyle(color: Colors.white),
                        decoration: InputDecoration(
                          hintText: "Caută o melodie...",
                          hintStyle: const TextStyle(color: Colors.white60),
                          prefixIcon: const Icon(Icons.search, color: Colors.white70),
                          suffixIcon: _searchQuery.isNotEmpty 
                              ? IconButton(
                                  icon: const Icon(Icons.clear, color: Colors.white70),
                                  onPressed: () {
                                    _searchController.clear();
                                    _searchQuery = "";
                                    _applySortingAndFiltering();
                                  },
                                )
                              : null,
                          filled: true,
                          fillColor: Colors.black.withOpacity(0.3),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(12),
                            borderSide: BorderSide.none,
                          ),
                          contentPadding: const EdgeInsets.symmetric(vertical: 8),
                        ),
                      ),
                    ),

                    const Spacer(),

                    // Secțiunea Info Melodie Curentă
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 24.0),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.center,
                        children: [
                          Text(
                            audioState.currentSongTitle.isNotEmpty ? audioState.currentSongTitle : 'Selectează o melodie',
                            textAlign: TextAlign.center,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: moodColors.textColor,
                              fontSize: 22,
                              fontWeight: FontWeight.bold,
                              shadows: const [Shadow(color: Colors.black87, blurRadius: 10, offset: Offset(0, 2))],
                            ),
                          ),
                          const SizedBox(height: 6),
                          Text(
                            audioState.currentArtist.isNotEmpty ? audioState.currentArtist : '',
                            textAlign: TextAlign.center,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: moodColors.textColor.withOpacity(0.85),
                              fontSize: 15,
                              fontWeight: FontWeight.w500,
                              shadows: const [Shadow(color: Colors.black87, blurRadius: 8)],
                            ),
                          ),
                        ],
                      ),
                    ),

                    const SizedBox(height: 24),

                    // Slider și Controale Media
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 20),
                      child: Column(
                        children: [
                          Slider(
                            value: audioState.position.inSeconds.toDouble().clamp(0.0, audioState.duration.inSeconds.toDouble()),
                            max: audioState.duration.inSeconds > 0 ? audioState.duration.inSeconds.toDouble() : 1.0,
                            activeColor: moodColors.accentColor,
                            inactiveColor: Colors.white24,
                            onChanged: (val) {
                              audioState.audioPlayer.seek(Duration(seconds: val.toInt()));
                            },
                          ),
                          Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 16.0),
                            child: Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                Text(_formatDuration(audioState.position), style: const TextStyle(fontSize: 12, color: Colors.white70)),
                                Text(_formatDuration(audioState.duration), style: const TextStyle(fontSize: 12, color: Colors.white70)),
                              ],
                            ),
                          ),
                          Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              IconButton(
                                iconSize: 36,
                                icon: const Icon(Icons.skip_previous, color: Colors.white),
                                onPressed: () => audioState.playPrevious(),
                              ),
                              const SizedBox(width: 16),
                              IconButton(
                                iconSize: 58,
                                icon: Icon(audioState.isPlaying ? Icons.pause_circle_filled : Icons.play_circle_filled),
                                color: moodColors.accentColor,
                                onPressed: () => audioState.togglePlayPause(),
                              ),
                              const SizedBox(width: 16),
                              IconButton(
                                iconSize: 36,
                                icon: const Icon(Icons.skip_next, color: Colors.white),
                                onPressed: () => audioState.playNext(),
                              ),
                            ],
                            ),
                        ],
                      ),
                    ),

                    const SizedBox(height: 16),
                    const Divider(color: Colors.white12, height: 1),

                    // Lista de Melodii (Ocupă jumătatea de jos a ecranului)
                    Expanded(
                      child: Container(
                        color: Colors.black.withOpacity(0.4), // Fundal obscurizat sub listă
                        child: _displayedFiles.isEmpty
                            ? const Center(child: Text("Nu s-a găsit nicio melodie.", style: TextStyle(color: Colors.white70)))
                            : ListView.builder(
                                padding: const EdgeInsets.only(top: 8, bottom: 16),
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
                                    tileColor: isSelected ? moodColors.accentColor.withOpacity(0.25) : tileBgColor,
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
                                      style: TextStyle(fontSize: 11, color: isSelected ? moodColors.accentColor.withOpacity(0.8) : Colors.white60),
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
        [youtube.YouTubeApi.youtubeReadonlyScope, 'https://www.googleapis.com/auth/userinfo.email'],
      ),
    );
    return youtube.YouTubeApi(authClient);
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
      _addLog('[SUCCESS] S-a adăugat: "${newPlaylist.snippet?.title}"!');
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
        _addLog('Finalizat! Noi: ${result.successCount}, Existente: ${result.skippedCount}');

        if (result.failedSongs.isNotEmpty) {
          _showErrorDialog(
            'Rezultat Descărcare',
            'S-au procesat $totalDone din ${itemsList.length} piese.\n\nErori:\n• ' + result.failedSongs.join('\n• '),
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