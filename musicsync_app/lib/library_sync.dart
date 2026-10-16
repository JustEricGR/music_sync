import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:googleapis/youtube/v3.dart' as youtube;
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

import 'playlist_manifest.dart';

const String _kMetaFileName = '.musicsync_playlist.json';

/// Același format de nume ca la descărcare — numele folderului unui
/// playlist și al fiecărei melodii derivă din titlul YouTube prin asta.
String cleanFileName(String name) {
  return name.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_').trim();
}

String playlistTotalPrefsKey(String folderName) => 'playlist_total_$folderName';

/// Metadate per-playlist (`.musicsync_playlist.json`, ascuns, în folderul
/// playlistului): legătura cu playlistul YouTube (după ID, ca să
/// supraviețuiască redenumirilor).
class PlaylistMeta {
  final String? playlistId;
  final String? youtubeTitle;

  const PlaylistMeta({this.playlistId, this.youtubeTitle});

  PlaylistMeta copyWith({String? playlistId, String? youtubeTitle}) => PlaylistMeta(
        playlistId: playlistId ?? this.playlistId,
        youtubeTitle: youtubeTitle ?? this.youtubeTitle,
      );

  Map<String, dynamic> toJson() => {
        if (playlistId != null) 'playlistId': playlistId,
        if (youtubeTitle != null) 'youtubeTitle': youtubeTitle,
      };

  factory PlaylistMeta.fromJson(Map<String, dynamic> json) => PlaylistMeta(
        playlistId: json['playlistId'] as String?,
        youtubeTitle: json['youtubeTitle'] as String?,
      );
}

// ── Tema aleasă manual pentru un playlist ───────────────────────────────────

const String _kThemeOverridesKey = 'playlist_theme_overrides';

/// Tema aleasă manual e ținută în SharedPreferences, nu în folderul
/// playlistului — așa rămâne salvată și după ștergerea playlistului și
/// revine automat când e descărcat din nou. Cheile: ID-ul YouTube (stabil la
/// redenumiri) și numele folderului (pentru playlisturi nelegate de YouTube).
Future<List<String>> _themeOverrideKeys(Directory folder) async {
  final meta = await PlaylistMetaStore.read(folder);
  return [
    if (meta.playlistId != null) 'id:${meta.playlistId}',
    'name:${p.basename(folder.path)}',
  ];
}

Future<Map<String, String>> _readThemeOverrides(SharedPreferences prefs) async {
  final raw = prefs.getString(_kThemeOverridesKey);
  if (raw == null) return {};
  try {
    return Map<String, String>.from(jsonDecode(raw) as Map);
  } catch (_) {
    return {};
  }
}

Future<String?> loadThemeOverride(Directory folder) async {
  final prefs = await SharedPreferences.getInstance();
  final overrides = await _readThemeOverrides(prefs);
  for (final key in await _themeOverrideKeys(folder)) {
    final themeId = overrides[key];
    if (themeId != null) return themeId;
  }
  return null;
}

/// [themeId] null = înapoi la detecția automată.
Future<void> saveThemeOverride(Directory folder, String? themeId) async {
  final prefs = await SharedPreferences.getInstance();
  final overrides = await _readThemeOverrides(prefs);
  for (final key in await _themeOverrideKeys(folder)) {
    if (themeId == null) {
      overrides.remove(key);
    } else {
      overrides[key] = themeId;
    }
  }
  await prefs.setString(_kThemeOverridesKey, jsonEncode(overrides));
}

class PlaylistMetaStore {
  PlaylistMetaStore._();

