import 'package:flutter/material.dart';
import 'app_themes.dart';

class ThemeProvider extends ChangeNotifier {
  CountryTheme _currentTheme = appThemes['grecia']!;

  CountryTheme get currentTheme => _currentTheme;

  void switchTheme(String themeId) {
    if (appThemes.containsKey(themeId)) {
      _currentTheme = appThemes[themeId]!;
      notifyListeners(); // Asta va face interfața să se re-rendereze instant cu noile culori
    }
  }
}