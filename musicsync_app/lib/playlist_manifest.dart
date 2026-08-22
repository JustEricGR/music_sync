import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

/// Numele folderului rădăcină în care ajung melodiile eliminate dintr-un
/// playlist (nu sunt șterse, doar mutate aici). Exclus din scanarea
/// bibliotecii locale — nu apare ca un playlist propriu-zis.
const String kRemovedSongsFolderName = 'Removed Songs';

const String _kManifestFileName = '.musicsync_manifest.json';

const List<String> _kAudioExtensions = ['.mp3', '.m4a', '.wav'];

/// O melodie urmărită în manifestul unui playlist local.
class PlaylistSongEntry {
  /// ID-ul video YouTube. Gol pentru intrări vechi/necunoscute (fișiere
  /// descoperite pe disc înainte să existe manifestul).
  final String videoId;

  /// Doar numele fișierului (fără cale), trebuie să existe în folderul
  /// playlistului.
  final String fileName;

  final String title;

  /// Poziția în playlistul YouTube sursă, la momentul descărcării.
  /// -1 = origine necunoscută (intrare veche, adăugată manual etc.).
  final int sourceIndex;

  const PlaylistSongEntry({
    required this.videoId,
    required this.fileName,
    required this.title,
    required this.sourceIndex,
  });

  Map<String, dynamic> toJson() => {
        'videoId': videoId,
        'fileName': fileName,
        'title': title,
        'sourceIndex': sourceIndex,
      };

  factory PlaylistSongEntry.fromJson(Map<String, dynamic> json) => PlaylistSongEntry(
        videoId: json['videoId'] as String? ?? '',
        fileName: json['fileName'] as String? ?? '',
        title: json['title'] as String? ?? '',
        sourceIndex: (json['sourceIndex'] as num?)?.toInt() ?? -1,
      );
}

/// O melodie găsită deja descărcată într-un ALT playlist (folosit pentru
/// a evita re-descărcarea aceluiași video).
class CrossPlaylistHit {
  final File file;
  final String playlistFolderName;
  const CrossPlaylistHit(this.file, this.playlistFolderName);
}

/// Manifest JSON per-playlist (`.musicsync_manifest.json`, ascuns, în chiar
/// folderul playlistului) care ține ordinea, ID-ul video și originea
/// fiecărei melodii — lucruri pe care simpla listare a folderului nu le
/// poate oferi.
///
/// Toate operațiile publice sunt atomice (citire -> mutație -> salvare
/// dintr-o singură bucată), serializate per folder printr-un mic mutex
/// async, ca să nu se piardă modificări dacă un sync de descărcare rulează
/// în paralel cu o editare din UI (reorder/remove) pe același playlist.
class PlaylistManifest {
  PlaylistManifest._();

  static final Map<String, Future<void>> _locks = {};

  static Future<T> _withLock<T>(String folderPath, Future<T> Function() action) async {
    final prior = _locks[folderPath] ?? Future<void>.value();
    final completer = Completer<void>();
    _locks[folderPath] = prior.then((_) => completer.future);
    await prior;
    try {
      return await action();
    } finally {
      completer.complete();
    }
  }

  static bool _isAudioFile(String path) {
    final lower = path.toLowerCase();
    return _kAudioExtensions.any((ext) => lower.endsWith(ext));
  }

