import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import 'app_themes.dart';
import 'theme_photos.dart';

/// Pozele de fundal ale unei teme: cele incluse în aplicație și cele
/// adăugate din galerie (care pot fi șterse).
class ThemePhotosScreen extends StatelessWidget {
  final CountryTheme theme;

  const ThemePhotosScreen({super.key, required this.theme});

  Future<void> _addPhotos(BuildContext context) async {
    final result = await FilePicker.platform.pickFiles(type: FileType.image, allowMultiple: true);
    final paths = result?.files.map((f) => f.path).whereType<String>().toList() ?? [];
    if (paths.isEmpty) return;

    final added = await ThemePhotos.instance.addUserPhotos(theme, paths);
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('$added ${added == 1 ? 'poză adăugată' : 'poze adăugate'} la ${theme.name}.')),
      );
    }
  }

  Future<void> _confirmRemove(BuildContext context, ThemePhoto photo) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Ștergi poza?'),
        content: Image(image: photo.image, height: 160, fit: BoxFit.cover),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialogContext, false), child: const Text('Anulează')),
          ElevatedButton(onPressed: () => Navigator.pop(dialogContext, true), child: const Text('Șterge')),
        ],
      ),
    );
    if (ok == true) await ThemePhotos.instance.removeUserPhoto(photo.file!);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('Poze — ${theme.name}')),
      floatingActionButton: FloatingActionButton.extended(
        icon: const Icon(Icons.add_photo_alternate),
        label: const Text('Adaugă poze'),
        onPressed: () => _addPhotos(context),
      ),
      body: AnimatedBuilder(
        animation: ThemePhotos.instance,
        builder: (context, _) {
          final photos = ThemePhotos.instance.photosFor(theme);
          if (photos.isEmpty) {
            return const Center(child: Text('Nicio poză încă. Adaugă din galerie.'));
          }
          return GridView.builder(
            padding: const EdgeInsets.fromLTRB(8, 8, 8, 96),
            gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
              maxCrossAxisExtent: 180,
              mainAxisSpacing: 8,
              crossAxisSpacing: 8,
              childAspectRatio: 0.75,
            ),
            itemCount: photos.length,
            itemBuilder: (context, i) {
              final photo = photos[i];
              return ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    Image(
                      image: photo.image,
                      fit: BoxFit.cover,
                      errorBuilder: (_, __, ___) => const ColoredBox(
                        color: Colors.black26,
                        child: Icon(Icons.broken_image),
                      ),
                    ),
                    Positioned(
                      left: 6,
                      bottom: 6,
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                        decoration: BoxDecoration(color: Colors.black54, borderRadius: BorderRadius.circular(8)),
                        child: Text(
                          photo.isUserPhoto ? 'adăugată' : 'inclusă',
                          style: const TextStyle(color: Colors.white, fontSize: 11),
                        ),
                      ),
                    ),
                    if (photo.isUserPhoto)
                      Positioned(
                        right: 2,
                        top: 2,
                        child: IconButton.filled(
                          style: IconButton.styleFrom(backgroundColor: Colors.black54),
                          icon: const Icon(Icons.delete, color: Colors.white, size: 18),
                          tooltip: 'Șterge poza',
                          onPressed: () => _confirmRemove(context, photo),
                        ),
                      ),
                  ],
                ),
              );
            },
          );
        },
      ),
    );
  }
}
