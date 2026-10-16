import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'app_themes.dart';
import 'theme_photos.dart';
import 'dart:math';

const String _kAutoThemePrefsKey = 'auto_theme_enabled';

class ThemeProvider extends ChangeNotifier {
  CountryTheme _currentTheme = appThemes['grecia']!;
  ThemePhoto? _currentBackground; // Poza de fundal curentă
  bool _autoThemeEnabled = true;

  CountryTheme get currentTheme => _currentTheme;
  ThemePhoto? get currentBackground => _currentBackground;

  /// Tema se schimbă singură după țara playlistului / postului de radio
  /// pornit (Grecia dacă nu se poate detecta).
  bool get autoThemeEnabled => _autoThemeEnabled;

  ThemeProvider() {
    // Selectează o imagine random pentru tema inițială (Grecia) la pornirea aplicației
    _pickRandomImage();
    _loadAutoThemePref();
  }

  Future<void> _loadAutoThemePref() async {
    final prefs = await SharedPreferences.getInstance();
    _autoThemeEnabled = prefs.getBool(_kAutoThemePrefsKey) ?? true;
    notifyListeners();
  }

  Future<void> setAutoThemeEnabled(bool enabled) async {
    _autoThemeEnabled = enabled;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kAutoThemePrefsKey, enabled);
  }

  /// Aplică tema detectată automat (doar dacă opțiunea e activă).
  void applyAutoTheme(String themeId) {
    if (!_autoThemeEnabled || themeId == _currentTheme.id) return;
    switchTheme(themeId);
  }

  // Funcție internă care alege o imagine la întâmplare din pozele temei curente
  void _pickRandomImage() {
    final photos = ThemePhotos.instance.photosFor(_currentTheme);
    _currentBackground = photos.isEmpty ? null : photos[Random().nextInt(photos.length)];
  }

  // Transformă tema țării curente în ThemeData pentru MaterialApp
  ThemeData get themeData {
    // Dialogurile/meniurile/cardurile M3 folosesc surfaceContainer*, pe care
    // fromSeed(brightness: dark) le face mereu închise — dar textul temei
    // Grecia e închis la culoare, deci textul (ex. linkul lipit în dialogul
    // de playlist) ajungea închis pe închis. Le legăm de cardBackground-ul
    // temei, cu text ales după luminozitatea lui.
    final surface = _currentTheme.cardBackground;
    final onSurface = surface.computeLuminance() > 0.5 ? const Color(0xFF1A1A1A) : Colors.white;

    return ThemeData(
      useMaterial3: true,
      scaffoldBackgroundColor: _currentTheme.scaffoldBackground,
      primaryColor: _currentTheme.accentColor,
      colorScheme: ColorScheme.fromSeed(
        seedColor: _currentTheme.accentColor,
        primary: _currentTheme.accentColor,
        secondary: _currentTheme.accentColor,
        surface: surface,
        onSurface: onSurface,
        onSurfaceVariant: onSurface.withValues(alpha: 0.7),
        surfaceContainerLowest: surface,
        surfaceContainerLow: surface,
        surfaceContainer: surface,
        surfaceContainerHigh: surface,
        surfaceContainerHighest: surface,
        brightness: Brightness.dark,
      ),
      appBarTheme: AppBarTheme(
        backgroundColor: _currentTheme.scaffoldBackground,
        foregroundColor: _currentTheme.textColor,
      ),
      // Pe suprafețe (carduri, dialoguri, câmpuri) textul trebuie să
      // contrasteze cu cardBackground, nu cu fundalul ecranului.
      textTheme: TextTheme(
        bodyLarge: TextStyle(color: onSurface),
        bodyMedium: TextStyle(color: onSurface),
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
