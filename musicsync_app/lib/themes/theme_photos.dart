import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'app_themes.dart';

const List<String> _kImageExtensions = ['.jpg', '.jpeg', '.png', '.webp'];

bool _isImage(String path) => _kImageExtensions.contains(p.extension(path).toLowerCase());

/// O poză de fundal a unei teme: inclusă în aplicație (asset) sau adăugată
/// de utilizator din galerie (fișier).
class ThemePhoto {
  final String? assetPath;
  final File? file;

  const ThemePhoto.asset(String this.assetPath) : file = null;
  const ThemePhoto.file(File this.file) : assetPath = null;

  bool get isUserPhoto => file != null;

  ImageProvider get image => file != null ? FileImage(file!) : AssetImage(assetPath!) as ImageProvider;

  @override
  bool operator ==(Object other) => other is ThemePhoto && other.assetPath == assetPath && other.file?.path == file?.path;

  @override
  int get hashCode => Object.hash(assetPath, file?.path);
}

/// `assets/images/<folder>/<poză>` -> { folder: [poze sortate] }.
Map<String, List<String>> groupThemeAssets(Iterable<String> assetPaths) {
  final result = <String, List<String>>{};
  for (final path in assetPaths) {
    final parts = path.split('/');
    if (parts.length != 4 || parts[0] != 'assets' || parts[1] != 'images' || !_isImage(path)) continue;
    (result[parts[2]] ??= []).add(path);
  }
  for (final list in result.values) {
    list.sort();
  }
  return result;
}

/// Pozele temelor. Două surse, ca adăugarea să fie ușoară:
/// 1. Orice imagine pusă în `assets/images/<folder>/` e preluată automat la
///    următorul build (fără să mai fie scrisă în cod).
/// 2. Pozele adăugate din aplicație (ecranul "Poze temă") — copiate în
///    datele aplicației, disponibile imediat, fără rebuild.
class ThemePhotos extends ChangeNotifier {
  ThemePhotos._();
  static final ThemePhotos instance = ThemePhotos._();

  Map<String, List<String>> _assets = {};
  String? _userRoot;

  Future<void> init() async {
    try {
      final manifest = await AssetManifest.loadFromAssetBundle(rootBundle);
      _assets = groupThemeAssets(manifest.listAssets());
    } catch (e) {
      debugPrint('[ThemePhotos] AssetManifest indisponibil: $e');
    }
    final support = await getApplicationSupportDirectory();
    _userRoot = p.join(support.path, 'theme_photos');
  }

  Directory _userDir(CountryTheme theme) => Directory(p.join(_userRoot!, theme.photoFolder));

  List<File> userPhotosFor(CountryTheme theme) {
    if (_userRoot == null) return [];
    final dir = _userDir(theme);
    if (!dir.existsSync()) return [];
    final files = dir.listSync().whereType<File>().where((f) => _isImage(f.path)).toList()
      ..sort((a, b) => a.path.compareTo(b.path));
    return files;
  }

  List<ThemePhoto> photosFor(CountryTheme theme) => [
        for (final a in _assets[theme.photoFolder] ?? const <String>[]) ThemePhoto.asset(a),
        for (final f in userPhotosFor(theme)) ThemePhoto.file(f),
      ];

  /// Copiază pozele alese în folderul temei. Întoarce câte au fost adăugate.
  Future<int> addUserPhotos(CountryTheme theme, List<String> sourcePaths) async {
    if (_userRoot == null) return 0;
    final dir = _userDir(theme);
    await dir.create(recursive: true);
    int added = 0;
    for (final source in sourcePaths) {
      if (!_isImage(source)) continue;
      final name = '${DateTime.now().microsecondsSinceEpoch}_${p.basename(source)}';
      await File(source).copy(p.join(dir.path, name));
      added++;
    }
    if (added > 0) notifyListeners();
    return added;
  }

  Future<void> removeUserPhoto(File file) async {
    if (await file.exists()) await file.delete();
    notifyListeners();
  }
}
