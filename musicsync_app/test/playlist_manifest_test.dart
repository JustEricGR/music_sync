import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'package:musicsync_app/playlist_manifest.dart';

Future<File> _touch(Directory dir, String name, {DateTime? modified}) async {
  final file = File(p.join(dir.path, name));
  await file.writeAsString('x');
  if (modified != null) {
    await file.setLastModified(modified);
  }
  return file;
}

void main() {
  late Directory tempDir;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('playlist_manifest_test_');
  });

  tearDown(() {
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  group('legacy adoption / reconciliation', () {
    test('adopts existing files with sourceIndex -1, ordered by mtime', () async {
      final base = DateTime(2024, 1, 1);
      await _touch(tempDir, 'a.mp3', modified: base);
      await _touch(tempDir, 'b.mp3', modified: base.add(const Duration(minutes: 1)));
      await _touch(tempDir, 'c.mp3', modified: base.add(const Duration(minutes: 2)));

      final songs = await PlaylistManifest.getOrderedSongs(tempDir);

      expect(songs.map((s) => s.fileName).toList(), ['a.mp3', 'b.mp3', 'c.mp3']);
      expect(songs.every((s) => s.sourceIndex == -1), isTrue);
      expect(songs.every((s) => s.videoId.isEmpty), isTrue);
      expect(File(p.join(tempDir.path, '.musicsync_manifest.json')).existsSync(), isTrue);
    });

    test('prunes entries whose file was deleted externally', () async {
      await _touch(tempDir, 'a.mp3');
      await _touch(tempDir, 'b.mp3');
      await PlaylistManifest.getOrderedSongs(tempDir);

      File(p.join(tempDir.path, 'a.mp3')).deleteSync();

      final songs = await PlaylistManifest.getOrderedSongs(tempDir);
      expect(songs.map((s) => s.fileName).toList(), ['b.mp3']);
    });

    test('recovers from a corrupt manifest file instead of crashing', () async {
      await _touch(tempDir, 'a.mp3');
      final manifestFile = File(p.join(tempDir.path, '.musicsync_manifest.json'));
      await manifestFile.writeAsString('{not valid json');

      final songs = await PlaylistManifest.getOrderedSongs(tempDir);
      expect(songs.map((s) => s.fileName).toList(), ['a.mp3']);
    });
  });

  group('smart insert', () {
    test('cold start: first tracked download appends after an all-legacy library', () async {
      final base = DateTime(2024, 1, 1);
      await _touch(tempDir, 'legacy1.mp3', modified: base);
      await _touch(tempDir, 'legacy2.mp3', modified: base.add(const Duration(minutes: 1)));
      await _touch(tempDir, 'legacy3.mp3', modified: base.add(const Duration(minutes: 2)));

      await _touch(tempDir, 'new1.mp3');
      await PlaylistManifest.insertSong(
        tempDir,
        PlaylistSongEntry(videoId: 'v1', fileName: 'new1.mp3', title: 'New 1', sourceIndex: 0),
      );

      final songs = await PlaylistManifest.getOrderedSongs(tempDir);
      // Trebuie să aterizeze DUPĂ melodiile legacy, nu înaintea lor.
      expect(
        songs.map((s) => s.fileName).toList(),
        ['legacy1.mp3', 'legacy2.mp3', 'legacy3.mp3', 'new1.mp3'],
      );
    });

    test('inserts between two already-tracked neighbors by source order', () async {
      await _touch(tempDir, 's0.mp3');
      await PlaylistManifest.insertSong(
        tempDir,
        PlaylistSongEntry(videoId: 'v0', fileName: 's0.mp3', title: 'S0', sourceIndex: 0),
      );

      await _touch(tempDir, 's2.mp3');
      await PlaylistManifest.insertSong(
        tempDir,
        PlaylistSongEntry(videoId: 'v2', fileName: 's2.mp3', title: 'S2', sourceIndex: 2),
      );

      await _touch(tempDir, 's1.mp3');
      await PlaylistManifest.insertSong(
        tempDir,
        PlaylistSongEntry(videoId: 'v1', fileName: 's1.mp3', title: 'S1', sourceIndex: 1),
      );

      final songs = await PlaylistManifest.getOrderedSongs(tempDir);
      expect(songs.map((s) => s.fileName).toList(), ['s0.mp3', 's1.mp3', 's2.mp3']);
    });

    test('lands at the top when it is the earliest tracked song so far', () async {
      await _touch(tempDir, 's5.mp3');
      await PlaylistManifest.insertSong(
        tempDir,
        PlaylistSongEntry(videoId: 'v5', fileName: 's5.mp3', title: 'S5', sourceIndex: 5),
      );

      await _touch(tempDir, 's1.mp3');
      await PlaylistManifest.insertSong(
        tempDir,
        PlaylistSongEntry(videoId: 'v1', fileName: 's1.mp3', title: 'S1', sourceIndex: 1),
      );

      final songs = await PlaylistManifest.getOrderedSongs(tempDir);
      expect(songs.map((s) => s.fileName).toList(), ['s1.mp3', 's5.mp3']);
    });
  });

  group('reorder / remove', () {
    test('reorder moves an entry to the requested index', () async {
      await _touch(tempDir, 'a.mp3');
      await _touch(tempDir, 'b.mp3');
      await _touch(tempDir, 'c.mp3');
      await PlaylistManifest.getOrderedSongs(tempDir); // adoptă legacy în ordine mtime: a, b, c

      await PlaylistManifest.reorder(tempDir, 0, 2); // mută a.mp3 la final
      final songs = await PlaylistManifest.getOrderedSongs(tempDir);
      expect(songs.map((s) => s.fileName).toList(), ['b.mp3', 'c.mp3', 'a.mp3']);
    });

    test('removeByFileName drops just that entry', () async {
      await _touch(tempDir, 'a.mp3');
      await _touch(tempDir, 'b.mp3');
      await PlaylistManifest.getOrderedSongs(tempDir);

      // Ca în fluxul real (moveToRemovedSongs + removeByFileName): fișierul
      // chiar pleacă din folder, altfel reconcilierea l-ar readopta ca
      // "legacy" la următoarea citire — asta testează exact removeByFileName
      // ca operație de manifest, nu comportamentul de reconciliere.
      File(p.join(tempDir.path, 'a.mp3')).deleteSync();

      await PlaylistManifest.removeByFileName(tempDir, 'a.mp3');
      final songs = await PlaylistManifest.getOrderedSongs(tempDir);
      expect(songs.map((s) => s.fileName).toList(), ['b.mp3']);
    });
  });

  group('buildCrossPlaylistIndex', () {
    test('finds a tracked video in a sibling playlist folder, excludes the given folder', () async {
      final playlistA = Directory(p.join(tempDir.path, 'Playlist A'))..createSync();
      final playlistB = Directory(p.join(tempDir.path, 'Playlist B'))..createSync();

      await _touch(playlistA, 'song.mp3');
      await PlaylistManifest.insertSong(
        playlistA,
        PlaylistSongEntry(videoId: 'shared', fileName: 'song.mp3', title: 'Song', sourceIndex: 0),
      );

      final index = await PlaylistManifest.buildCrossPlaylistIndex(rootDir: tempDir, excludeFolder: playlistB);
      expect(index.containsKey('shared'), isTrue);
      expect(index['shared']!.playlistFolderName, 'Playlist A');

      final indexExcludingA = await PlaylistManifest.buildCrossPlaylistIndex(rootDir: tempDir, excludeFolder: playlistA);
      expect(indexExcludingA.containsKey('shared'), isFalse);
    });

    test('never treats the Removed Songs folder as a source playlist', () async {
      final removed = Directory(p.join(tempDir.path, kRemovedSongsFolderName))..createSync();
      final other = Directory(p.join(tempDir.path, 'Other'))..createSync();

      await _touch(removed, 'song.mp3');
      await PlaylistManifest.insertSong(
        removed,
        PlaylistSongEntry(videoId: 'removedvid', fileName: 'song.mp3', title: 'Song', sourceIndex: 0),
      );

      final index = await PlaylistManifest.buildCrossPlaylistIndex(rootDir: tempDir, excludeFolder: other);
      expect(index.containsKey('removedvid'), isFalse);
    });
  });

  group('moveToRemovedSongs', () {
    test('moves the file into <root>/Removed Songs', () async {
      final playlist = Directory(p.join(tempDir.path, 'My Playlist'))..createSync();
      final file = await _touch(playlist, 'song.mp3');

      final moved = await PlaylistManifest.moveToRemovedSongs(
        rootDir: tempDir,
        source: file,
        sourcePlaylistFolderName: 'My Playlist',
      );

      expect(moved.existsSync(), isTrue);
      expect(file.existsSync(), isFalse);
      expect(moved.path, contains(kRemovedSongsFolderName));
    });

    test('resolves a filename collision by prefixing the source playlist name', () async {
      final playlistA = Directory(p.join(tempDir.path, 'A'))..createSync();
      final playlistB = Directory(p.join(tempDir.path, 'B'))..createSync();
      final fileA = await _touch(playlistA, 'song.mp3');
      final fileB = await _touch(playlistB, 'song.mp3');

      final movedA = await PlaylistManifest.moveToRemovedSongs(rootDir: tempDir, source: fileA, sourcePlaylistFolderName: 'A');
      final movedB = await PlaylistManifest.moveToRemovedSongs(rootDir: tempDir, source: fileB, sourcePlaylistFolderName: 'B');

      expect(movedA.path, isNot(equals(movedB.path)));
      expect(movedA.existsSync(), isTrue);
      expect(movedB.existsSync(), isTrue);
    });
  });
}