  static Future<PlaylistMeta> read(Directory folder) async {
    final file = File(p.join(folder.path, _kMetaFileName));
    if (!await file.exists()) return const PlaylistMeta();
    try {
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is Map) return PlaylistMeta.fromJson(Map<String, dynamic>.from(decoded));
    } catch (_) {}
    return const PlaylistMeta();
  }

  static Future<void> write(Directory folder, PlaylistMeta meta) async {
    final file = File(p.join(folder.path, _kMetaFileName));
    final tmp = File('${file.path}.tmp');
    await tmp.writeAsString(jsonEncode(meta.toJson()), flush: true);
    await tmp.rename(file.path);
  }

  static Future<PlaylistMeta> update(Directory folder, PlaylistMeta Function(PlaylistMeta) change) async {
    final updated = change(await read(folder));
    await write(folder, updated);
    return updated;
  }
}

/// Apelat după ce un playlist local a fost schimbat pe disc din afara
/// ecranului de player (redenumit și/sau melodii eliminate de sync), ca
/// playerul global să-și reconstruiască sursa dacă acel playlist e cel
/// încărcat. Setat din main.dart.
typedef PlaylistChangedListener = Future<void> Function(String oldTitle, Directory newDir);

class LibraryEvents {
  LibraryEvents._();
  static PlaylistChangedListener? onPlaylistChanged;

  /// Playlistul a fost scos din bibliotecă (nu mai există pe YouTube).
  static Future<void> Function(String title)? onPlaylistRemoved;
}

/// Folderele de playlist din rădăcina bibliotecii (fără "Removed Songs").
List<Directory> listPlaylistFolders(Directory root) {
  if (!root.existsSync()) return [];
  return root
      .listSync()
      .whereType<Directory>()
      .where((d) => p.basename(d.path).toLowerCase() != kRemovedSongsFolderName.toLowerCase())
      .toList();
}

Future<Directory?> findFolderByPlaylistId(Directory root, String playlistId) async {
  for (final dir in listPlaylistFolders(root)) {
    final meta = await PlaylistMetaStore.read(dir);
    if (meta.playlistId == playlistId) return dir;
  }
  return null;
}

/// Redenumește folderul unui playlist și mută cheia din SharedPreferences.
/// Aruncă [FileSystemException] dacă există deja alt folder cu noul nume.
Future<Directory> renamePlaylistFolder(Directory folder, String newFolderName) async {
  final oldName = p.basename(folder.path);
  final target = Directory(p.join(folder.parent.path, newFolderName));
  if (await target.exists() && !p.equals(target.path, folder.path)) {
    throw FileSystemException('Există deja un folder cu numele "$newFolderName"', target.path);
  }

  final renamed = await folder.rename(target.path);

  final prefs = await SharedPreferences.getInstance();
  final total = prefs.getInt(playlistTotalPrefsKey(oldName));
  if (total != null) {
    await prefs.setInt(playlistTotalPrefsKey(newFolderName), total);
    await prefs.remove(playlistTotalPrefsKey(oldName));
  }
  return renamed;
}

/// Folderul în care se descarcă un playlist: dacă există deja un folder
/// legat de acest ID (chiar sub un nume vechi), e refolosit și redenumit la
/// titlul curent; altfel se folosește/creează `<root>/<titlu curățat>`.
Future<Directory> resolveDownloadFolder({
  required Directory root,
  required String playlistId,
  required String playlistTitle,
}) async {
  final safeTitle = cleanFileName(playlistTitle);
  Directory folder = Directory(p.join(root.path, safeTitle));

  final linked = await findFolderByPlaylistId(root, playlistId);
  if (linked != null) {
    folder = linked;
    final oldName = p.basename(linked.path);
    if (oldName != safeTitle) {
      try {
        folder = await renamePlaylistFolder(linked, safeTitle);
        await LibraryEvents.onPlaylistChanged?.call(oldName, folder);
      } catch (_) {
        // Conflict de nume / folder blocat — continuăm sub numele vechi.
      }
    }
  }

  if (!await folder.exists()) {
    await folder.create(recursive: true);
  }

  await PlaylistMetaStore.update(
    folder,
    (m) => m.copyWith(playlistId: playlistId, youtubeTitle: playlistTitle),
  );
  return folder;
}