  /// Citește manifestul (tolerează fișier lipsă sau JSON corupt -> listă
  /// goală), apoi îl reconciliază cu conținutul real al folderului: șterge
  /// intrările ale căror fișiere nu mai există, și adaugă la final (sortate
  /// după data modificării) orice fișier audio găsit pe disc dar absent din
  /// manifest, cu sourceIndex -1. Astfel bibliotecile existente adoptă
  /// manifestul automat, fără nicio migrare distructivă.
  static Future<List<PlaylistSongEntry>> _loadReconciled(Directory folder) async {
    final manifestFile = File(p.join(folder.path, _kManifestFileName));
    List<PlaylistSongEntry> songs = [];

    if (await manifestFile.exists()) {
      try {
        final raw = await manifestFile.readAsString();
        final decoded = jsonDecode(raw);
        if (decoded is List) {
          songs = decoded
              .whereType<Map>()
              .map((m) => PlaylistSongEntry.fromJson(Map<String, dynamic>.from(m)))
              .toList();
        }
      } catch (_) {
        songs = [];
      }
    }

    if (!await folder.exists()) {
      return songs;
    }

    final actualFiles = folder.listSync().whereType<File>().where((f) => _isAudioFile(f.path)).toList();

    final actualNames = actualFiles.map((f) => p.basename(f.path)).toSet();
    final knownNames = songs.map((s) => s.fileName).toSet();

    bool changed = false;

    final beforePrune = songs.length;
    songs.removeWhere((s) => !actualNames.contains(s.fileName));
    if (songs.length != beforePrune) changed = true;

    final missing = actualFiles.where((f) => !knownNames.contains(p.basename(f.path))).toList();
    if (missing.isNotEmpty) {
      missing.sort((a, b) => a.lastModifiedSync().compareTo(b.lastModifiedSync()));
      for (final f in missing) {
        final name = p.basename(f.path);
        songs.add(PlaylistSongEntry(
          videoId: '',
          fileName: name,
          title: p.basenameWithoutExtension(name),
          sourceIndex: -1,
        ));
      }
      changed = true;
    }

    if (changed) {
      await _save(folder, songs);
    }

    return songs;
  }

  static Future<void> _save(Directory folder, List<PlaylistSongEntry> songs) async {
    final manifestFile = File(p.join(folder.path, _kManifestFileName));
    final tmpFile = File('${manifestFile.path}.tmp');
    final jsonStr = jsonEncode(songs.map((s) => s.toJson()).toList());
    await tmpFile.writeAsString(jsonStr, flush: true);
    await tmpFile.rename(manifestFile.path);
  }

  /// Inserează `newEntry` la poziția care păstrează ordinea playlistului
  /// YouTube sursă printre melodiile deja urmărite (sourceIndex >= 0):
  /// - dacă nu există încă nicio intrare urmărită, se adaugă la final
  ///   (comportamentul actual la prima descărcare într-o bibliotecă veche —
  ///   altfel toate primele descărcări "urmărite" s-ar îngrămădi la început);
  /// - altfel, se plasează imediat după ultima intrare urmărită cu
  ///   sourceIndex mai mic (deci: între cei doi vecini deja descărcați,
  ///   la coadă dacă nu există vecin ulterior, sau la început dacă e cea
  ///   mai timpurie melodie urmărită până acum).
  static void _insertSmart(List<PlaylistSongEntry> songs, PlaylistSongEntry newEntry) {
    if (newEntry.sourceIndex < 0) {
      songs.add(newEntry);
      return;
    }

    bool hasAnyTracked = false;
    int idx = 0;
    for (int i = 0; i < songs.length; i++) {
      final s = songs[i].sourceIndex;
      if (s >= 0) {
        hasAnyTracked = true;
        if (s < newEntry.sourceIndex) idx = i + 1;
      }
    }
    songs.insert(hasAnyTracked ? idx : songs.length, newEntry);
  }

  /// Ordinea curentă (reconciliată) a melodiilor din playlist.
  static Future<List<PlaylistSongEntry>> getOrderedSongs(Directory folder) =>
      _withLock(folder.path, () => _loadReconciled(folder));

  /// Adaugă o melodie nou descărcată (sau copiată dintr-un alt playlist),
  /// plasată automat prin `_insertSmart`.
  static Future<void> insertSong(Directory folder, PlaylistSongEntry entry) =>
      _withLock(folder.path, () async {
        final songs = await _loadReconciled(folder);
        songs.removeWhere((s) => s.fileName == entry.fileName || (entry.videoId.isNotEmpty && s.videoId == entry.videoId));
        _insertSmart(songs, entry);
        await _save(folder, songs);
      });

