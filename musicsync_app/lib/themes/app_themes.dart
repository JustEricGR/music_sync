import 'package:flutter/material.dart';

enum SongMood { chill, acoustic, energetic, melancholic }

class PlayerColors {
  final List<Color> gradientColors;
  final Color textColor;
  final Color accentColor;

  PlayerColors({
    required this.gradientColors,
    required this.textColor,
    required this.accentColor,
  });
}

class CountryTheme {
  final String id;
  final String name;
  final Color scaffoldBackground;
  final Color textColor;
  final Color accentColor;
  final Color cardBackground;
  final Map<SongMood, PlayerColors> playerMoods;
  final List<String> assetPhotos;

  CountryTheme({
    required this.id,
    required this.name,
    required this.scaffoldBackground,
    required this.textColor,
    required this.accentColor,
    required this.cardBackground,
    required this.playerMoods,
    required this.assetPhotos,
  });
}

final Map<String, CountryTheme> appThemes = {

  // ─────────────────────────────────────────────────────────────────────────
  // ARMENIA — Ararat poppy fields, tufa stone churches, khachkar gold trim
  // ─────────────────────────────────────────────────────────────────────────
  'armenia': CountryTheme(
    id: 'armenia',
    name: 'Armenia',
    scaffoldBackground: const Color(0xFF1A100A),
    assetPhotos: [
      "assets\images\armenia\armenia1.jpg",
      "assets\images\armenia\armenia2.jpg",
      "assets\images\armenia\armenia3.jpg",
      "assets\images\armenia\armenia4.jpg",
      "assets\images\armenia\armenia5.jpg"
    ],
    textColor: const Color(0xFFF5ECD7),
    accentColor: const Color(0xFFC8241A),
    cardBackground: const Color(0xFF2A1A10),
    playerMoods: {
      SongMood.chill: PlayerColors(
        gradientColors: [const Color(0xFF1A3550), const Color(0xFF2A6080)],
        textColor: const Color(0xFFD0E8F5),
        accentColor: const Color(0xFF4A9FD4),
      ),
      SongMood.acoustic: PlayerColors(
        gradientColors: [const Color(0xFF5C3518), const Color(0xFF8B5A2A)],
        textColor: const Color(0xFFFFF3E0),
        accentColor: const Color(0xFFD4A820),
      ),
      SongMood.energetic: PlayerColors(
        gradientColors: [const Color(0xFF8B0A0A), const Color(0xFFC8241A)],
        textColor: Colors.white,
        accentColor: const Color(0xFF3D7A3D),
      ),
      SongMood.melancholic: PlayerColors(
        gradientColors: [const Color(0xFF1A1A2E), const Color(0xFF2A1A3A)],
        textColor: const Color(0xFFD4C0A8),
        accentColor: const Color(0xFF8B1A1A),
      ),
    },
  ),

  // ─────────────────────────────────────────────────────────────────────────
  // GREECE — Sun-bleached limestone, Aegean blue, bougainvillea pink, vine
  // ─────────────────────────────────────────────────────────────────────────
  'grecia': CountryTheme(
    id: 'grecia',
    name: 'Grecia',
    scaffoldBackground: const Color(0xFFF4EED8),
    assetPhotos: [
      "assets\images\greece\greece1.jpg",
      "assets\images\greece\greece2.jpg",
      "assets\images\greece\greece3.jpg",
      "assets\images\greece\greece4.jpg",
      "assets\images\greece\greece5.jpg",
      "assets\images\greece\greece6.jpg",
      "assets\images\greece\greece7.jpg"
    ],
    textColor: const Color(0xFF1A2A3A),
    accentColor: const Color(0xFF1A5FA8),
    cardBackground: const Color(0xFFFFFFFF),
    playerMoods: {
      SongMood.chill: PlayerColors(
        gradientColors: [const Color(0xFF1A4A6A), const Color(0xFF2A7A9A)],
        textColor: const Color(0xFFD8EEF5),
        accentColor: const Color(0xFF6A9AB0),
      ),
      SongMood.acoustic: PlayerColors(
        gradientColors: [const Color(0xFF6A4010), const Color(0xFFA07030)],
        textColor: const Color(0xFFFFF8E8),
        accentColor: const Color(0xFF8A9A6A),
      ),
      SongMood.energetic: PlayerColors(
        gradientColors: [const Color(0xFF1A5FA8), const Color(0xFF2A8FD4)],
        textColor: Colors.white,
        accentColor: const Color(0xFFD4186A),
      ),
      SongMood.melancholic: PlayerColors(
        gradientColors: [const Color(0xFF1A2A1A), const Color(0xFF2A3A2A)],
        textColor: const Color(0xFFD8C8A0),
        accentColor: const Color(0xFFC8A060),
      ),
    },
  ),

  // ─────────────────────────────────────────────────────────────────────────
  // IRAN — From the photos:
  //   • Damavand poppy fields: vivid crimson #C0392B, emerald #2E7D32
  //   • Snow-capped peaks: icy slate #B0BEC5
  //   • Persian miniature (img 4): saffron #E67E22, cobalt tile #1A6FA8,
  //     terracotta robe #A0522D, jade garden #4CAF50
  //   • Overall feel: rich, warm, ancient — dark saffron night base
  // ─────────────────────────────────────────────────────────────────────────
  'iran': CountryTheme(
    id: 'iran',
    name: 'Iran',
    // Deep saffron-night — like the sky behind Damavand at dusk
    scaffoldBackground: const Color(0xFF1A0F00),
    assetPhotos: [
      "assets\images\iran\iran1.jpg",
      "assets\images\iran\iran2.jpg",
      "assets\images\iran\iran3.jpg",
      "assets\images\iran\iran4.jpg",
      "assets\images\iran\iran5.jpg",
      "assets\images\iran\iran6.jpg",
      "assets\images\iran\iran7.jpg",
      "assets\images\iran\iran8.jpg"
    ],
    textColor: const Color(0xFFF5E6C8),       // warm parchment
    accentColor: const Color(0xFFD4890A),      // saffron gold
    cardBackground: const Color(0xFF2C1A00),   // dark spice brown
    playerMoods: {
      // Chill — the misty mountain morning, snow & green hills
      SongMood.chill: PlayerColors(
        gradientColors: [const Color(0xFF1B4332), const Color(0xFF2D6A4F)],
        textColor: const Color(0xFFD8F3DC),
        accentColor: const Color(0xFF95D5B2),
      ),
      // Acoustic — Persian miniature warmth: terracotta, cobalt tile, saffron
      SongMood.acoustic: PlayerColors(
        gradientColors: [const Color(0xFF6B2D0F), const Color(0xFF9C4A1A)],
        textColor: const Color(0xFFFFF3E0),
        accentColor: const Color(0xFF1A6FA8),  // cobalt from the minaret tile
      ),
      // Energetic — the poppy field explosion: crimson on emerald
      SongMood.energetic: PlayerColors(
        gradientColors: [const Color(0xFF7B0000), const Color(0xFFC0392B)],
        textColor: Colors.white,
        accentColor: const Color(0xFF4CAF50),  // the vivid grass green
      ),
      // Melancholic — Damavand at dusk: dusty lavender sky, dark earth
      SongMood.melancholic: PlayerColors(
        gradientColors: [const Color(0xFF2C2535), const Color(0xFF1A1520)],
        textColor: const Color(0xFFD7C4A3),
        accentColor: const Color(0xFFD4890A),  // a single saffron lamp
      ),
    },
  ),

  // ─────────────────────────────────────────────────────────────────────────
  // TURKEY — From the photos:
  //   • Uzungöl (img 7): deep forest green #2E4A1E, misty teal lake #5B8A8B,
  //     red tablecloth stripe #C0392B, silver çaydanlık #8A9BA8
  //   • Istanbul (img 9): Bosphorus amber haze #C8914A, Hagia Sophia stone
  //     #8B7355, Iznik tile blue #1B6CA8, tulip crimson #C0392B,
  //     Galata moonrise amber #E8A020, foggy grey-violet silhouette #4A4560
  //   • Overall feel: layered, imperial, melancholic yet warm
  // ─────────────────────────────────────────────────────────────────────────
  'turcia': CountryTheme(
    id: 'turcia',
    name: 'Turcia',
    // Istanbul at golden hour — the amber haze over the Bosphorus
    scaffoldBackground: const Color(0xFF1C1208),
    assetPhotos: [
      "assets\images\turkey\turkey1.jpg",
      "assets\images\turkey\turkey2.jpg",
      "assets\images\turkey\turkey3.jpg",
      "assets\images\turkey\turkey4.jpg",
      "assets\images\turkey\turkey5.jpg",
      "assets\images\turkey\turkey6.jpg"
    ],
    textColor: const Color(0xFFF0E0C0),        // aged parchment
    accentColor: const Color(0xFF1B6CA8),       // Iznik tile cobalt
    cardBackground: const Color(0xFF2A1E0A),    // dark Ottoman wood
    playerMoods: {
      // Chill — Uzungöl morning mist: deep green forest + teal lake
      SongMood.chill: PlayerColors(
        gradientColors: [const Color(0xFF1B3A1F), const Color(0xFF2E6B5E)],
        textColor: const Color(0xFFD4EDD4),
        accentColor: const Color(0xFF7EC8C8),   // the lake surface
      ),
      // Acoustic — Ottoman café warmth: Hagia Sophia stone + amber lamp
      SongMood.acoustic: PlayerColors(
        gradientColors: [const Color(0xFF5C4A2A), const Color(0xFF8B6914)],
        textColor: const Color(0xFFFFF8E7),
        accentColor: const Color(0xFFE8A020),   // çay glass in the light
      ),
      // Energetic — Iznik tile energy: cobalt blue + tulip crimson
      SongMood.energetic: PlayerColors(
        gradientColors: [const Color(0xFF0D3B6E), const Color(0xFF1B6CA8)],
        textColor: Colors.white,
        accentColor: const Color(0xFFD4182A),   // the tulip in the tile
      ),
      // Melancholic — Istanbul silhouette at dusk: violet-grey fog + amber
      SongMood.melancholic: PlayerColors(
        gradientColors: [const Color(0xFF2A2535), const Color(0xFF3D3050)],
        textColor: const Color(0xFFD8C8A8),
        accentColor: const Color(0xFFC8914A),   // single Bosphorus glow
      ),
    },
  ),

  // ─────────────────────────────────────────────────────────────────────────
  // AZERBAIJAN — From the photos:
  //   • Flag (img 5): sky blue #00B9E4, crimson #EF3340, green #00B140
  //   • Flame Towers Baku skyline: sunset orange-copper #D4622A
  //   • Pomegranate (img 6): deep ruby #8B1A2A, sandy mosque stone #D4B896
  //   • Carpet patterns: rich burgundy #6B1D2E, ivory #F5ECD7
  //   • Caucasus gorge (img 5 bottom): dark slate green #2A3D2A
  //   • Mostar bridge water (img 8): turquoise river #2AABB5
  //   • Overall feel: vibrant folk energy, ancient + modern duality
  // ─────────────────────────────────────────────────────────────────────────
  'azerbaidjan': CountryTheme(
    id: 'azerbaidjan',
    name: 'Azerbaidjan',
    // Deep carpet burgundy — like the traditional Azerbaijani kilim
    scaffoldBackground: const Color(0xFF180A10),
    assetPhotos: [
      "assets\images\azerbaijan\azerbaijan1.jpg"
    ],
    textColor: const Color(0xFFF5ECD7),        // carpet ivory
    accentColor: const Color(0xFF00B9E4),       // flag sky blue
    cardBackground: const Color(0xFF2A1018),    // dark pomegranate wine
    playerMoods: {
      // Chill — Caucasus highlands at dawn: slate green + misty blue
      SongMood.chill: PlayerColors(
        gradientColors: [const Color(0xFF1A2E1A), const Color(0xFF2A4A4A)],
        textColor: const Color(0xFFCCE5E5),
        accentColor: const Color(0xFF5BBFBF),
      ),
      // Acoustic — traditional carpet & tea: burgundy + ivory + copper
      SongMood.acoustic: PlayerColors(
        gradientColors: [const Color(0xFF4A1020), const Color(0xFF6B1D2E)],
        textColor: const Color(0xFFF5ECD7),
        accentColor: const Color(0xFFD4622A),   // copper samovar
      ),
      // Energetic — flag colors: crimson + sky blue Baku flame energy
      SongMood.energetic: PlayerColors(
        gradientColors: [const Color(0xFFAA1528), const Color(0xFFEF3340)],
        textColor: Colors.white,
        accentColor: const Color(0xFF00B9E4),   // flag sky blue
      ),
      // Melancholic — pomegranate deep ruby + sandstone mosque dusk
      SongMood.melancholic: PlayerColors(
        gradientColors: [const Color(0xFF3D1010), const Color(0xFF5C1A1A)],
        textColor: const Color(0xFFE8C8A0),
        accentColor: const Color(0xFF8B1A2A),   // deep pomegranate
      ),
    },
  ),

  'kurdistan': CountryTheme(
    id: 'kurdistan',
    name: 'Kurdistan',
    // Deep carpet burgundy — like the traditional Azerbaijani kilim
    scaffoldBackground: const Color(0xFF180A10),
    assetPhotos: [
      "assets\images\kurdistan\kurdistan1.jpg",
      "assets\images\kurdistan\kurdistan2.jpg",
      "assets\images\kurdistan\kurdistan3.jpg",
      "assets\images\kurdistan\kurdistan4.jpg"
    ],
    textColor: const Color(0xFFF5ECD7),        // carpet ivory
    accentColor: const Color(0xFF00B9E4),       // flag sky blue
    cardBackground: const Color(0xFF2A1018),    // dark pomegranate wine
    playerMoods: {
      // Chill — Caucasus highlands at dawn: slate green + misty blue
      SongMood.chill: PlayerColors(
        gradientColors: [const Color(0xFF1A2E1A), const Color(0xFF2A4A4A)],
        textColor: const Color(0xFFCCE5E5),
        accentColor: const Color(0xFF5BBFBF),
      ),
      // Acoustic — traditional carpet & tea: burgundy + ivory + copper
      SongMood.acoustic: PlayerColors(
        gradientColors: [const Color(0xFF4A1020), const Color(0xFF6B1D2E)],
        textColor: const Color(0xFFF5ECD7),
        accentColor: const Color(0xFFD4622A),   // copper samovar
      ),
      // Energetic — flag colors: crimson + sky blue Baku flame energy
      SongMood.energetic: PlayerColors(
        gradientColors: [const Color(0xFFAA1528), const Color(0xFFEF3340)],
        textColor: Colors.white,
        accentColor: const Color(0xFF00B9E4),   // flag sky blue
      ),
      // Melancholic — pomegranate deep ruby + sandstone mosque dusk
      SongMood.melancholic: PlayerColors(
        gradientColors: [const Color(0xFF3D1010), const Color(0xFF5C1A1A)],
        textColor: const Color(0xFFE8C8A0),
        accentColor: const Color(0xFF8B1A2A),   // deep pomegranate
      ),
    },
  ),

  'bosnia': CountryTheme(
    id: 'bosnia',
    name: 'Bosnia',
    // Deep carpet burgundy — like the traditional Azerbaijani kilim
    scaffoldBackground: const Color(0xFF180A10),
    assetPhotos: [
      "assets\images\bosnia\bosnia1.jpg"
    ],
    textColor: const Color(0xFFF5ECD7),        // carpet ivory
    accentColor: const Color(0xFF00B9E4),       // flag sky blue
    cardBackground: const Color(0xFF2A1018),    // dark pomegranate wine
    playerMoods: {
      // Chill — Caucasus highlands at dawn: slate green + misty blue
      SongMood.chill: PlayerColors(
        gradientColors: [const Color(0xFF1A2E1A), const Color(0xFF2A4A4A)],
        textColor: const Color(0xFFCCE5E5),
        accentColor: const Color(0xFF5BBFBF),
      ),
      // Acoustic — traditional carpet & tea: burgundy + ivory + copper
      SongMood.acoustic: PlayerColors(
        gradientColors: [const Color(0xFF4A1020), const Color(0xFF6B1D2E)],
        textColor: const Color(0xFFF5ECD7),
        accentColor: const Color(0xFFD4622A),   // copper samovar
      ),
      // Energetic — flag colors: crimson + sky blue Baku flame energy
      SongMood.energetic: PlayerColors(
        gradientColors: [const Color(0xFFAA1528), const Color(0xFFEF3340)],
        textColor: Colors.white,
        accentColor: const Color(0xFF00B9E4),   // flag sky blue
      ),
      // Melancholic — pomegranate deep ruby + sandstone mosque dusk
      SongMood.melancholic: PlayerColors(
        gradientColors: [const Color(0xFF3D1010), const Color(0xFF5C1A1A)],
        textColor: const Color(0xFFE8C8A0),
        accentColor: const Color(0xFF8B1A2A),   // deep pomegranate
      ),
    },
  ),

  'central asia': CountryTheme(
    id: 'central asia',
    name: 'Central Asia',
    // Deep carpet burgundy — like the traditional Azerbaijani kilim
    scaffoldBackground: const Color(0xFF180A10),
    assetPhotos: [
      "assets\images\central_asia\central_asia1.jpg"
    ],
    textColor: const Color(0xFFF5ECD7),        // carpet ivory
    accentColor: const Color(0xFF00B9E4),       // flag sky blue
    cardBackground: const Color(0xFF2A1018),    // dark pomegranate wine
    playerMoods: {
      // Chill — Caucasus highlands at dawn: slate green + misty blue
      SongMood.chill: PlayerColors(
        gradientColors: [const Color(0xFF1A2E1A), const Color(0xFF2A4A4A)],
        textColor: const Color(0xFFCCE5E5),
        accentColor: const Color(0xFF5BBFBF),
      ),
      // Acoustic — traditional carpet & tea: burgundy + ivory + copper
      SongMood.acoustic: PlayerColors(
        gradientColors: [const Color(0xFF4A1020), const Color(0xFF6B1D2E)],
        textColor: const Color(0xFFF5ECD7),
        accentColor: const Color(0xFFD4622A),   // copper samovar
      ),
      // Energetic — flag colors: crimson + sky blue Baku flame energy
      SongMood.energetic: PlayerColors(
        gradientColors: [const Color(0xFFAA1528), const Color(0xFFEF3340)],
        textColor: Colors.white,
        accentColor: const Color(0xFF00B9E4),   // flag sky blue
      ),
      // Melancholic — pomegranate deep ruby + sandstone mosque dusk
      SongMood.melancholic: PlayerColors(
        gradientColors: [const Color(0xFF3D1010), const Color(0xFF5C1A1A)],
        textColor: const Color(0xFFE8C8A0),
        accentColor: const Color(0xFF8B1A2A),   // deep pomegranate
      ),
    },
  ),

};