/// Șterge definitiv un playlist local (folder + fișiere + numărul de piese
/// salvat). Tema aleasă pentru el NU se șterge — vezi [saveThemeOverride].
Future<void> deleteLocalPlaylist(Directory folder) async {
  final name = p.basename(folder.path);
  if (await folder.exists()) {
    await folder.delete(recursive: true);
  }
  final prefs = await SharedPreferences.getInstance();
  await prefs.remove(playlistTotalPrefsKey(name));
}

// ── Comparare local vs YouTube ──────────────────────────────────────────────

class RemoteSong {
  final String videoId;
  final String title;
  const RemoteSong(this.videoId, this.title);

  /// Video șters/privat — rămâne în playlist dar nu poate fi descărcat.
  bool get isUnavailable => videoId.isEmpty || title == 'Private video' || title == 'Deleted video';
}

/// Câte melodii din playlistul YouTube se pot descărca efectiv (fără cele
/// șterse/private) — numărul afișat ca "X / total".
int availableSongCount(List<RemoteSong> remote) => remote.where((r) => !r.isUnavailable).length;

class SongDiff {
  /// Intrări vechi (fără videoId) recunoscute după titlu: fișier -> videoId.
  final Map<String, String> backfill;

  /// Melodii care nu mai sunt în playlistul YouTube.
  final List<PlaylistSongEntry> removed;

  const SongDiff({required this.backfill, required this.removed});
}

const Set<String> _kTitleNoise = {
  'official', 'video', 'audio', 'lyrics', 'lyric', 'hd', 'hq', '4k', 'clip', 'videoclip', 'music', 'ft', 'feat',
  'the', 'and', 'oficial', 'original', 'version', 'visualizer', 'mv', 'live',
};

/// Cuvintele semnificative dintr-un titlu (fără diacritice/semne, fără
/// "Official Video" etc.) — pentru potrivirea fișierelor vechi cu YouTube.
Set<String> _titleTokens(String title) {
  final lower = title.toLowerCase();
  return lower
      .split(RegExp(r'[^\p{L}\p{N}]+', unicode: true))
      .where((t) => t.length >= 2 && !_kTitleNoise.contains(t))
      .toSet();
}

double _titleSimilarity(Set<String> a, Set<String> b) {
  if (a.isEmpty || b.isEmpty) return 0;
  final common = a.intersection(b).length;
  final jaccard = common / a.union(b).length;
  // Titlul fișierului poate fi o variantă scurtată a celui de pe YouTube.
  final containment = common / min(a.length, b.length);
  return max(jaccard, min(a.length, b.length) >= 3 ? containment * 0.9 : 0);
}

