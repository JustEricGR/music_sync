import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show MethodChannel;
import 'package:flutter_map/flutter_map.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';
import 'package:provider/provider.dart';
import 'package:permission_handler/permission_handler.dart' show Permission, PermissionActions, PermissionCheckShortcuts;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

import '../main.dart' show GlobalAudioState, PersistentBottomMiniPlayer;
import 'disk_cache.dart';
import 'geo.dart';
import 'place_locator.dart';
import 'radio_favorites.dart';
import 'radio_repository.dart';
import 'radio_station.dart';
import 'song_recognizer.dart';
import 'station_clusters.dart';
import 'stream_finder.dart';

/// Lista mondială de posturi se reîmprospătează automat (pe Wi-Fi) după atâtea zile.
const Duration _kWorldRefreshAge = Duration(days: 7);

// Centrul Greciei — poziția implicită a hărții înainte de primul GPS.
const LatLng _kDefaultCenter = LatLng(39.07, 21.82);

/// Limite pentru "Salvează harta zonei" (politica serverelor de tile-uri
/// gratuite interzice descărcarea masivă / la zoom mare).
const int _kPrefetchMaxZoom = 14;
const int _kPrefetchMaxTiles = 2000;

enum _RecognitionSource { stream, microphone }

enum _RecognitionState { idle, listening, searching }

class RadioScreen extends StatefulWidget {
  static const String routeName = '/radio';

  /// Mini-playerul cere: arată postul care rulează în lista orașului lui.
  /// (Valoarea crește la fiecare cerere, ca ecranul deja deschis să reacționeze.)
  static final ValueNotifier<int> focusPlayingRequests = ValueNotifier(0);

  /// La deschidere, du-te direct la postul care rulează.
  final bool focusPlaying;

  const RadioScreen({super.key, this.focusPlaying = false});

  @override
  State<RadioScreen> createState() => _RadioScreenState();
}

class _RadioScreenState extends State<RadioScreen> with SingleTickerProviderStateMixin {
  late final TabController _tabs = TabController(length: 4, vsync: this);
  bool _focusPending = false;

  final RadioRepository _repo = RadioRepository();
  final SongRecognizer _recognizer = SongRecognizer();
  final MapController _mapController = MapController();
  final CachedTileProvider _tileProvider = CachedTileProvider();
  StreamSubscription<List<ConnectivityResult>>? _connectivitySub;

  // Locație / țară
  CountryLocator? _locator;
  double? _lat;
  double? _lon;
  bool _hasLiveFix = false;
  bool _locating = false;
  String? _locationError;
  CountryInfo? _country;

  /// GPS-ul telefonului e oprit / permisiunea refuzată — arătăm clar asta
  /// și cerem pornirea, în loc să afișăm în tăcere o poziție veche.
  bool _locationServiceOff = false;
  bool _permissionDenied = false;
  bool _askedToEnableLocation = false;
  StreamSubscription<ServiceStatus>? _serviceStatusSub;

  // Posturi (lista: țara mea sau țara aleasă)
  List<RadioStation> _remoteStations = [];
  List<RadioStation> _manualStations = [];
  bool _loadingStations = false;
  String? _stationsError;
  DateTime? _cacheTime;
  bool _isOffline = false;
  bool _isUnmetered = false; // Wi-Fi / Ethernet
  StationSort _sort = StationSort.nearby;
  String _filter = '';

  /// Țara răsfoită în listă; null = țara în care ești.
  CountryInfo? _browseCountry;

  // Toate posturile unei țări (și cele fără coordonate, plasate după oraș
  // sau la capitală) — încărcate când țara e în listă sau în centrul hărții.
  PlaceLocator? _places;
  final Map<String, List<RadioStation>> _countryAll = {};
  final Map<String, DateTime?> _countryFetchedAt = {};
  final Set<String> _countryLoading = {};
  Timer? _countryLoadTimer;

  // Posturile lumii (cu coordonate) — pentru harta tip Radio Garden
  List<RadioStation> _worldStations = [];
  DateTime? _worldFetchedAt;
  bool _loadingWorld = false;
  String? _worldError;
  List<RadioStation> _mapStations = [];
  List<StationCluster> _clusters = [];
  Timer? _reclusterTimer;

  // Hartă
  bool _mapReady = false;
  bool _centeredOnUser = false;
  bool _prefetching = false;
  bool _prefetchCancelled = false;
  int _prefetchDone = 0;
  int _prefetchTotal = 0;

  // Recunoaștere
  _RecognitionSource? _sourceChoice; // null = automat
  _RecognitionState _recState = _RecognitionState.idle;
  RecognizedSong? _lastResult;
  bool _lastNotFound = false;
  String? _recError;
  List<RecognizedSong> _history = [];

  List<RadioStation> get _allStations => [..._manualStations, ..._remoteStations];

  bool get _showUserPosition => _hasLiveFix && !_locationServiceOff && !_permissionDenied;

  @override
  void initState() {
    super.initState();
    _focusPending = widget.focusPlaying;
    RadioScreen.focusPlayingRequests.addListener(_onFocusRequest);
    _init();
  }

  void _onFocusRequest() {
    _focusPending = true;
    _focusPlayingStation();
  }

