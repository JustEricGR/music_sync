import 'package:flutter/material.dart';
import 'app_themes.dart';
import 'dart:math';

class ThemeProvider extends ChangeNotifier {
  CountryTheme _currentTheme = appThemes['grecia']!;
  String? _currentBackgroundImage; // Stochează calea imaginii curente

  CountryTheme get currentTheme => _currentTheme;
  String? get currentBackgroundImage => _currentBackgroundImage; // Getter pentru ecranul player-ului

  ThemeProvider() {
    // Selectează o imagine random pentru tema inițială (Grecia) la pornirea aplicației
    _pickRandomImage();
  }

  // Funcție internă care alege o imagine la întâmplare din lista temei curente
  void _pickRandomImage() {
    // Presupunem că ai adăugat listul `assetPhotos` în clasa CountryTheme
    if (_currentTheme.assetPhotos != null && _currentTheme.assetPhotos!.isNotEmpty) {
      final random = Random();
      _currentBackgroundImage = _currentTheme.assetPhotos![random.nextInt(_currentTheme.assetPhotos!.length)];
    } else {
      _currentBackgroundImage = null; // Fallback în caz că o țară nu are imagini definite
    }
  }

  // Transformă tema țării curente în ThemeData pentru MaterialApp
  ThemeData get themeData {
    return ThemeData(
      useMaterial3: true,
      scaffoldBackgroundColor: _currentTheme.scaffoldBackground,
      primaryColor: _currentTheme.accentColor,
      colorScheme: ColorScheme.fromSeed(
        seedColor: _currentTheme.accentColor,
        primary: _currentTheme.accentColor,
        secondary: _currentTheme.accentColor,
        surface: _currentTheme.cardBackground,
        brightness: Brightness.dark,
      ),
      appBarTheme: AppBarTheme(
        backgroundColor: _currentTheme.scaffoldBackground,
        foregroundColor: _currentTheme.textColor,
      ),
      textTheme: TextTheme(
        bodyLarge: TextStyle(color: _currentTheme.textColor),
        bodyMedium: TextStyle(color: _currentTheme.textColor),
      ),
    );
  }

  void switchTheme(String themeId) {
    if (appThemes.containsKey(themeId)) {
      _currentTheme = appThemes[themeId]!;
      _pickRandomImage(); // Alege o nouă imagine random când utilizatorul schimbă țara
      notifyListeners();
    }
  }
}