/// Decide ce melodii locale au fost scoase din playlistul YouTube.
/// Melodiile cu videoId: comparate direct. Cele vechi (descărcate înainte de
/// manifest, fără ID) sunt legate după titlu — exact, apoi aproximativ
/// (titlul video modificat ușor); cele care nu corespund niciunei melodii
/// din playlist sunt considerate scoase. Dacă lista de pe YouTube e goală
/// nu elimină nimic (protecție la răspunsuri incomplete ale API-ului).
SongDiff diffPlaylistSongs(List<PlaylistSongEntry> local, List<RemoteSong> remote) {
  final remoteIds = remote.map((r) => r.videoId).where((id) => id.isNotEmpty).toSet();
  if (remoteIds.isEmpty) return const SongDiff(backfill: {}, removed: []);

  // Melodii de pe YouTube încă nelegate de niciun fișier local.
  final claimed = local.map((e) => e.videoId).where((id) => id.isNotEmpty).toSet();
  final unclaimed = remote.where((r) => r.videoId.isNotEmpty && !claimed.contains(r.videoId)).toList();

  final backfill = <String, String>{};
  final removed = <PlaylistSongEntry>[];

  // 1. Fișierele vechi cu titlu identic (numele fișierului = titlul curățat).
  final legacy = <PlaylistSongEntry>[];
  for (final entry in local) {
    if (entry.videoId.isNotEmpty) {
      if (!remoteIds.contains(entry.videoId)) removed.add(entry);
      continue;
    }
    final base = p.basenameWithoutExtension(entry.fileName);
    final exact = unclaimed.where((r) => cleanFileName(r.title) == base).firstOrNull;
    if (exact != null) {
      backfill[entry.fileName] = exact.videoId;
      unclaimed.remove(exact);
    } else {
      legacy.add(entry);
    }
  }

  // 2. Potrivire aproximativă pentru restul, cea mai bună întâi.
  for (final entry in legacy) {
    final tokens = _titleTokens(p.basenameWithoutExtension(entry.fileName));
    RemoteSong? best;
    double bestScore = 0;
    for (final r in unclaimed) {
      final score = _titleSimilarity(tokens, _titleTokens(r.title));
      if (score > bestScore) {
        bestScore = score;
        best = r;
      }
    }
    if (best != null && bestScore >= 0.6) {
      backfill[entry.fileName] = best.videoId;
      unclaimed.remove(best);
    } else {
      removed.add(entry);
    }
  }

  return SongDiff(backfill: backfill, removed: removed);
}

/// Cât din melodiile unui folder local se regăsesc într-un playlist de pe
/// YouTube (0..1) — pentru a lega folderele vechi, fără ID, chiar dacă
/// playlistul a fost redenumit între timp.
double playlistContentMatch(List<PlaylistSongEntry> local, List<RemoteSong> remote) {
  if (local.isEmpty || remote.isEmpty) return 0;
  final ids = remote.map((r) => r.videoId).toSet();
  final titles = remote.map((r) => cleanFileName(r.title)).toSet();
  final matched = local.where((e) {
    if (e.videoId.isNotEmpty) return ids.contains(e.videoId);
    return titles.contains(p.basenameWithoutExtension(e.fileName));
  }).length;
  return matched / local.length;
}

/// Mută un playlist întreg (care nu mai există pe YouTube) în
/// `Removed Songs/Playlisturi șterse/` — dispare din bibliotecă, dar poate
/// fi recuperat.
Future<Directory> movePlaylistToRemoved(Directory root, Directory folder) async {
  final name = p.basename(folder.path);
  final target = Directory(p.join(root.path, kRemovedSongsFolderName, 'Playlisturi șterse'));
  await target.create(recursive: true);
  var dest = p.join(target.path, name);
  int suffix = 1;
  while (await Directory(dest).exists()) {
    dest = p.join(target.path, '$name ($suffix)');
    suffix++;
  }
  try {
    return await folder.rename(dest);
  } on FileSystemException {
    // Alt sistem de fișiere — copiem și ștergem.
    final copy = await Directory(dest).create(recursive: true);
    await for (final entity in folder.list()) {
      if (entity is File) await entity.copy(p.join(copy.path, p.basename(entity.path)));
    }
    await folder.delete(recursive: true);
    return copy;
  } finally {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(playlistTotalPrefsKey(name));
  }
}

// ── Sync complet al bibliotecii ─────────────────────────────────────────────

class LibrarySyncReport {
  final List<String> renamed = [];
  final List<String> removedSongs = [];
  final List<String> removedPlaylists = [];
  final List<String> reordered = [];
  final List<String> keptUnavailable = [];
  final List<String> unmatched = [];
  final List<String> errors = [];
  int checkedPlaylists = 0;
  bool cancelled = false;
}

/// Orice apel YouTube care durează mai mult e considerat blocat (rețea
/// căzută) — eroarea e raportată și sync-ul trece la următorul playlist.
const Duration _kApiTimeout = Duration(seconds: 30);

/// Rezultatul căutării unui playlist după ID.
enum _Lookup { found, gone, error }

