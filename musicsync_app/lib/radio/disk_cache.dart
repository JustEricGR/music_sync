import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

const String kHttpUserAgent = 'MusicSync/1.0 (com.example.musicsync_app)';

/// Folder local (în datele aplicației) pentru tot ce ține de radio: harta,
/// logo-uri, lista de posturi — ca să poată fi răsfoite offline.
class DiskCache {
  DiskCache._();

  static String? _rootPath;

  static Future<void> init() async {
    if (_rootPath != null) return;
    final dir = await getApplicationSupportDirectory();
    _rootPath = p.join(dir.path, 'radio_cache');
    await Directory(_rootPath!).create(recursive: true);
  }

  static String get rootPath {
    final root = _rootPath;
    if (root == null) throw StateError('DiskCache.init() nu a fost apelat');
    return root;
  }

  static Directory get tilesDir => Directory(p.join(rootPath, 'tiles'));
  static Directory get logosDir => Directory(p.join(rootPath, 'logos'));

  static File logoFileFor(String url) {
    // Hash simplu și stabil (FNV-1a) — doar pentru nume de fișier.
    int hash = 0x811c9dc5;
    for (final b in utf8.encode(url)) {
      hash = ((hash ^ b) * 0x01000193) & 0xFFFFFFFF;
    }
    return File(p.join(logosDir.path, '${hash.toRadixString(16)}.img'));
  }

  /// Descarcă (dacă lipsește) și întoarce conținutul fișierului.
  static Future<Uint8List> fetchCached(String url, File cacheFile, {Map<String, String>? headers}) async {
    if (await cacheFile.exists()) {
      return cacheFile.readAsBytes();
    }
    final res = await http
        .get(Uri.parse(url), headers: {'User-Agent': kHttpUserAgent, ...?headers})
        .timeout(const Duration(seconds: 20));
    if (res.statusCode != 200 || res.bodyBytes.isEmpty) {
      throw HttpException('HTTP ${res.statusCode}', uri: Uri.parse(url));
    }
    await cacheFile.parent.create(recursive: true);
    final tmp = File('${cacheFile.path}.part');
    await tmp.writeAsBytes(res.bodyBytes, flush: true);
    await tmp.rename(cacheFile.path);
    return res.bodyBytes;
  }

  /// Descarcă în fundal logo-urile care lipsesc (pentru uz offline).
  static Future<void> prefetchLogos(Iterable<String> urls, {int concurrency = 3}) async {
    final queue = urls.where((u) => u.startsWith('http')).toSet().toList();
    Future<void> worker() async {
      while (queue.isNotEmpty) {
        final url = queue.removeLast();
        try {
          await fetchCached(url, logoFileFor(url));
        } catch (_) {}
      }
    }

    await Future.wait(List.generate(concurrency, (_) => worker()));
  }
}

/// ImageProvider care citește din cache-ul de pe disc, sau descarcă și
/// salvează la prima afișare.
@immutable
class CachedNetworkImageProvider extends ImageProvider<CachedNetworkImageProvider> {
  final String url;
  final String cachePath;
  final Map<String, String>? headers;

  const CachedNetworkImageProvider(this.url, this.cachePath, {this.headers});

  factory CachedNetworkImageProvider.logo(String url) =>
      CachedNetworkImageProvider(url, DiskCache.logoFileFor(url).path);

  @override
  Future<CachedNetworkImageProvider> obtainKey(ImageConfiguration configuration) =>
      SynchronousFuture<CachedNetworkImageProvider>(this);

  @override
  ImageStreamCompleter loadImage(CachedNetworkImageProvider key, ImageDecoderCallback decode) {
    return MultiFrameImageStreamCompleter(
      codec: _load(key, decode),
      scale: 1.0,
      debugLabel: key.url,
    );
  }

  Future<ui.Codec> _load(CachedNetworkImageProvider key, ImageDecoderCallback decode) async {
    final file = File(key.cachePath);
    try {
      final bytes = await DiskCache.fetchCached(key.url, file, headers: key.headers);
      return await decode(await ui.ImmutableBuffer.fromUint8List(bytes));
    } catch (e) {
      // Fișier corupt în cache -> îl ștergem ca să se reîncerce data viitoare.
      if (await file.exists() && e is! HttpException) {
        try {
          await file.delete();
        } catch (_) {}
      }
      PaintingBinding.instance.imageCache.evict(key);
      rethrow;
    }
  }

