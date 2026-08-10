import 'package:flutter/material.dart';
import 'app_themes.dart';

class ThemeProvider extends ChangeNotifier {
  CountryTheme _currentTheme = appThemes['grecia']!;

  CountryTheme get currentTheme => _currentTheme;

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
      notifyListeners();
    }
  }
}