class LibrarySyncService {
  final youtube.YouTubeApi api;
  bool _cancelled = false;
  final Map<String, List<RemoteSong>> _songsCache = {};

  /// Rezervă când API-ul oficial nu poate citi un playlist (ex. pagini
  /// repetate la nesfârșit): lista prin yt-dlp.
  final Future<List<RemoteSong>> Function(String playlistId)? fallbackLister;

  LibrarySyncService(this.api, {this.fallbackLister});

  /// Melodiile playlistului: API-ul YouTube, iar dacă acesta eșuează, yt-dlp.
  Future<List<RemoteSong>> _songsWithFallback(String playlistId, void Function(String) onLog) async {
    try {
      return await _fetchPlaylistSongs(playlistId, onLog: onLog);
    } catch (e) {
      final lister = fallbackLister;
      if (lister == null || _cancelled) rethrow;
      onLog('    API-ul YouTube nu poate citi lista complet — o citesc prin yt-dlp...');
      final songs = await lister(playlistId);
      _songsCache[playlistId] = songs;
      return songs;
    }
  }

  void cancel() => _cancelled = true;

  Future<Map<String, youtube.Playlist>> _fetchMyPlaylists() async {
    final result = <String, youtube.Playlist>{};
    String? pageToken;
    do {
      final res = await api.playlists.list(
        ['snippet', 'contentDetails'],
        mine: true,
        maxResults: 50,
        pageToken: pageToken,
      ).timeout(_kApiTimeout);
      for (final pl in res.items ?? <youtube.Playlist>[]) {
        if (pl.id != null) result[pl.id!] = pl;
      }
      pageToken = res.nextPageToken;
    } while (pageToken != null && !_cancelled);
    return result;
  }

  Future<(_Lookup, youtube.Playlist?)> _lookupPlaylist(String id) async {
    try {
      final res = await api.playlists.list(['snippet', 'contentDetails'], id: [id]).timeout(_kApiTimeout);
      final items = res.items ?? [];
      return items.isEmpty ? (_Lookup.gone, null) : (_Lookup.found, items.first);
    } on youtube.DetailedApiRequestError catch (e) {
      return e.status == 404 ? (_Lookup.gone, null) : (_Lookup.error, null);
    } catch (_) {
      return (_Lookup.error, null);
    }
  }

  Future<List<RemoteSong>> _fetchPlaylistSongs(String playlistId, {void Function(String)? onLog}) async {
    final cached = _songsCache[playlistId];
    if (cached != null) return cached;
    final songs = <RemoteSong>[];
    final seenTokens = <String>{};
    String? pageToken;
    int page = 0;
    do {
      page++;
      if (page > 1) onLog?.call('    pagina $page (${songs.length} melodii până acum)...');
      final res = await api.playlistItems.list(
        ['snippet'],
        playlistId: playlistId,
        maxResults: 50,
        pageToken: pageToken,
      ).timeout(_kApiTimeout);
      for (final item in res.items ?? <youtube.PlaylistItem>[]) {
        final id = item.snippet?.resourceId?.videoId ?? '';
        songs.add(RemoteSong(id, item.snippet?.title ?? ''));
      }
      pageToken = res.nextPageToken;
      // YouTube trimite uneori la nesfârșit același "pagina următoare".
      if (pageToken != null && !seenTokens.add(pageToken)) {
        throw StateError('YouTube a repetat aceeași pagină ($page) — lista nu poate fi citită complet');
      }
      if (page > 200) throw StateError('Playlist prea mare (peste 10.000 de melodii)');
    } while (pageToken != null && !_cancelled);
    if (!_cancelled) _songsCache[playlistId] = songs;
    return songs;
  }

