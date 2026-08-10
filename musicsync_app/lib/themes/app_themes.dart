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

  CountryTheme({
    required this.id,
    required this.name,
    required this.scaffoldBackground,
    required this.textColor,
    required this.accentColor,
    required this.cardBackground,
    required this.playerMoods,
  });
}

final Map<String, CountryTheme> appThemes = {
  'grecia': CountryTheme(
    id: 'grecia',
    name: 'Grecia',
    scaffoldBackground: const Color(0xFFF8F9FA),
    textColor: const Color(0xFF1A2530),
    accentColor: const Color(0xFF005A9C), // Albastru cobalt
    cardBackground: Colors.white,
    playerMoods: {
      SongMood.chill: PlayerColors(
        gradientColors: [const Color(0xFF003B46), const Color(0xFF07575B)],
        textColor: Colors.white,
        accentColor: const Color(0xFF66A5AD),
      ),
      SongMood.acoustic: PlayerColors(
        gradientColors: [const Color(0xFFF4EADE), const Color(0xFFE2D4C9)],
        textColor: const Color(0xFF4A3E3D),
        accentColor: const Color(0xFF8C7A6B),
      ),
      SongMood.energetic: PlayerColors(
        gradientColors: [const Color(0xFFE0F2FE), const Color(0xFFBAE6FD)],
        textColor: const Color(0xFF0369A1),
        accentColor: const Color(0xFFE11D48), // Roz Bougainvillea
      ),
      SongMood.melancholic: PlayerColors(
        gradientColors: [const Color(0xFF2D3A2E), const Color(0xFF1E251F)],
        textColor: const Color(0xFFE2E8F0),
        accentColor: const Color(0xFFF1F5F9),
      ),
    },
  ),
  'iran': CountryTheme(
    id: 'iran',
    name: 'Iran',
    scaffoldBackground: const Color(0xFF0B132B),
    textColor: const Color(0xFFF4F5F6),
    accentColor: const Color(0xFF00B4D8),
    cardBackground: const Color(0xFF1C2541),
    playerMoods: {
      SongMood.chill: PlayerColors(
        gradientColors: [const Color(0xFF023E8A), const Color(0xFF03045E)],
        textColor: Colors.white,
        accentColor: const Color(0xFF00B4D8),
      ),
      // Adaugi restul stărilor la fel...
    },
  ),
  // Adaugi restul țărilor (Turcia, Armenia, Asia Centrală) respectând structura
};