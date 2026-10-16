import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'radio_station.dart';

const String _kFavoritesKey = 'radio_favorites';

/// Posturile favorite (♥). Salvate complet pe telefon, ca lista să meargă
/// și offline și indiferent de țara în care ești.
class RadioFavorites extends ChangeNotifier {
  RadioFavorites._();
  static final RadioFavorites instance = RadioFavorites._();

  List<RadioStation> _stations = [];

  List<RadioStation> get stations => List.unmodifiable(_stations);

  bool isFavorite(String uuid) => _stations.any((s) => s.uuid == uuid);

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getStringList(_kFavoritesKey) ?? [];
    final loaded = <RadioStation>[];
    for (final s in raw) {
      try {
        loaded.add(RadioStation.fromJson(jsonDecode(s) as Map<String, dynamic>));
      } catch (_) {}
    }
    _stations = loaded;
    notifyListeners();
  }

  Future<void> _save() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_kFavoritesKey, _stations.map((s) => jsonEncode(s.toJson())).toList());
  }

  /// Adaugă sau scoate postul; întoarce true dacă acum e favorit.
  Future<bool> toggle(RadioStation station) async {
    final added = !isFavorite(station.uuid);
    if (added) {
      _stations = [..._stations, station];
    } else {
      _stations = _stations.where((s) => s.uuid != station.uuid).toList();
    }
    notifyListeners();
    await _save();
    return added;
  }

  Future<void> reorder(int oldIndex, int newIndex) async {
    final list = List<RadioStation>.from(_stations);
    final item = list.removeAt(oldIndex);
    list.insert(newIndex.clamp(0, list.length), item);
    _stations = list;
    notifyListeners();
    await _save();
  }
}

/// Inimioara ♥ de pe un post: plină = favorit.
class FavoriteButton extends StatelessWidget {
  final RadioStation station;
  final double size;

  const FavoriteButton({super.key, required this.station, this.size = 24});

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: RadioFavorites.instance,
      builder: (context, _) {
        final fav = RadioFavorites.instance.isFavorite(station.uuid);
        return IconButton(
          iconSize: size,
          tooltip: fav ? 'Scoate din favorite' : 'Adaugă la favorite',
          icon: Icon(fav ? Icons.favorite : Icons.favorite_border, color: fav ? Colors.redAccent : null),
          onPressed: () async {
            final added = await RadioFavorites.instance.toggle(station);
            if (!context.mounted) return;
            ScaffoldMessenger.of(context)
              ..hideCurrentSnackBar()
              ..showSnackBar(SnackBar(
                duration: const Duration(seconds: 2),
                content: Text(added ? '❤ "${station.name}" adăugat la favorite' : '"${station.name}" scos din favorite'),
              ));
          },
        );
      },
    );
  }
}