  @override
  bool operator ==(Object other) => other is CachedNetworkImageProvider && other.url == url;

  @override
  int get hashCode => url.hashCode;
}

// ── Harta (OpenTopoMap — relief pe date OpenStreetMap) ─────────────────────

const String kTerrainTileUrl = 'https://tile.opentopomap.org/{z}/{x}/{y}.png';
const int kTerrainMaxNativeZoom = 17;

/// Tile-urile văzute o dată sunt păstrate pe disc și refolosite offline.
class CachedTileProvider extends TileProvider {
  CachedTileProvider() : super(headers: {'User-Agent': kHttpUserAgent});

  static File tileFile(int z, int x, int y) =>
      File(p.join(DiskCache.tilesDir.path, '$z', '$x', '$y.png'));

  @override
  ImageProvider getImage(TileCoordinates coordinates, TileLayer options) {
    final url = getTileUrl(coordinates, options);
    final file = tileFile(coordinates.z, coordinates.x, coordinates.y);
    return CachedNetworkImageProvider(url, file.path, headers: headers);
  }
}

class _TileRange {
  final int z, minX, maxX, minY, maxY;
  _TileRange(this.z, this.minX, this.maxX, this.minY, this.maxY);
  int get count => (maxX - minX + 1) * (maxY - minY + 1);
}

_TileRange _rangeFor(int z, double south, double west, double north, double east) {
  final n = 1 << z;
  int tx(double lon) => ((lon + 180) / 360 * n).floor().clamp(0, n - 1);
  int ty(double lat) {
    final r = lat.clamp(-85.05, 85.05) * pi / 180;
    return ((1 - log(tan(r) + 1 / cos(r)) / pi) / 2 * n).floor().clamp(0, n - 1);
  }

  return _TileRange(z, tx(west), tx(east), ty(north), ty(south));
}

/// Numărul de tile-uri pentru zona dată între zoom-urile indicate.
int countTilesInArea({
  required double south,
  required double west,
  required double north,
  required double east,
  required int minZoom,
  required int maxZoom,
}) {
  int total = 0;
  for (int z = minZoom; z <= maxZoom; z++) {
    total += _rangeFor(z, south, west, north, east).count;
  }
  return total;
}

/// Salvează offline zona vizibilă. Limitat intenționat (zoom maxim și număr
/// de tile-uri) — serverele de hărți gratuite interzic descărcările masive.
Future<int> prefetchTileArea({
  required double south,
  required double west,
  required double north,
  required double east,
  required int minZoom,
  required int maxZoom,
  required void Function(int done, int total) onProgress,
  bool Function()? isCancelled,
}) async {
  final jobs = <List<int>>[];
  for (int z = minZoom; z <= maxZoom; z++) {
    final r = _rangeFor(z, south, west, north, east);
    for (int x = r.minX; x <= r.maxX; x++) {
      for (int y = r.minY; y <= r.maxY; y++) {
        jobs.add([z, x, y]);
      }
    }
  }

  int done = 0;
  int saved = 0;
  final total = jobs.length;
  onProgress(0, total);

  Future<void> worker() async {
    while (jobs.isNotEmpty) {
      if (isCancelled?.call() == true) return;
      final job = jobs.removeLast();
      final file = CachedTileProvider.tileFile(job[0], job[1], job[2]);
      if (!await file.exists()) {
        final url = kTerrainTileUrl
            .replaceAll('{z}', '${job[0]}')
            .replaceAll('{x}', '${job[1]}')
            .replaceAll('{y}', '${job[2]}');
        try {
          await DiskCache.fetchCached(url, file);
          saved++;
        } catch (_) {}
      }
      done++;
      onProgress(done, total);
    }
  }

  // Doar 2 conexiuni simultan, ca să nu încărcăm serverul de tile-uri.
  await Future.wait([worker(), worker()]);
  return saved;
}