  /// Care dintre aceste video-uri încă există (public/nelistat) pe YouTube.
  Future<Set<String>> _existingVideoIds(List<String> ids) async {
    final existing = <String>{};
    for (int i = 0; i < ids.length; i += 50) {
      final chunk = ids.sublist(i, min(i + 50, ids.length));
      final res = await api.videos.list(['id'], id: chunk, maxResults: 50).timeout(_kApiTimeout);
      for (final v in res.items ?? <youtube.Video>[]) {
        if (v.id != null) existing.add(v.id!);
      }
    }
    return existing;
  }

  /// Leagă un folder vechi (fără ID) de un playlist YouTube: după nume, iar
  /// dacă nu se potrivește (playlist redenumit), după conținut.
  Future<String?> _linkFolder(
    Directory dir,
    Map<String, youtube.Playlist> remote,
    Set<String> alreadyLinked,
    void Function(String) onLog,
  ) async {
    final name = p.basename(dir.path);
    String norm(String s) => s.toLowerCase().replaceAll(RegExp(r'[^\p{L}\p{N}]', unicode: true), '');
    final candidates = remote.values.where((pl) => pl.id != null && !alreadyLinked.contains(pl.id)).toList();

    final byName = candidates.where((pl) => cleanFileName(pl.snippet?.title ?? '') == name).toList();
    if (byName.length == 1) return byName.first.id;
    final byNorm = candidates.where((pl) => norm(pl.snippet?.title ?? '') == norm(name)).toList();
    if (byNorm.length == 1) return byNorm.first.id;

    final local = await PlaylistManifest.getOrderedSongs(dir);
    if (local.isEmpty) return null;
    onLog('    caut după conținut printre ${candidates.length} playlisturi...');
    String? bestId;
    double best = 0;
    for (final pl in candidates) {
      if (_cancelled) return null;
      List<RemoteSong> songs;
      try {
        songs = await _songsWithFallback(pl.id!, (_) {});
      } catch (_) {
        continue;
      }
      final score = playlistContentMatch(local, songs);
      if (score > best) {
        best = score;
        bestId = pl.id;
      }
    }
    return best >= 0.5 ? bestId : null;
  }