  /// Elimină o intrare din manifest (fișierul trebuie mutat separat, vezi
  /// [moveToRemovedSongs]).
  static Future<List<PlaylistSongEntry>> removeByFileName(Directory folder, String fileName) =>
      _withLock(folder.path, () async {
        final songs = await _loadReconciled(folder);
        songs.removeWhere((s) => s.fileName == fileName);
        await _save(folder, songs);
        return songs;
      });

  /// Reordonare manuală (drag & drop) — index-urile sunt cele din lista
  /// afișată deja (adică din `getOrderedSongs`), fără ajustarea specifică
  /// `ReorderableListView` (aceea se face în UI înainte de a apela aici).
  static Future<List<PlaylistSongEntry>> reorder(Directory folder, int oldIndex, int newIndex) =>
      _withLock(folder.path, () async {
        final songs = await _loadReconciled(folder);
        if (oldIndex < 0 || oldIndex >= songs.length) return songs;
        final entry = songs.removeAt(oldIndex);
        final target = newIndex.clamp(0, songs.length);
        songs.insert(target, entry);
        await _save(folder, songs);
        return songs;
      });

  /// Scanează toate playlisturile-frate din `rootDir` (exceptând
  /// [excludeFolder] și folderul de melodii eliminate) și construiește o
  /// hartă videoId -> fișier deja descărcat, pentru a evita re-descărcarea.
  static Future<Map<String, CrossPlaylistHit>> buildCrossPlaylistIndex({
    required Directory rootDir,
    required Directory excludeFolder,
  }) async {
    final Map<String, CrossPlaylistHit> index = {};
    if (!await rootDir.exists()) return index;

    for (final entity in rootDir.listSync()) {
      if (entity is! Directory) continue;

      final folderName = p.basename(entity.path);
      if (folderName.toLowerCase() == kRemovedSongsFolderName.toLowerCase()) continue;
      if (p.equals(entity.path, excludeFolder.path)) continue;

      final songs = await getOrderedSongs(entity);
      for (final song in songs) {
        if (song.videoId.isEmpty) continue;
        if (index.containsKey(song.videoId)) continue;

        final file = File(p.join(entity.path, song.fileName));
        if (await file.exists()) {
          index[song.videoId] = CrossPlaylistHit(file, folderName);
        }
      }
    }

    return index;
  }

  /// Mută `source` în `<rootDir>/Removed Songs/` (o creează dacă lipsește),
  /// rezolvând coliziunile de nume prin prefixarea folderului sursă și,
  /// dacă tot există, un sufix numeric incremental.
  static Future<File> moveToRemovedSongs({
    required Directory rootDir,
    required File source,
    required String sourcePlaylistFolderName,
  }) async {
    final removedDir = Directory(p.join(rootDir.path, kRemovedSongsFolderName));
    if (!await removedDir.exists()) {
      await removedDir.create(recursive: true);
    }

    final ext = p.extension(source.path);
    final baseName = p.basenameWithoutExtension(source.path);

    Future<bool> isTaken(String name) => File(p.join(removedDir.path, name)).exists();

    String candidateName = '$baseName$ext';
    if (await isTaken(candidateName)) {
      candidateName = '$sourcePlaylistFolderName - $baseName$ext';
      int suffix = 1;
      while (await isTaken(candidateName)) {
        candidateName = '$sourcePlaylistFolderName - $baseName ($suffix)$ext';
        suffix++;
      }
    }

    final destPath = p.join(removedDir.path, candidateName);

    try {
      return await source.rename(destPath);
    } on FileSystemException {
      // rename() poate eșua peste sisteme de fișiere/puncte de montare
      // diferite (ex. cazuri de stocare Android) -> fallback copy+delete.
      final copied = await source.copy(destPath);
      await source.delete();
      return copied;
    }
  }
}
