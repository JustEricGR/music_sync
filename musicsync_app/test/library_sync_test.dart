import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

import 'package:musicsync_app/library_sync.dart';
import 'package:musicsync_app/playlist_manifest.dart';

PlaylistSongEntry _entry(String fileName, {String videoId = ''}) =>
    PlaylistSongEntry(videoId: videoId, fileName: fileName, title: p.basenameWithoutExtension(fileName), sourceIndex: -1);

void main() {
  group('diffPlaylistSongs', () {
    test('removes tracked songs missing from YouTube, keeps the rest', () {
      final local = [_entry('A.m4a', videoId: 'a'), _entry('B.m4a', videoId: 'b'), _entry('C.m4a', videoId: 'c')];
      final remote = [const RemoteSong('a', 'A'), const RemoteSong('c', 'C')];

      final diff = diffPlaylistSongs(local, remote);
      expect(diff.removed.map((e) => e.fileName), ['B.m4a']);
      expect(diff.backfill, isEmpty);
    });

    test('legacy entries: matched by title, the rest were removed from YouTube', () {
      final local = [_entry('AC_DC - Song.m4a'), _entry('Removed long ago.mp3')];
      final remote = [const RemoteSong('x1', 'AC/DC - Song'), const RemoteSong('x2', 'Other')];

      final diff = diffPlaylistSongs(local, remote);
      expect(diff.backfill, {'AC_DC - Song.m4a': 'x1'});
      expect(diff.removed.map((e) => e.fileName), ['Removed long ago.mp3']);
    });

    test('legacy entry whose YouTube title changed slightly is kept (fuzzy match)', () {
      final local = [_entry('Tarkan - Şımarık (Official Video).m4a')];
      final remote = [const RemoteSong('t1', 'TARKAN - Şımarık [Official Music Video HD]')];
      final diff = diffPlaylistSongs(local, remote);
      expect(diff.backfill, {'Tarkan - Şımarık (Official Video).m4a': 't1'});
      expect(diff.removed, isEmpty);
    });

    test('a YouTube song is claimed by only one local file', () {
      final local = [_entry('Song A.m4a', videoId: 'a'), _entry('Song A (1).m4a')];
      final remote = [const RemoteSong('a', 'Song A')];
      // Al doilea fișier nu poate fi legat de "a" (e deja luat) -> scos.
      expect(diffPlaylistSongs(local, remote).removed.map((e) => e.fileName), ['Song A (1).m4a']);
    });

    test('availableSongCount ignores private and deleted videos', () {
      expect(
        availableSongCount(const [RemoteSong('a', 'A'), RemoteSong('b', 'Private video'), RemoteSong('c', 'Deleted video')]),
        1,
      );
    });

    test('playlistContentMatch links a renamed playlist by its songs', () {
      final local = [_entry('A.m4a', videoId: 'a'), _entry('B.m4a'), _entry('C.m4a')];
      final remote = [const RemoteSong('a', 'A'), const RemoteSong('b', 'B'), const RemoteSong('z', 'Z')];
      expect(playlistContentMatch(local, remote), closeTo(2 / 3, 0.001));
      expect(playlistContentMatch(local, const [RemoteSong('q', 'Q')]), 0);
    });

    test('empty YouTube list removes nothing', () {
      final local = [_entry('A.m4a', videoId: 'a')];
      expect(diffPlaylistSongs(local, []).removed, isEmpty);
    });

    test('private/deleted videos still in the playlist are kept', () {
      final local = [_entry('A.m4a', videoId: 'a')];
      final remote = [const RemoteSong('a', 'Private video')];
      expect(diffPlaylistSongs(local, remote).removed, isEmpty);
    });
  });

  group('folders and metadata', () {
    late Directory root;

    setUp(() {
      SharedPreferences.setMockInitialValues({});
      root = Directory.systemTemp.createTempSync('library_sync_test_');
    });

    tearDown(() {
      if (root.existsSync()) root.deleteSync(recursive: true);
    });

    test('meta round-trip', () async {
      final dir = Directory(p.join(root.path, 'PL'))..createSync();
      await PlaylistMetaStore.write(dir, const PlaylistMeta(playlistId: 'id1', youtubeTitle: 'T'));
      final meta = await PlaylistMetaStore.update(dir, (m) => m.copyWith(youtubeTitle: 'T2'));
      expect(meta.playlistId, 'id1');
      expect((await PlaylistMetaStore.read(dir)).youtubeTitle, 'T2');
    });

    test('theme override survives deleting the playlist and returns on re-download', () async {
      final dir = Directory(p.join(root.path, 'Turkish Mix'))..createSync();
      await PlaylistMetaStore.write(dir, const PlaylistMeta(playlistId: 'PL9'));
      await saveThemeOverride(dir, 'turcia');

      await deleteLocalPlaylist(dir);
      expect(dir.existsSync(), isFalse);

      // Redescărcat sub alt nume (redenumit pe YouTube) — regăsit după ID.
      final again = await resolveDownloadFolder(root: root, playlistId: 'PL9', playlistTitle: 'Türk Pop');
      expect(await loadThemeOverride(again), 'turcia');

      await saveThemeOverride(again, null);
      expect(await loadThemeOverride(again), isNull);
    });

    test('theme override for a playlist without YouTube id uses the folder name', () async {
      final dir = Directory(p.join(root.path, 'Local only'))..createSync();
      await saveThemeOverride(dir, 'armenia');
      await deleteLocalPlaylist(dir);
      final recreated = Directory(p.join(root.path, 'Local only'))..createSync();
      expect(await loadThemeOverride(recreated), 'armenia');
    });

    test('resolveDownloadFolder renames the folder linked to the playlist id', () async {
      final old = Directory(p.join(root.path, 'Old Name'))..createSync();
      File(p.join(old.path, 'song.m4a')).writeAsStringSync('x');
      await PlaylistMetaStore.write(old, const PlaylistMeta(playlistId: 'PL1'));
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(playlistTotalPrefsKey('Old Name'), 7);

      final changes = <String>[];
      LibraryEvents.onPlaylistChanged = (oldTitle, newDir) async => changes.add('$oldTitle->${p.basename(newDir.path)}');
      addTearDown(() => LibraryEvents.onPlaylistChanged = null);

      final folder = await resolveDownloadFolder(root: root, playlistId: 'PL1', playlistTitle: 'New: Name');

      expect(p.basename(folder.path), 'New_ Name');
      expect(File(p.join(folder.path, 'song.m4a')).existsSync(), isTrue);
      expect(old.existsSync(), isFalse);
      expect(prefs.getInt(playlistTotalPrefsKey('New_ Name')), 7);
      expect(prefs.getInt(playlistTotalPrefsKey('Old Name')), isNull);
      expect(changes, ['Old Name->New_ Name']);
      expect((await PlaylistMetaStore.read(folder)).youtubeTitle, 'New: Name');
    });

    test('rename refuses to overwrite another folder', () async {
      final a = Directory(p.join(root.path, 'A'))..createSync();
      Directory(p.join(root.path, 'B')).createSync();
      expect(() => renamePlaylistFolder(a, 'B'), throwsA(isA<FileSystemException>()));
    });

    test('listPlaylistFolders skips Removed Songs; delete removes folder', () async {
      Directory(p.join(root.path, kRemovedSongsFolderName)).createSync();
      final pl = Directory(p.join(root.path, 'Keep'))..createSync();
      expect(listPlaylistFolders(root).map((d) => p.basename(d.path)), ['Keep']);

      await deleteLocalPlaylist(pl);
      expect(pl.existsSync(), isFalse);
    });

    test('applySourceOrder puts songs in YouTube order and returns duplicates', () async {
      final dir = Directory(p.join(root.path, 'PL'))..createSync();
      File(p.join(dir.path, 's2.m4a')).writeAsStringSync('x');
      File(p.join(dir.path, 's1.m4a')).writeAsStringSync('x');
      await PlaylistManifest.insertSong(dir, _entry('s2.m4a', videoId: 'v2'));
      await PlaylistManifest.insertSong(dir, _entry('s1.m4a', videoId: 'v1'));
      // Descărcate mai târziu: o a doua copie a lui v1 și un fișier fără ID.
      File(p.join(dir.path, 'dup.m4a')).writeAsStringSync('x');
      File(p.join(dir.path, 'local.m4a')).writeAsStringSync('x');
      await PlaylistManifest.assignVideoIds(dir, {'dup.m4a': 'v1'});

      final result = await PlaylistManifest.applySourceOrder(dir, {'v1': 0, 'v2': 1});
      expect(result.orderChanged, isTrue);
      expect(result.duplicates.map((e) => e.fileName), ['dup.m4a']);

      final names = (await PlaylistManifest.getOrderedSongs(dir)).map((e) => e.fileName).toList();
      // YouTube: v1, v2; apoi melodia fără ID. Duplicatul încă e pe disc (îl
      // mută apelantul), deci reapare la final ca intrare veche.
      expect(names, ['s1.m4a', 's2.m4a', 'local.m4a', 'dup.m4a']);

      final again = await PlaylistManifest.applySourceOrder(dir, {'v1': 0, 'v2': 1});
      expect(again.orderChanged, isFalse);
    });

    test('movePlaylistToRemoved hides the playlist from the library', () async {
      final pl = Directory(p.join(root.path, 'Gone'))..createSync();
      File(p.join(pl.path, 'a.m4a')).writeAsStringSync('x');
      final moved = await movePlaylistToRemoved(root, pl);
      expect(pl.existsSync(), isFalse);
      expect(File(p.join(moved.path, 'a.m4a')).existsSync(), isTrue);
      expect(listPlaylistFolders(root), isEmpty);
    });

    test('assignVideoIds fills only missing ids', () async {
      final dir = Directory(p.join(root.path, 'PL'))..createSync();
      File(p.join(dir.path, 'a.m4a')).writeAsStringSync('x');
      File(p.join(dir.path, 'b.m4a')).writeAsStringSync('x');
      await PlaylistManifest.insertSong(dir, _entry('b.m4a', videoId: 'keep'));

      await PlaylistManifest.assignVideoIds(dir, {'a.m4a': 'new-a', 'b.m4a': 'ignored'});
      final byName = {for (final s in await PlaylistManifest.getOrderedSongs(dir)) s.fileName: s.videoId};
      expect(byName, {'a.m4a': 'new-a', 'b.m4a': 'keep'});
    });
  });
}