  /// Pentru fiecare playlist descărcat:
  /// - îl leagă de playlistul YouTube (ID; foldere vechi după nume/conținut);
  /// - dacă playlistul nu mai există pe YouTube, îl mută în "Removed Songs";
  /// - preia numele nou (redenumește folderul);
  /// - mută în "Removed Songs" melodiile scoase din playlist și duplicatele;
  /// - pune melodiile exact în ordinea de pe YouTube.
  Future<LibrarySyncReport> syncAll({
    required Directory root,
    required Set<String> customPlaylistIds,
    required void Function(String message) onLog,
    bool dryRun = false,
  }) async {
    _cancelled = false;
    final report = LibrarySyncReport();
    if (dryRun) onLog('PREVIZUALIZARE — nu se modifică nimic pe telefon.');
    final prefs = await SharedPreferences.getInstance();

    onLog('Preluare playlisturi de pe YouTube...');
    final remote = await _fetchMyPlaylists();
    for (final id in customPlaylistIds) {
      if (remote.containsKey(id)) continue;
      final (status, pl) = await _lookupPlaylist(id);
      if (status == _Lookup.found) remote[id] = pl!;
    }
    onLog('${remote.length} playlisturi găsite pe cont.');

    // ── Faza 1: legăm fiecare folder de playlistul lui ──────────────────────
    final folders = listPlaylistFolders(root);
    final linkedIds = <String>{};
    final folderIds = <Directory, String?>{};
    for (final dir in folders) {
      folderIds[dir] = (await PlaylistMetaStore.read(dir)).playlistId;
      if (folderIds[dir] != null) linkedIds.add(folderIds[dir]!);
    }

    final gone = <Directory>[];
    for (int i = 0; i < folders.length; i++) {
      if (_cancelled) break;
      final dir = folders[i];
      final name = p.basename(dir.path);
      var id = folderIds[dir];

      if (id == null) {
        onLog('[${i + 1}/${folders.length}] Leg "$name" de YouTube...');
        try {
          id = await _linkFolder(dir, remote, linkedIds, onLog);
        } catch (e) {
          report.errors.add('"$name": $e');
          onLog('[EROARE] "$name": $e');
          continue;
        }
        if (id == null) {
          gone.add(dir);
          continue;
        }
        folderIds[dir] = id;
        linkedIds.add(id);
        if (!dryRun) await PlaylistMetaStore.update(dir, (m) => m.copyWith(playlistId: id));
        onLog('[LINK] "$name" legat de playlistul YouTube "${remote[id]?.snippet?.title ?? id}".');
      } else if (!remote.containsKey(id)) {
        final (status, pl) = await _lookupPlaylist(id);
        if (status == _Lookup.found) {
          remote[id] = pl!;
        } else if (status == _Lookup.gone) {
          gone.add(dir);
        } else {
          report.errors.add('"$name": YouTube nu a răspuns');
        }
      }
    }

    // ── Faza 2: playlisturile care nu mai există pe YouTube ─────────────────
    // Protecție: dacă "dispar" majoritatea playlisturilor, probabil e alt
    // cont Google sau o problemă de API — nu ștergem nimic.
    if (gone.isNotEmpty && !_cancelled) {
      if (remote.isEmpty || gone.length > folders.length / 2) {
        for (final dir in gone) {
          report.unmatched.add(p.basename(dir.path));
        }
        onLog('[ATENȚIE] ${gone.length} din ${folders.length} playlisturi nu apar pe acest cont YouTube — '
            'ești conectat cu contul corect? Nu am șters niciun playlist.');
      } else {
        for (final dir in gone) {
          final name = p.basename(dir.path);
          try {
            if (!dryRun) await movePlaylistToRemoved(root, dir);
            report.removedPlaylists.add(name);
            onLog('[ȘTERS] "$name" nu mai există pe YouTube — mutat în "Removed Songs/Playlisturi șterse".');
            if (!dryRun) {
              await LibraryEvents.onPlaylistRemoved?.call(name).timeout(const Duration(seconds: 10), onTimeout: () {});
            }
          } catch (e) {
            report.errors.add('Mutare "$name": $e');
          }
        }
      }
    }

    // ── Faza 3: nume, melodii, ordine ───────────────────────────────────────
    final active = folders.where((d) => !gone.contains(d) && folderIds[d] != null && remote.containsKey(folderIds[d])).toList();
    for (int i = 0; i < active.length; i++) {
      if (_cancelled) {
        report.cancelled = true;
        break;
      }
      final folder = active[i];
      final playlistId = folderIds[folder]!;
      final playlist = remote[playlistId]!;
      final oldName = p.basename(folder.path);
      Directory dir = folder;
      onLog('[${i + 1}/${active.length}] Verific "$oldName"...');

      try {
        report.checkedPlaylists++;
        bool changed = false;

        final youtubeTitle = playlist.snippet?.title ?? oldName;
        final newName = cleanFileName(youtubeTitle);
        if (newName.isNotEmpty && newName != oldName) {
          try {
            if (!dryRun) dir = await renamePlaylistFolder(dir, newName);
            changed = true;
            report.renamed.add('$oldName → $newName');
            onLog('[RENAME] "$oldName" → "$newName"');
          } catch (e) {
            report.errors.add('Redenumire "$oldName": $e');
            onLog('[EROARE] Nu am putut redenumi "$oldName": $e');
          }
        }

        final remoteSongs = await _songsWithFallback(playlistId, onLog);
        if (_cancelled) {
          report.cancelled = true;
          break;
        }
        onLog('    ${remoteSongs.length} melodii pe YouTube.');

        final local = await PlaylistManifest.getOrderedSongs(dir);
        final diff = diffPlaylistSongs(local, remoteSongs);
        if (diff.backfill.isNotEmpty && !dryRun) {
          await PlaylistManifest.assignVideoIds(dir, diff.backfill);
        }
        onLog('    ${local.length} local • ${diff.backfill.length} vechi recunoscute • ${diff.removed.length} de scos');

        // YouTube ascunde complet videoclipurile devenite indisponibile (nici
        // API-ul, nici yt-dlp nu le întorc) — dar le numără. Dacă lipsesc
        // melodii din listă, nu putem ști dacă au fost scoase din playlist sau
        // doar ascunse, așa că le păstrăm pe telefon (nu mai pot fi redescărcate).
        final reportedCount = playlist.contentDetails?.itemCount ?? remoteSongs.length;
        final hiddenCount = reportedCount - remoteSongs.length;
        var toRemove = diff.removed;
        if (hiddenCount > 0 && diff.removed.isNotEmpty) {
          // Video-urile care încă există pe YouTube au fost clar scoase din
          // playlist -> le scoatem. Cele care nu mai există (șterse/private)
          // pot fi chiar cele ascunse și nu mai pot fi redescărcate -> le păstrăm.
          final existing = await _existingVideoIds(
            diff.removed.map((e) => e.videoId).where((id) => id.isNotEmpty).toList(),
          );
          toRemove = diff.removed.where((e) => existing.contains(e.videoId)).toList();
          final kept = diff.removed.length - toRemove.length;
          onLog('    YouTube ascunde $hiddenCount melodii indisponibile: scot ${toRemove.length} '
              '(încă există pe YouTube), păstrez $kept care nu mai există pe YouTube.');
          if (kept > 0) {
            report.keptUnavailable.add('${p.basename(dir.path)}: $kept melodii păstrate (nu mai există pe YouTube)');
          }
        }

        final folderName = p.basename(dir.path);
        Future<void> moveOut(PlaylistSongEntry entry, String why) async {
          if (!dryRun) {
            final file = File(p.join(dir.path, entry.fileName));
            if (await file.exists()) {
              await PlaylistManifest.moveToRemovedSongs(rootDir: root, source: file, sourcePlaylistFolderName: folderName);
            }
            await PlaylistManifest.removeByFileName(dir, entry.fileName);
          }
          changed = true;
          report.removedSongs.add('$folderName: ${entry.title}$why');
          onLog('[REMOVE] "${entry.title}"$why');
        }

        for (final entry in toRemove) {
          await moveOut(entry, '');
        }

        // Ordinea exactă de pe YouTube + eliminarea duplicatelor.
        final indexById = <String, int>{};
        for (int k = 0; k < remoteSongs.length; k++) {
          indexById.putIfAbsent(remoteSongs[k].videoId, () => k);
        }
        final order = await PlaylistManifest.applySourceOrder(dir, indexById, save: !dryRun);
        for (final dup in order.duplicates) {
          await moveOut(dup, ' (duplicat)');
        }
        if (order.orderChanged) {
          changed = true;
          report.reordered.add(folderName);
          onLog('[ORDINE] "$folderName" rearanjat ca pe YouTube.');
        }

        if (dryRun) continue;
        await prefs.setInt(playlistTotalPrefsKey(folderName), availableSongCount(remoteSongs));
        await PlaylistMetaStore.update(
          dir,
          (m) => m.copyWith(playlistId: playlistId, youtubeTitle: youtubeTitle),
        );

        if (changed) {
          // Actualizarea playerului nu are voie să blocheze sync-ul.
          await LibraryEvents.onPlaylistChanged
              ?.call(oldName, dir)
              .timeout(const Duration(seconds: 10), onTimeout: () {});
        } else {
          onLog('[OK] "$folderName" la zi.');
        }
      } catch (e) {
        report.errors.add('"$oldName": $e');
        onLog('[EROARE] "$oldName": $e');
      }
    }

    return report;
  }
}