  /// Duce harta la orașul de unde a fost ales postul care rulează și
  /// redeschide lista posturilor de acolo, cu postul selectat.
  void _focusPlayingStation() {
    if (!_focusPending || !mounted) return;
    final audio = GlobalAudioState.instance;
    final station = audio.currentRadio;
    if (station == null) {
      _focusPending = false;
      return;
    }
    final ctx = audio.radioMapContext ??
        (station.hasLocation ? (lat: station.lat!, lon: station.lon!, zoom: 11.0) : null);
    if (ctx == null) {
      _focusPending = false;
      _tabs.animateTo(station.isManual ? 1 : (RadioFavorites.instance.isFavorite(station.uuid) ? 2 : 1));
      return;
    }
    _tabs.animateTo(0);
    if (!_mapReady) return; // reluat din onMapReady
    _focusPending = false;
    _mapController.move(LatLng(ctx.lat, ctx.lon), ctx.zoom);
    _reclusterTimer?.cancel();
    _recluster();
    final cluster = _clusters.where((c) => c.stations.any((s) => s.uuid == station.uuid)).firstOrNull ??
        StationCluster([station], ctx.lat, ctx.lon);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _showClusterSheet(cluster, focusUuid: station.uuid);
    });
  }

  @override
  void dispose() {
    RadioScreen.focusPlayingRequests.removeListener(_onFocusRequest);
    _tabs.dispose();
    _connectivitySub?.cancel();
    _serviceStatusSub?.cancel();
    _reclusterTimer?.cancel();
    _countryLoadTimer?.cancel();
    _prefetchCancelled = true;
    _recognizer.dispose();
    _mapController.dispose();
    super.dispose();
  }

  Future<void> _init() async {
    final connectivity = await Connectivity().checkConnectivity();
    _applyConnectivity(connectivity);
    _connectivitySub = Connectivity().onConnectivityChanged.listen((results) {
      final cameOnline = _isOffline && !results.contains(ConnectivityResult.none);
      if (mounted) setState(() => _applyConnectivity(results));
      if (cameOnline) {
        _refreshStations();
        _maybeAutoDownloadWorld();
      }
    });

    _manualStations = await _repo.loadManualStations();
    _history = await SongRecognizer.loadHistory();
    _locator = await CountryLocator.load();
    _places = await PlaceLocator.load();

    final world = await _repo.loadWorldCache();
    _worldStations = world.stations;
    _worldFetchedAt = world.fetchedAt;

    final last = await _repo.loadLastPosition();
    if (last != null) _setPosition(last.$1, last.$2, live: false);
    _watchLocationService();
    await _refreshStations(fetch: false);
    _rebuildMapStations();

    unawaited(_maybeAutoDownloadWorld());
    await _locate();
    // Fără GPS și fără o poziție salvată (ex. după reinstalare) lista rămânea
    // goală: pornim pe țara rețelei mobile (merge și fără GPS/internet),
    // apoi pe cea din setările telefonului, altfel pe Grecia.
    final locator = _locator;
    if (_country == null && locator != null && mounted) {
      final region = await _networkCountry() ??
          WidgetsBinding.instance.platformDispatcher.locale.countryCode?.toUpperCase();
      final all = locator.countries;
      final fallback = all.where((c) => c.code == region).firstOrNull ?? all.where((c) => c.code == 'GR').firstOrNull;
      if (fallback != null) setState(() => _country = fallback);
    }
    await _refreshStations(fetch: !_isOffline);
  }

  void _applyConnectivity(List<ConnectivityResult> results) {
    _isOffline = results.contains(ConnectivityResult.none);
    _isUnmetered = results.contains(ConnectivityResult.wifi) || results.contains(ConnectivityResult.ethernet);
  }

  CountryInfo? get _listCountry => _browseCountry ?? _country;

  static const MethodChannel _deviceChannel = MethodChannel('musicsync/device');

  /// Țara rețelei mobile (ex. "RO"), din cartela SIM — fără GPS.
  Future<String?> _networkCountry() async {
    if (!Platform.isAndroid) return null;
    try {
      final iso = await _deviceChannel.invokeMethod<String>('networkCountry');
      return (iso == null || iso.isEmpty) ? null : iso.toUpperCase();
    } catch (_) {
      return null;
    }
  }

  // ── Posturile lumii (hartă) ─────────────────────────────────────────────────

  /// Pe Wi-Fi descarcă singur lista mondială dacă lipsește sau e veche; pe
  /// date mobile doar la cerere (are ~17 MB).
  Future<void> _maybeAutoDownloadWorld() async {
    if (_isOffline || !_isUnmetered || _loadingWorld) return;
    final fetched = _worldFetchedAt;
    if (_worldStations.isNotEmpty && fetched != null && DateTime.now().difference(fetched) < _kWorldRefreshAge) {
      return;
    }
    await _downloadWorld();
  }

  Future<void> _downloadWorld() async {
    if (_isOffline) {
      _showSnack('Ai nevoie de internet pentru a descărca posturile lumii.');
      return;
    }
    setState(() {
      _loadingWorld = true;
      _worldError = null;
    });
    try {
      final stations = await _repo.fetchWorld();
      await _repo.saveWorldCache(stations);
      if (!mounted) return;
      setState(() {
        _worldStations = stations;
        _worldFetchedAt = DateTime.now();
      });
      _rebuildMapStations();
    } catch (e) {
      if (mounted) setState(() => _worldError = e.toString());
    } finally {
      if (mounted) setState(() => _loadingWorld = false);
    }
  }

  /// Toate posturile țării [code]: din cache, iar dacă [fetch] și lista e
  /// veche/lipsă (sau [force]) — din Radio Browser, plasate pe hartă.
  Future<void> _ensureCountryLoaded(String code, {required bool fetch, bool force = false}) async {
    if (_countryLoading.contains(code)) return;
    setState(() => _countryLoading.add(code));
    try {
      if (!_countryAll.containsKey(code)) {
        final cached = await _repo.loadCache(RadioRepository.countryAllKey(code));
        if (cached.stations.isNotEmpty) {
          _countryAll[code] = cached.stations;
          _countryFetchedAt[code] = cached.fetchedAt;
        }
      }
      final fetchedAt = _countryFetchedAt[code];
      final stale = fetchedAt == null || DateTime.now().difference(fetchedAt) > _kWorldRefreshAge;
      if (fetch && !_isOffline && (force || stale)) {
        final raw = await _repo.fetchCountryAll(code);
        final placed = [for (final s in raw) _places?.place(s) ?? s];
        await _repo.saveCache(RadioRepository.countryAllKey(code), placed);
        _countryAll[code] = placed;
        _countryFetchedAt[code] = DateTime.now();
      }
    } finally {
      if (mounted) setState(() => _countryLoading.remove(code));
    }
    _rebuildMapStations();
  }

  /// Când harta stă pe o țară (zoom de țară sau mai aproape), îi încărcăm
  /// toate posturile — ca în Radio Garden, harta se umple pe măsură ce explorezi.
  void _scheduleCountryLoad() {
    _countryLoadTimer?.cancel();
    _countryLoadTimer = Timer(const Duration(milliseconds: 900), () async {
      final locator = _locator;
      if (!_mapReady || locator == null || !mounted) return;
      final camera = _mapController.camera;
      if (camera.zoom < 4.5) return;
      final country = locator.lookup(camera.center.latitude, camera.center.longitude);
      if (country == null) return;
      try {
        await _ensureCountryLoaded(country.code, fetch: true);
      } catch (_) {}
    });
  }

  /// Toate posturile cu poziție cunoscută local (lume + țări încărcate +
  /// manuale), fără duplicate.
  void _rebuildMapStations() {
    final byUuid = <String, RadioStation>{};
    for (final s in _worldStations) {
      byUuid[s.uuid] = s;
    }
    for (final list in _countryAll.values) {
      for (final s in list) {
        if (s.hasLocation) byUuid.putIfAbsent(s.uuid, () => s);
      }
    }
    for (final s in [..._remoteStations, ..._manualStations]) {
      if (s.hasLocation) byUuid.putIfAbsent(s.uuid, () => s);
    }
    _mapStations = byUuid.values.toList();
    _recluster();
  }

  void _recluster() {
    if (!_mapReady || !mounted) return;
    final camera = _mapController.camera;
    final b = camera.visibleBounds;
    setState(() {
      _clusters = clusterStations(
        _mapStations,
        zoom: camera.zoom,
        south: b.south,
        west: b.west,
        north: b.north,
        east: b.east,
      );
    });
  }

  void _scheduleRecluster() {
    _reclusterTimer?.cancel();
    _reclusterTimer = Timer(const Duration(milliseconds: 150), _recluster);
  }

  void _setPosition(double lat, double lon, {required bool live}) {
    final country = _locator?.lookup(lat, lon);
    if (!mounted) return;
    setState(() {
      _lat = lat;
      _lon = lon;
      _hasLiveFix = _hasLiveFix || live;
      if (country != null) _country = country;
    });
    // Prima poziție (chiar și cea veche) centrează harta, apoi doar fix-urile GPS noi.
    if (_mapReady && (live || !_centeredOnUser)) {
      _centeredOnUser = true;
      _mapController.move(LatLng(lat, lon), max(_mapController.camera.zoom, 9));
    }
  }

  /// Când utilizatorul pornește/oprește locația din telefon, reacționăm imediat.
  void _watchLocationService() {
    try {
      _serviceStatusSub = Geolocator.getServiceStatusStream().listen((status) {
        final off = status == ServiceStatus.disabled;
        if (!mounted) return;
        setState(() {
          _locationServiceOff = off;
          if (off) _hasLiveFix = false;
        });
        if (!off) _locate();
      });
    } catch (_) {
      // Platformă fără flux de stare (ex. web) — verificăm doar la _locate().
    }
  }

  Future<void> _promptEnableLocation({required bool permission}) async {
    if (_askedToEnableLocation || !mounted) return;
    _askedToEnableLocation = true;
    final open = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        icon: const Icon(Icons.location_off, size: 36),
        title: Text(permission ? 'Permite accesul la locație' : 'Locația este oprită'),
        content: Text(
          permission
              ? 'MusicSync are nevoie de locație ca să găsească țara în care ești și posturile din jurul tău. '
                  'Permite accesul din setările aplicației.'
              : 'Pornește locația telefonului ca să vezi țara în care ești și posturile din jurul tău. '
                  'Până atunci, harta și lista folosesc ultima poziție cunoscută.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialogContext, false), child: const Text('Nu acum')),
          ElevatedButton.icon(
            icon: const Icon(Icons.settings),
            label: Text(permission ? 'Deschide setările' : 'Pornește locația'),
            onPressed: () => Navigator.pop(dialogContext, true),
          ),
        ],
      ),
    );
    if (open == true) {
      permission ? await Geolocator.openAppSettings() : await Geolocator.openLocationSettings();
    }
  }

  Future<void> _locate() async {
    setState(() {
      _locating = true;
      _locationError = null;
    });
    try {
      if (!await Geolocator.isLocationServiceEnabled()) {
        setState(() {
          _locationServiceOff = true;
          _hasLiveFix = false;
        });
        unawaited(_promptEnableLocation(permission: false));
        throw 'Locația telefonului este oprită.';
      }
      var permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }
      if (permission == LocationPermission.denied || permission == LocationPermission.deniedForever) {
        setState(() {
          _permissionDenied = true;
          _hasLiveFix = false;
        });
        unawaited(_promptEnableLocation(permission: true));
        throw 'Permisiunea de locație a fost refuzată.';
      }
      setState(() {
        _locationServiceOff = false;
        _permissionDenied = false;
      });

      final lastKnown = await Geolocator.getLastKnownPosition();
      if (lastKnown != null) _setPosition(lastKnown.latitude, lastKnown.longitude, live: false);

      // GPS-ul funcționează și fără internet.
      final pos = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.medium,
          timeLimit: Duration(seconds: 25),
        ),
      );
      final countryBefore = _country?.code;
      _setPosition(pos.latitude, pos.longitude, live: true);
      await _repo.saveLastPosition(pos.latitude, pos.longitude);

      // Altă țară decât cea afișată -> lista noii țări.
      if (_country?.code != countryBefore && _browseCountry == null) {
        await _refreshStations(fetch: !_isOffline);
      }
    } on TimeoutException {
      if (mounted) {
        setState(() => _locationError = 'GPS-ul nu a răspuns la timp — încearcă afară sau lângă o fereastră.');
      }
    } catch (e) {
      if (mounted) setState(() => _locationError = e.toString());
    } finally {
      if (mounted) setState(() => _locating = false);
    }
  }

  /// Butonul "Poziția mea": centrează imediat pe poziția cunoscută și cere
  /// una nouă; spune mereu ce se întâmplă.
  Future<void> _goToMyLocation() async {
    if (_locationServiceOff || _permissionDenied) {
      _askedToEnableLocation = false;
      await _promptEnableLocation(permission: _permissionDenied);
      return;
    }
    if (_lat != null && _mapReady) {
      _mapController.move(LatLng(_lat!, _lon!), max(_mapController.camera.zoom, 10));
    }
    if (_locating) {
      _showSnack('Se caută poziția GPS...');
      return;
    }
    if (_lat == null) _showSnack('Se caută poziția GPS...');
    await _locate();
    if (!mounted) return;
    if (_lat != null && _mapReady) {
      _mapController.move(LatLng(_lat!, _lon!), max(_mapController.camera.zoom, 10));
    } else if (_locationError != null) {
      _showSnack(_locationError!);
    }
  }

  /// Lista țării afișate: toate posturile ei (+ cele din jur de peste
  /// graniță, pentru țara mea). [fetch] = actualizează din internet dacă
  /// lista e veche; [force] = actualizează oricum (butonul de refresh).
  Future<void> _refreshStations({bool fetch = true, bool force = false}) async {
    final code = _listCountry?.code;
    if (code == null) return;
    if (force && _isOffline) _showSnack('Fără internet — se afișează posturile salvate.');

    setState(() {
      _loadingStations = true;
      _stationsError = null;
    });
    try {
      await _ensureCountryLoaded(code, fetch: fetch, force: force);

      var nearby = <RadioStation>[];
      if (_browseCountry == null && _lat != null) {
        nearby = _worldStations
            .where((s) => s.countryCode != code && (s.distanceKmFrom(_lat, _lon) ?? double.infinity) <= kNearbyRadiusKm)
            .toList();
      }
      if (!mounted || code != _listCountry?.code) return;
      final stations = [...?_countryAll[code], ...nearby];
      setState(() {
        _remoteStations = stations;
        _cacheTime = _countryFetchedAt[code];
      });
      _rebuildMapStations();
      if (fetch && !_isOffline) {
        // Logo-urile celor mai relevante posturi, pentru afișare offline.
        final top = sortStations(stations, StationSort.nearby, lat: _lat, lon: _lon).take(80);
        unawaited(DiskCache.prefetchLogos(top.map((s) => s.favicon)));
      }
    } catch (e) {
      if (mounted) setState(() => _stationsError = e.toString());
    } finally {
      if (mounted) setState(() => _loadingStations = false);
    }
  }

  void _showSnack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  /// [fromCluster] = postul a fost ales din lista unui oraș de pe hartă —
  /// mini-playerul va putea redeschide acea listă.
  Future<void> _play(RadioStation station, {StationCluster? fromCluster}) async {
    if (_isOffline) {
      _showSnack('Fără internet — postul nu poate fi ascultat acum.');
      return;
    }
    unawaited(_ensureBackgroundPlaybackAllowed());
    try {
      unawaited(_repo.reportClick(station));
      await GlobalAudioState.instance.playRadio(
        station,
        mapContext: fromCluster != null && _mapReady
            ? (lat: fromCluster.lat, lon: fromCluster.lon, zoom: _mapController.camera.zoom)
            : null,
      );
    } catch (e) {
      _showSnack('Stream indisponibil pentru "${station.name}": $e');
    }
  }

  /// Android oprește sau "sugrumă" aplicațiile în fundal pentru a economisi
  /// bateria — radioul se întrerupea cu ecranul stins. Cerem (o singură
  /// dată) scutirea de la optimizarea bateriei.
  Future<void> _ensureBackgroundPlaybackAllowed() async {
    if (!Platform.isAndroid) return;
    if (await Permission.ignoreBatteryOptimizations.isGranted) return;
    final prefs = await SharedPreferences.getInstance();
    if (prefs.getBool('asked_battery_optimization') == true || !mounted) return;
    await prefs.setBool('asked_battery_optimization', true);
    if (!mounted) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        icon: const Icon(Icons.battery_alert, size: 36),
        title: const Text('Radio fără întreruperi'),
        content: const Text(
          'Ca radioul să nu se oprească atunci când ieși din aplicație sau stingi ecranul, '
          'permite-i lui MusicSync să ruleze în fundal (fără restricții de baterie).',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialogContext, false), child: const Text('Nu acum')),
          ElevatedButton(onPressed: () => Navigator.pop(dialogContext, true), child: const Text('Permite')),
        ],
      ),
    );
    if (ok == true) await Permission.ignoreBatteryOptimizations.request();
  }

  // ── Posturi manuale ─────────────────────────────────────────────────────────

  /// Adaugă un post din site-ul lui (sau direct din linkul de stream): caută
  /// stream-ul în pagină, îl verifică și îl salvează cu nume și logo.
  Future<void> _showAddStationDialog() async {
    final urlController = TextEditingController();
    final nameController = TextEditingController();
    final finder = StreamFinder(directorySearch: _repo.searchByName);
    FoundStream? found;
    bool searching = false;
    String? error;

    final added = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) {
          Future<void> search() async {
            final input = urlController.text.trim();
            if (input.isEmpty) return;
            setDialogState(() {
              searching = true;
              error = null;
              found = null;
            });
            try {
              final result = await finder.find(input);
              setDialogState(() {
                found = result;
                if (result == null) {
                  error = 'N-am găsit stream pe această pagină. Deschide site-ul, apasă pe butonul '
                      '"Live / Ascultă" și lipește aici linkul acelei pagini.';
                } else if (nameController.text.trim().isEmpty && result.name != null) {
                  nameController.text = result.name!;
                }
              });
            } catch (e) {
              setDialogState(() => error = 'Site-ul nu răspunde: $e');
            } finally {
              setDialogState(() => searching = false);
            }
          }

          return AlertDialog(
            title: const Text('Adaugă post'),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Lipește site-ul radioului (ex. greca994.gr) sau direct linkul de stream. '
                    'Aplicația găsește singură stream-ul și verifică dacă merge.',
                    style: TextStyle(fontSize: 13),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: urlController,
                    maxLines: 2,
                    minLines: 1,
                    keyboardType: TextInputType.url,
                    decoration: InputDecoration(
                      labelText: 'Site sau link stream',
                      border: const OutlineInputBorder(),
                      suffixIcon: IconButton(icon: const Icon(Icons.search), onPressed: searching ? null : search),
                    ),
                    onSubmitted: (_) => search(),
                  ),
                  const SizedBox(height: 12),
                  if (searching)
                    const Row(
                      children: [
                        SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)),
                        SizedBox(width: 12),
                        Expanded(child: Text('Caut stream-ul pe site...')),
                      ],
                    ),
                  if (error != null) Text(error!, style: const TextStyle(color: Colors.redAccent, fontSize: 12)),
                  if (found != null) ...[
                    Row(
                      children: [
                        const Icon(Icons.check_circle, color: Colors.green, size: 18),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            'Stream găsit: ${found!.streamUrl}',
                            style: const TextStyle(fontSize: 12),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: nameController,
                      decoration: const InputDecoration(labelText: 'Nume post', border: OutlineInputBorder()),
                    ),
                    if (_lat != null)
                      const Padding(
                        padding: EdgeInsets.only(top: 8),
                        child: Text('Postul va apărea pe hartă la poziția ta curentă.', style: TextStyle(fontSize: 12)),
                      ),
                  ],
                ],
              ),
            ),
            actions: [
              TextButton(onPressed: () => Navigator.pop(dialogContext, false), child: const Text('Anulează')),
              if (found == null)
                ElevatedButton(onPressed: searching ? null : search, child: const Text('Caută'))
              else
                ElevatedButton(
                  onPressed: () {
                    if (nameController.text.trim().isEmpty) return;
                    Navigator.pop(dialogContext, true);
                  },
                  child: const Text('Adaugă'),
                ),
            ],
          );
        },
      ),
    );
    finder.dispose();
    final result = found;
    if (added != true || result == null) return;

    final station = await _repo.addManualStation(
      name: nameController.text.trim(),
      streamUrl: result.streamUrl,
      countryCode: _country?.code ?? '',
      homepage: result.homepage ?? '',
      favicon: result.favicon ?? '',
      lat: _lat,
      lon: _lon,
    );
    final manual = await _repo.loadManualStations();
    if (mounted) setState(() => _manualStations = manual);
    _rebuildMapStations();
    await _play(station);
  }

  Future<void> _chooseCountry() async {
    final locator = _locator;
    if (locator == null) return;
    final all = locator.countries;
    String query = '';

    // CountryInfo cu cod gol = "țara mea".
    final picked = await showDialog<CountryInfo>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) {
          final q = query.toLowerCase();
          final visible = all.where((c) => q.isEmpty || c.name.toLowerCase().contains(q) || c.code.toLowerCase() == q).toList();
          return Dialog(
            child: SizedBox(
              width: 420,
              height: MediaQuery.of(context).size.height * 0.75,
              child: Column(
                children: [
                  Padding(
                    padding: const EdgeInsets.all(12),
                    child: TextField(
                      autofocus: true,
                      onChanged: (v) => setDialogState(() => query = v),
                      decoration: const InputDecoration(
                        hintText: 'Caută țara...',
                        prefixIcon: Icon(Icons.search),
                        border: OutlineInputBorder(),
                        isDense: true,
                      ),
                    ),
                  ),
                  if (_country != null)
                    ListTile(
                      leading: const Icon(Icons.my_location),
                      title: Text('Țara mea (${_country!.name})'),
                      onTap: () => Navigator.pop(dialogContext, const CountryInfo('', '')),
                    ),
                  const Divider(height: 1),
                  Expanded(
                    child: ListView.builder(
                      itemCount: visible.length,
                      itemBuilder: (context, i) {
                        final c = visible[i];
                        return ListTile(
                          leading: Text(c.flag, style: const TextStyle(fontSize: 22)),
                          title: Text(c.name),
                          selected: c.code == _listCountry?.code,
                          onTap: () => Navigator.pop(dialogContext, c),
                        );
                      },
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
    if (picked == null || !mounted) return;

    final isMine = picked.code.isEmpty || picked.code == _country?.code;
    setState(() {
      _browseCountry = isMine ? null : picked;
      _sort = isMine ? StationSort.nearby : StationSort.popular;
      _remoteStations = [];
      _cacheTime = null;
      _stationsError = null;
    });
    await _refreshStations(fetch: !_isOffline);
  }

  void _showClusterSheet(StationCluster cluster, {String? focusUuid}) {
    var scrolled = false;
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (sheetContext) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: cluster.stations.length > 6 ? 0.6 : 0.4,
        minChildSize: 0.25,
        maxChildSize: 0.9,
        builder: (context, scrollController) => AnimatedBuilder(
          animation: GlobalAudioState.instance,
          builder: (context, _) {
            final theme = Theme.of(context);
            final audio = GlobalAudioState.instance;
            final place = cluster.placeName;
            return Column(
              children: [
                ListTile(
                  leading: Text(flagEmoji(cluster.countryCode), style: const TextStyle(fontSize: 26)),
                  title: Text(
                    place.isNotEmpty ? place : 'Posturi în zonă',
                    style: const TextStyle(fontWeight: FontWeight.bold),
                  ),
                  subtitle: Text('${cluster.stations.length} posturi'),
                  trailing: TextButton.icon(
                    icon: const Icon(Icons.zoom_in),
                    label: const Text('Zoom'),
                    onPressed: () {
                      Navigator.pop(sheetContext);
                      _mapController.move(LatLng(cluster.lat, cluster.lon), min(_mapController.camera.zoom + 3, 16));
                    },
                  ),
                ),
                const Divider(height: 1),
                Expanded(
                  child: Builder(builder: (context) {
                    // Derulăm o dată până la postul care rulează.
                    final focusIndex = focusUuid == null ? -1 : cluster.stations.indexWhere((s) => s.uuid == focusUuid);
                    if (!scrolled && focusIndex > 2) {
                      scrolled = true;
                      WidgetsBinding.instance.addPostFrameCallback((_) {
                        if (scrollController.hasClients) {
                          scrollController.jumpTo(min((focusIndex - 1) * 72.0, scrollController.position.maxScrollExtent));
                        }
                      });
                    }
                    return ListView.builder(
                    controller: scrollController,
                    itemCount: cluster.stations.length,
                    itemBuilder: (context, i) {
                      final s = cluster.stations[i];
                      final isPlaying = audio.currentRadio?.uuid == s.uuid;
                      return ListTile(
                        selected: isPlaying,
                        selectedTileColor: theme.colorScheme.primary.withValues(alpha: 0.12),
                        leading: _StationLogo(station: s, size: 40),
                        title: Text(
                          s.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontWeight: isPlaying ? FontWeight.bold : FontWeight.normal,
                            color: isPlaying ? theme.colorScheme.primary : null,
                          ),
                        ),
                        subtitle: Text(_stationDetails(s), maxLines: 1, overflow: TextOverflow.ellipsis),
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            FavoriteButton(station: s),
                            isPlaying
                                ? Icon(audio.isPlaying ? Icons.graphic_eq : Icons.play_arrow, color: theme.colorScheme.primary)
                                : const Icon(Icons.play_arrow),
                          ],
                        ),
                        onTap: () => isPlaying ? audio.togglePlayPause() : _play(s, fromCluster: cluster),
                      );
                    },
                  );
                  }),
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  Future<void> _confirmRemoveManual(RadioStation station) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Șterge postul?'),
        content: Text('"${station.name}" va fi eliminat din posturile adăugate manual.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialogContext, false), child: const Text('Anulează')),
          ElevatedButton(onPressed: () => Navigator.pop(dialogContext, true), child: const Text('Șterge')),
        ],
      ),
    );
    if (ok != true) return;
    await _repo.removeManualStation(station.uuid);
    final manual = await _repo.loadManualStations();
    if (mounted) setState(() => _manualStations = manual);
    _rebuildMapStations();
  }

  // ── Hartă offline ───────────────────────────────────────────────────────────

  Future<void> _prefetchVisibleArea() async {
    if (_isOffline) {
      _showSnack('Ai nevoie de internet pentru a salva harta.');
      return;
    }
    if (!_mapReady) return;

    final camera = _mapController.camera;
    final bounds = camera.visibleBounds;
    final z = camera.zoom.floor();
    final minZoom = max(4, z - 3);
    final maxZoom = min(_kPrefetchMaxZoom, z + 2);
    if (minZoom > maxZoom) {
      _showSnack('Micșorează harta (zoom ≤ $_kPrefetchMaxZoom) pentru a salva zona.');
      return;
    }

    final count = countTilesInArea(
      south: bounds.south,
      west: bounds.west,
      north: bounds.north,
      east: bounds.east,
      minZoom: minZoom,
      maxZoom: maxZoom,
    );
    if (count > _kPrefetchMaxTiles) {
      _showSnack('Zona e prea mare ($count bucăți). Mărește harta pe o zonă mai mică.');
      return;
    }

    final ok = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Salvează harta zonei'),
        content: Text(
          'Se descarcă zona vizibilă (zoom $minZoom–$maxZoom): $count bucăți, '
          'aproximativ ${(count * 25 / 1024).toStringAsFixed(1)} MB. '
          'Harta va funcționa apoi și fără internet.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialogContext, false), child: const Text('Anulează')),
          ElevatedButton(onPressed: () => Navigator.pop(dialogContext, true), child: const Text('Descarcă')),
        ],
      ),
    );
    if (ok != true || !mounted) return;

    setState(() {
      _prefetching = true;
      _prefetchCancelled = false;
      _prefetchDone = 0;
      _prefetchTotal = count;
    });
    try {
      final saved = await prefetchTileArea(
        south: bounds.south,
        west: bounds.west,
        north: bounds.north,
        east: bounds.east,
        minZoom: minZoom,
        maxZoom: maxZoom,
        isCancelled: () => _prefetchCancelled,
        onProgress: (done, total) {
          if (mounted) setState(() => _prefetchDone = done);
        },
      );
      _showSnack(_prefetchCancelled ? 'Salvare oprită.' : 'Hartă salvată offline ($saved bucăți noi).');
    } finally {
      if (mounted) setState(() => _prefetching = false);
    }
  }

  // ── Recunoaștere melodii ────────────────────────────────────────────────────

  _RecognitionSource _effectiveSource(RadioStation? radio) {
    final streamAvailable = radio != null && !radio.isHls;
    if (_sourceChoice == _RecognitionSource.stream && streamAvailable) return _RecognitionSource.stream;
    if (_sourceChoice == _RecognitionSource.microphone) return _RecognitionSource.microphone;
    return streamAvailable ? _RecognitionSource.stream : _RecognitionSource.microphone;
  }

  Future<String?> _askForToken({bool force = false}) async {
    final existing = await SongRecognizer.getToken();
    if (existing != null && !force) return existing;
    if (!mounted) return null;

    final controller = TextEditingController(text: existing ?? '');
    final token = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Conectare recunoaștere melodii'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Shazam nu permite conectarea contului tău în alte aplicații (nu are API public). '
                'Recunoașterea folosește AudD — aceeași tehnologie de amprentă audio.\n\n'
                'Creează-ți un cont pe dashboard.audd.io, copiază tokenul API și lipește-l mai jos. '
                'Se cere o singură dată.',
              ),
              const SizedBox(height: 12),
              TextField(
                controller: controller,
                autofocus: true,
                decoration: const InputDecoration(labelText: 'Token API', border: OutlineInputBorder()),
              ),
              TextButton.icon(
                icon: const Icon(Icons.open_in_new, size: 16),
                label: const Text('Deschide dashboard.audd.io'),
                onPressed: () => launchUrl(Uri.parse(kRecognitionDashboardUrl), mode: LaunchMode.externalApplication),
              ),
            ],
          ),
        ),
        actions: [
          if (existing != null)
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, ''),
              child: const Text('Deconectează', style: TextStyle(color: Colors.redAccent)),
            ),
          TextButton(onPressed: () => Navigator.pop(dialogContext), child: const Text('Anulează')),
          ElevatedButton(
            onPressed: () => Navigator.pop(dialogContext, controller.text.trim()),
            child: const Text('Salvează'),
          ),
        ],
      ),
    );
    if (token == null) return existing;
    await SongRecognizer.setToken(token);
    return token.isEmpty ? null : token;
  }

  Future<void> _recognize() async {
    if (_recState != _RecognitionState.idle) return;
    if (_isOffline) {
      setState(() => _recError = 'Recunoașterea are nevoie de internet.');
      return;
    }
    final token = await _askForToken();
    if (token == null || !mounted) return;

    final audio = GlobalAudioState.instance;
    final radio = audio.currentRadio;
    final source = _effectiveSource(radio);

    setState(() {
      _recState = _RecognitionState.listening;
      _recError = null;
      _lastNotFound = false;
    });

    try {
      final File sample = source == _RecognitionSource.stream
          ? await _recognizer.captureStream(radio!.streamUrl)
          : await _recognizer.recordMicrophone(const Duration(seconds: 10));

      if (!mounted) return;
      setState(() => _recState = _RecognitionState.searching);

      final song = await _recognizer.recognize(sample, token: token, stationName: radio?.name);
      if (song == null) {
        if (mounted) setState(() => _lastNotFound = true);
        return;
      }
      await SongRecognizer.addToHistory(song);
      final history = await SongRecognizer.loadHistory();
      if (mounted) {
        setState(() {
          _lastResult = song;
          _history = history;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _recError = e.toString());
    } finally {
      if (mounted) setState(() => _recState = _RecognitionState.idle);
    }
  }

  Future<void> _openUrl(String url) async {
    if (url.isEmpty) return;
    await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
  }

  // ── UI ──────────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
        appBar: AppBar(
          title: const Text('Radio & Shazam'),
          actions: [
            IconButton(
              icon: _loadingStations
                  ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.refresh),
              tooltip: 'Actualizează posturile',
              onPressed: _loadingStations ? null : () => _refreshStations(force: true),
            ),
            PopupMenuButton<String>(
              onSelected: (action) {
                switch (action) {
                  case 'add':
                    _showAddStationDialog();
                  case 'map':
                    _prefetchVisibleArea();
                  case 'account':
                    _askForToken(force: true);
                  case 'world':
                    _downloadWorld();
                }
              },
              itemBuilder: (_) => const [
                PopupMenuItem(value: 'add', child: ListTile(leading: Icon(Icons.add), title: Text('Adaugă post (din site)'))),
                PopupMenuItem(
                  value: 'map',
                  child: ListTile(leading: Icon(Icons.download_for_offline), title: Text('Salvează harta zonei')),
                ),
                PopupMenuItem(
                  value: 'world',
                  child: ListTile(leading: Icon(Icons.public), title: Text('Actualizează posturile lumii')),
                ),
                PopupMenuItem(
                  value: 'account',
                  child: ListTile(leading: Icon(Icons.key), title: Text('Cont recunoaștere melodii')),
                ),
              ],
            ),
          ],
          bottom: TabBar(
            controller: _tabs,
            tabs: const [
              Tab(icon: Icon(Icons.map), text: 'Hartă'),
              Tab(icon: Icon(Icons.list), text: 'Posturi'),
              Tab(icon: Icon(Icons.favorite), text: 'Favorite'),
              Tab(icon: Icon(Icons.graphic_eq), text: 'Shazam'),
            ],
          ),
        ),
        body: Column(
          children: [
            _buildLocationBar(),
            Expanded(
              child: TabBarView(
                controller: _tabs,
                physics: const NeverScrollableScrollPhysics(), // gesturile merg la hartă
                children: [
                  _KeepAlive(child: _buildMapTab()),
                  _buildListTab(),
                  _buildFavoritesTab(),
                  _buildShazamTab(),
                ],
              ),
            ),
            const PersistentBottomMiniPlayer(),
          ],
        ),
    );
  }

  Widget _buildFavoritesTab() {
    return AnimatedBuilder(
      animation: Listenable.merge([RadioFavorites.instance, GlobalAudioState.instance]),
      builder: (context, _) {
        final theme = Theme.of(context);
        final audio = GlobalAudioState.instance;
        final favorites = RadioFavorites.instance.stations;
        if (favorites.isEmpty) {
          return Center(
            child: Padding(
              padding: const EdgeInsets.all(32),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.favorite_border, size: 56, color: theme.colorScheme.onSurfaceVariant),
                  const SizedBox(height: 12),
                  const Text(
                    'Apasă ♥ pe orice post (pe hartă, în listă sau în mini-player) ca să-l adaugi aici.',
                    textAlign: TextAlign.center,
                  ),
                ],
              ),
            ),
          );
        }
        return ReorderableListView.builder(
          padding: const EdgeInsets.symmetric(vertical: 8),
          buildDefaultDragHandles: false,
          itemCount: favorites.length,
          onReorder: (oldIndex, newIndex) =>
              RadioFavorites.instance.reorder(oldIndex, newIndex > oldIndex ? newIndex - 1 : newIndex),
          itemBuilder: (context, i) {
            final s = favorites[i];
            final isPlaying = audio.currentRadio?.uuid == s.uuid;
            return ListTile(
              key: ValueKey(s.uuid),
              selected: isPlaying,
              selectedTileColor: theme.colorScheme.primary.withValues(alpha: 0.12),
              leading: _StationLogo(station: s, size: 44),
              title: Text(s.name, maxLines: 1, overflow: TextOverflow.ellipsis),
              subtitle: Text(
                [if (s.countryCode.isNotEmpty) flagEmoji(s.countryCode), _stationDetails(s)].join(' '),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  FavoriteButton(station: s),
                  ReorderableDragStartListener(index: i, child: const Icon(Icons.drag_handle)),
                ],
              ),
              onTap: () => isPlaying ? audio.togglePlayPause() : _play(s),
            );
          },
        );
      },
    );
  }

  Widget _buildLocationBar() {
    final theme = Theme.of(context);
    final locationBlocked = _locationServiceOff || _permissionDenied;

    String status;
    if (_locationServiceOff) {
      status = _lat != null
          ? 'Locația telefonului e oprită — se folosește ultima poziție cunoscută'
          : 'Locația telefonului e oprită';
    } else if (_permissionDenied) {
      status = 'Aplicația nu are voie să folosească locația';
    } else if (_locating && _lat == null) {
      status = 'Se caută poziția GPS...';
    } else if (_locationError != null) {
      status = _lat != null ? 'Ultima poziție cunoscută • $_locationError' : _locationError!;
    } else if (_hasLiveFix) {
      status = 'Poziție GPS curentă';
    } else if (_lat != null) {
      status = 'Ultima poziție cunoscută';
    } else {
      status = 'Poziție necunoscută';
    }

    final cacheInfo = _isOffline && !locationBlocked
        ? (_cacheTime != null ? 'OFFLINE • posturi salvate ${_formatDate(_cacheTime!)}' : 'OFFLINE • nu există posturi salvate')
        : null;

    return Material(
      color: locationBlocked ? Colors.orange.withValues(alpha: 0.18) : theme.colorScheme.surface,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
        child: Row(
          children: [
            locationBlocked
                ? const Icon(Icons.location_off, color: Colors.orange, size: 28)
                : Text(_country?.flag ?? '🌍', style: const TextStyle(fontSize: 26)),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    _country?.name ?? 'Țară necunoscută',
                    style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15),
                  ),
                  Text(
                    cacheInfo ?? status,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 11,
                      color: locationBlocked || _isOffline ? Colors.orange : theme.colorScheme.onSurfaceVariant,
                      fontWeight: locationBlocked ? FontWeight.bold : FontWeight.normal,
                    ),
                  ),
                ],
              ),
            ),
            if (locationBlocked)
              FilledButton.icon(
                style: FilledButton.styleFrom(backgroundColor: Colors.orange, foregroundColor: Colors.black),
                icon: const Icon(Icons.location_on, size: 18),
                label: const Text('Pornește'),
                onPressed: _permissionDenied ? Geolocator.openAppSettings : Geolocator.openLocationSettings,
              )
            else
              IconButton(
                icon: _locating
                    ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.my_location),
                tooltip: 'Actualizează poziția',
                onPressed: _locating ? null : _locate,
              ),
          ],
        ),
      ),
    );
  }

  String _formatDate(DateTime d) =>
      '${d.day.toString().padLeft(2, '0')}.${d.month.toString().padLeft(2, '0')} ${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';

  Widget _buildMapTab() {
    final theme = Theme.of(context);
    final audio = Provider.of<GlobalAudioState>(context);
    final playingUuid = audio.currentRadio?.uuid;

    return Stack(
      children: [
        FlutterMap(
          mapController: _mapController,
          options: MapOptions(
            initialCenter: _lat != null ? LatLng(_lat!, _lon!) : _kDefaultCenter,
            initialZoom: _lat != null ? 9 : 6,
            minZoom: 2,
            maxZoom: 18,
            // Fără rotire: la pinch-zoom harta se rotea și nordul nu mai era sus.
            interactionOptions: const InteractionOptions(
              flags: InteractiveFlag.all & ~InteractiveFlag.rotate,
            ),
            onMapReady: () {
              _mapReady = true;
              _centeredOnUser = _lat != null; // creată deja centrată pe poziție
              _recluster();
              if (_focusPending) {
                _centeredOnUser = true;
                _focusPlayingStation();
              }
            },
            onPositionChanged: (camera, hasGesture) {
              _scheduleRecluster();
              _scheduleCountryLoad();
            },
          ),
          children: [
            TileLayer(
              urlTemplate: kTerrainTileUrl,
              tileProvider: _tileProvider,
              maxNativeZoom: kTerrainMaxNativeZoom,
              userAgentPackageName: 'com.example.musicsync_app',
            ),
            MarkerLayer(
              markers: [
                for (final cluster in _clusters) _clusterMarker(cluster, playingUuid, theme),
                if (_showUserPosition)
                  Marker(
                    point: LatLng(_lat!, _lon!),
                    width: 22,
                    height: 22,
                    child: Container(
                      decoration: BoxDecoration(
                        color: Colors.blueAccent,
                        shape: BoxShape.circle,
                        border: Border.all(color: Colors.white, width: 3),
                        boxShadow: const [BoxShadow(color: Colors.black45, blurRadius: 6)],
                      ),
                    ),
                  ),
              ],
            ),
            const SimpleAttributionWidget(
              source: Text('OpenStreetMap, SRTM | OpenTopoMap | Radio Browser | GeoNames'),
            ),
          ],
        ),
        Positioned(
          right: 12,
          bottom: 36,
          child: Column(
            children: [
              FloatingActionButton.small(
                heroTag: 'radio_world',
                tooltip: 'Toată lumea',
                onPressed: () => _mapController.move(const LatLng(30, 15), 2.5),
                child: const Icon(Icons.public),
              ),
              const SizedBox(height: 8),
              FloatingActionButton.small(
                heroTag: 'radio_save_map',
                tooltip: 'Salvează harta zonei offline',
                onPressed: _prefetching ? null : _prefetchVisibleArea,
                child: const Icon(Icons.download_for_offline),
              ),
              const SizedBox(height: 8),
              FloatingActionButton.small(
                heroTag: 'radio_my_location',
                tooltip: 'Poziția mea',
                onPressed: _goToMyLocation,
                child: const Icon(Icons.my_location),
              ),
            ],
          ),
        ),
        Positioned(
          left: 12,
          right: 12,
          top: 12,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (_prefetching)
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Row(
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text('Salvare hartă offline: $_prefetchDone / $_prefetchTotal'),
                              const SizedBox(height: 6),
                              LinearProgressIndicator(value: _prefetchTotal == 0 ? null : _prefetchDone / _prefetchTotal),
                            ],
                          ),
                        ),
                        IconButton(
                          icon: const Icon(Icons.close),
                          onPressed: () => setState(() => _prefetchCancelled = true),
                        ),
                      ],
                    ),
                  ),
                ),
              _buildWorldStatusChip(),
            ],
          ),
        ),
      ],
    );
  }

  Marker _clusterMarker(StationCluster cluster, String? playingUuid, ThemeData theme) {
    final primary = theme.colorScheme.primary;
    final hasPlaying = playingUuid != null && cluster.stations.any((s) => s.uuid == playingUuid);

    if (cluster.stations.length == 1) {
      final s = cluster.stations.first;
      return Marker(
        point: LatLng(cluster.lat, cluster.lon),
        width: 34,
        height: 34,
        child: GestureDetector(
          onTap: () => _showStationSheet(s),
          child: Container(
            decoration: BoxDecoration(
              color: hasPlaying ? primary : Colors.white,
              shape: BoxShape.circle,
              border: Border.all(color: primary, width: 2),
              boxShadow: const [BoxShadow(color: Colors.black38, blurRadius: 4)],
            ),
            child: Icon(Icons.radio, size: 18, color: hasPlaying ? Colors.white : primary),
          ),
        ),
      );
    }

    // Punct de oraș ca în Radio Garden: mai mare cu cât are mai multe posturi.
    final count = cluster.stations.length;
    final size = 26.0 + min(26.0, log(count) * 7);
    return Marker(
      point: LatLng(cluster.lat, cluster.lon),
      width: size,
      height: size,
      child: GestureDetector(
        onTap: () => _showClusterSheet(cluster),
        child: Container(
          decoration: BoxDecoration(
            color: primary.withValues(alpha: 0.88),
            shape: BoxShape.circle,
            border: Border.all(color: hasPlaying ? Colors.white : Colors.white70, width: hasPlaying ? 3 : 1.5),
            boxShadow: [
              BoxShadow(color: hasPlaying ? primary : Colors.black38, blurRadius: hasPlaying ? 12 : 4),
            ],
          ),
          child: Center(
            child: Text(
              count > 999 ? '999+' : '$count',
              style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: size * 0.32),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildWorldStatusChip() {
    if (_countryLoading.isNotEmpty) {
      return Chip(
        avatar: const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
        label: Text('Se încarcă toate posturile din ${_countryLoading.map(flagEmoji).join(' ')}...'),
      );
    }
    if (_loadingWorld) {
      return const Chip(
        avatar: SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
        label: Text('Se încarcă posturile din toată lumea...'),
      );
    }
    if (_worldStations.isEmpty) {
      if (_isOffline) {
        return const Chip(avatar: Icon(Icons.cloud_off, size: 18), label: Text('Offline — doar posturile salvate'));
      }
      return ActionChip(
        avatar: const Icon(Icons.public, size: 18),
        label: Text(_worldError != null ? 'Eroare — reîncearcă descărcarea posturilor lumii' : 'Arată posturile din toată lumea (~17 MB)'),
        onPressed: _downloadWorld,
      );
    }
    return const SizedBox.shrink();
  }

  void _showStationSheet(RadioStation s) {
    showModalBottomSheet(
      context: context,
      builder: (sheetContext) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: _StationLogo(station: s, size: 48),
                title: Text(s.name, style: const TextStyle(fontWeight: FontWeight.bold)),
                subtitle: Text(_stationDetails(s)),
              ),
              if (s.tags.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Text('🏷 ${s.tags.split(',').take(6).join(', ')}', style: const TextStyle(fontSize: 12)),
                ),
              Row(
                children: [
                  Expanded(
                    child: ElevatedButton.icon(
                      icon: const Icon(Icons.play_arrow),
                      label: const Text('Ascultă'),
                      onPressed: () {
                        Navigator.pop(sheetContext);
                        _play(s);
                      },
                    ),
                  ),
                  const SizedBox(width: 4),
                  FavoriteButton(station: s, size: 28),
                  if (s.homepage.isNotEmpty) ...[
                    const SizedBox(width: 4),
                    OutlinedButton.icon(
                      icon: const Icon(Icons.public),
                      label: const Text('Site'),
                      onPressed: () => _openUrl(s.homepage),
                    ),
                  ],
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  String _stationDetails(RadioStation s) {
    final parts = <String>[];
    if (s.fmFrequency != null) parts.add(s.fmFrequency!);
    final km = s.distanceKmFrom(_lat, _lon);
    if (km != null) parts.add(km < 10 ? '${km.toStringAsFixed(1)} km' : '${km.round()} km');
    if (s.countryCode.isNotEmpty && s.countryCode != _country?.code) parts.add(flagEmoji(s.countryCode));
    if (s.precision == LocationPrecision.country) parts.add('național / online');
    if (s.precision == LocationPrecision.city && s.state.isNotEmpty) parts.add('📍 ${s.state}');
    if (s.isManual) {
      parts.add('adăugat manual');
    } else {
      parts.add('▶ ${s.clickCount}');
      parts.add('♥ ${s.votes}');
      if (s.clickTrend > 0) parts.add('↗ ${s.clickTrend}');
    }
    if (s.codec.isNotEmpty) parts.add(s.bitrate > 0 ? '${s.codec} ${s.bitrate}k' : s.codec);
    return parts.join(' • ');
  }

  Widget _buildListTab() {
    final theme = Theme.of(context);
    final audio = Provider.of<GlobalAudioState>(context);
    final playingUuid = audio.currentRadio?.uuid;

    final query = _filter.toLowerCase();
    final filtered = _allStations
        .where((s) => query.isEmpty || s.name.toLowerCase().contains(query) || s.tags.toLowerCase().contains(query))
        .toList();
    final sorted = sortStations(filtered, _sort, lat: _lat, lon: _lon);

    const sortLabels = {
      StationSort.nearby: 'Aproape',
      StationSort.popular: 'Populare',
      StationSort.votes: 'Voturi',
      StationSort.trending: 'Tendință',
    };

    final listCountry = _listCountry;

    return Column(
      children: [
        ListTile(
          dense: true,
          leading: Text(listCountry?.flag ?? '🌍', style: const TextStyle(fontSize: 24)),
          title: Text(
            listCountry?.name ?? 'Alege țara',
            style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15),
          ),
          subtitle: Text(
            _browseCountry == null ? 'Țara ta • atinge pentru altă țară' : 'Răsfoiești altă țară • atinge pentru a schimba',
          ),
          trailing: _browseCountry == null
              ? const Icon(Icons.arrow_drop_down)
              : IconButton(
                  icon: const Icon(Icons.my_location),
                  tooltip: 'Înapoi la țara mea',
                  onPressed: () async {
                    setState(() {
                      _browseCountry = null;
                      _sort = StationSort.nearby;
                    });
                    await _refreshStations(fetch: !_isOffline);
                  },
                ),
          onTap: _chooseCountry,
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 0, 12, 4),
          child: TextField(
            onChanged: (v) => setState(() => _filter = v),
            decoration: InputDecoration(
              hintText: 'Caută post sau gen...',
              prefixIcon: const Icon(Icons.search, size: 20),
              isDense: true,
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
            ),
          ),
        ),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Row(
            children: [
              for (final entry in sortLabels.entries)
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: ChoiceChip(
                    label: Text(entry.value),
                    selected: _sort == entry.key,
                    onSelected: (_) => setState(() => _sort = entry.key),
                  ),
                ),
            ],
          ),
        ),
        if (_stationsError != null)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            child: Text(
              'Nu am putut actualiza posturile: $_stationsError',
              style: const TextStyle(color: Colors.redAccent, fontSize: 12),
            ),
          ),
        if (_sort != StationSort.nearby)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
            child: Text(
              'Clasament după utilizatorii Radio Browser (nu audiențe oficiale).',
              style: TextStyle(fontSize: 11, color: theme.colorScheme.onSurfaceVariant),
            ),
          ),
        Expanded(
          child: sorted.isEmpty
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text(
                      _loadingStations
                          ? 'Se încarcă posturile...'
                          : (_isOffline
                              ? 'Niciun post salvat pentru zona asta. Deschide ecranul cu internet o dată ca să fie salvate.'
                              : 'Niciun post găsit.'),
                      textAlign: TextAlign.center,
                    ),
                  ),
                )
              : ListView.builder(
                  itemCount: sorted.length,
                  itemBuilder: (context, i) {
                    final s = sorted[i];
                    final isPlaying = s.uuid == playingUuid;
                    return ListTile(
                      leading: _StationLogo(station: s, size: 44),
                      title: Text(
                        s.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontWeight: isPlaying ? FontWeight.bold : FontWeight.normal,
                          color: isPlaying ? theme.colorScheme.primary : null,
                        ),
                      ),
                      subtitle: Text(_stationDetails(s), maxLines: 1, overflow: TextOverflow.ellipsis),
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          FavoriteButton(station: s),
                          isPlaying
                              ? Icon(audio.isPlaying ? Icons.graphic_eq : Icons.play_arrow, color: theme.colorScheme.primary)
                              : const Icon(Icons.play_arrow),
                        ],
                      ),
                      onTap: () => isPlaying ? audio.togglePlayPause() : _play(s),
                      onLongPress: () => s.isManual ? _confirmRemoveManual(s) : _showStationSheet(s),
                    );
                  },
                ),
        ),
      ],
    );
  }

  Widget _buildShazamTab() {
    final theme = Theme.of(context);
    final audio = Provider.of<GlobalAudioState>(context);
    final radio = audio.currentRadio;
    final source = _effectiveSource(radio);
    final streamAvailable = radio != null && !radio.isHls;
    final busy = _recState != _RecognitionState.idle;

    final statusText = switch (_recState) {
      _RecognitionState.listening =>
        source == _RecognitionSource.stream ? 'Ascult stream-ul radio...' : 'Ascult prin microfon (10 s)...',
      _RecognitionState.searching => 'Caut melodia...',
      _RecognitionState.idle => 'Atinge pentru a identifica melodia',
    };

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        if (radio != null && audio.radioNowPlaying != null)
          Card(
            child: ListTile(
              leading: const Icon(Icons.podcasts),
              title: Text(audio.radioNowPlaying!),
              subtitle: Text('Transmis acum de ${radio.name}'),
            ),
          ),
        const SizedBox(height: 12),
        Center(
          child: GestureDetector(
            onTap: busy ? null : _recognize,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 600),
              width: busy ? 170 : 150,
              height: busy ? 170 : 150,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: LinearGradient(
                  colors: [theme.colorScheme.primary, theme.colorScheme.primary.withValues(alpha: 0.6)],
                ),
                boxShadow: [
                  BoxShadow(
                    color: theme.colorScheme.primary.withValues(alpha: busy ? 0.7 : 0.4),
                    blurRadius: busy ? 40 : 20,
                    spreadRadius: busy ? 8 : 2,
                  ),
                ],
              ),
              child: busy
                  ? const Center(child: CircularProgressIndicator(color: Colors.white))
                  : const Icon(Icons.graphic_eq, size: 72, color: Colors.white),
            ),
          ),
        ),
        const SizedBox(height: 16),
        Center(child: Text(statusText, style: const TextStyle(fontWeight: FontWeight.bold))),
        const SizedBox(height: 12),
        Center(
          child: SegmentedButton<_RecognitionSource>(
            segments: [
              ButtonSegment(
                value: _RecognitionSource.stream,
                icon: const Icon(Icons.radio),
                label: const Text('Stream radio'),
                enabled: streamAvailable,
              ),
              const ButtonSegment(
                value: _RecognitionSource.microphone,
                icon: Icon(Icons.mic),
                label: Text('Microfon'),
              ),
            ],
            selected: {source},
            onSelectionChanged: busy ? null : (sel) => setState(() => _sourceChoice = sel.first),
          ),
        ),
        if (!streamAvailable)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(
              radio == null ? 'Pornește un post radio pentru recunoaștere direct din stream.' : 'Acest post (HLS) merge doar prin microfon.',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 11, color: theme.colorScheme.onSurfaceVariant),
            ),
          ),
        const SizedBox(height: 16),
        if (_recError != null)
          Card(
            color: Colors.red.withValues(alpha: 0.15),
            child: ListTile(
              leading: const Icon(Icons.error_outline, color: Colors.redAccent),
              title: Text(_recError!),
              trailing: TextButton(onPressed: () => _askForToken(force: true), child: const Text('Token')),
            ),
          ),
        if (_lastNotFound)
          const Card(
            child: ListTile(
              leading: Icon(Icons.help_outline),
              title: Text('Nu am recunoscut melodia'),
              subtitle: Text('Încearcă din nou în timpul unei melodii (nu în timpul reclamelor sau al vorbitului).'),
            ),
          ),
        if (_lastResult != null) _buildResultCard(_lastResult!, highlight: true),
        const SizedBox(height: 16),
        Row(
          children: [
            const Expanded(child: Text('Istoric', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16))),
            if (_history.isNotEmpty)
              TextButton.icon(
                icon: const Icon(Icons.delete_sweep, size: 18),
                label: const Text('Golește'),
                onPressed: () async {
                  await SongRecognizer.clearHistory();
                  if (mounted) setState(() => _history = []);
                },
              ),
          ],
        ),
        if (_history.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: Text('Melodiile recunoscute apar aici.', style: TextStyle(color: theme.colorScheme.onSurfaceVariant)),
          ),
        for (final song in _history) _buildResultCard(song),
      ],
    );
  }

  Widget _buildResultCard(RecognizedSong song, {bool highlight = false}) {
    final theme = Theme.of(context);
    final meta = [
      if (song.album.isNotEmpty) song.album,
      if (song.releaseDate.length >= 4) song.releaseDate.substring(0, 4),
      if (song.stationName != null) '📻 ${song.stationName}',
      _formatDate(song.recognizedAt),
    ].join(' • ');

    return Card(
      shape: highlight
          ? RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
              side: BorderSide(color: theme.colorScheme.primary, width: 2),
            )
          : null,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(4, 4, 4, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ListTile(
              leading: Icon(Icons.music_note, color: theme.colorScheme.primary),
              title: Text(song.title, style: const TextStyle(fontWeight: FontWeight.bold)),
              subtitle: Text('${song.artist}\n$meta'),
              isThreeLine: true,
            ),
            Wrap(
              spacing: 8,
              children: [
                const SizedBox(width: 8),
                if (song.songLink.isNotEmpty)
                  OutlinedButton.icon(
                    icon: const Icon(Icons.open_in_new, size: 16),
                    label: const Text('Deschide'),
                    onPressed: () => _openUrl(song.songLink),
                  ),
                OutlinedButton.icon(
                  icon: const Icon(Icons.smart_display, size: 16),
                  label: const Text('YouTube'),
                  onPressed: () => _openUrl(song.youtubeSearchUrl),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _StationLogo extends StatelessWidget {
  final RadioStation station;
  final double size;

  const _StationLogo({required this.station, required this.size});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final fallback = Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: theme.colorScheme.primary.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Center(
        child: station.fmFrequency != null
            ? Text(
                station.fmFrequency!.replaceAll(' FM', ''),
                style: TextStyle(fontSize: size * 0.26, fontWeight: FontWeight.bold, color: theme.colorScheme.primary),
              )
            : Icon(Icons.radio, color: theme.colorScheme.primary, size: size * 0.55),
      ),
    );

    if (!station.favicon.startsWith('http')) return fallback;
    return ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: Image(
        image: CachedNetworkImageProvider.logo(station.favicon),
        width: size,
        height: size,
        fit: BoxFit.cover,
        errorBuilder: (_, __, ___) => fallback,
      ),
    );
  }
}

/// Păstrează harta în viață când schimbi tab-ul (altfel s-ar reconstrui
/// de la zero și ar pierde poziția/zoom-ul).
class _KeepAlive extends StatefulWidget {
  final Widget child;
  const _KeepAlive({required this.child});

  @override
  State<_KeepAlive> createState() => _KeepAliveState();
}

class _KeepAliveState extends State<_KeepAlive> with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return widget.child;
  }
}
