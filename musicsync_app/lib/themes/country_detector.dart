/// Detecția automată a temei (țării) pentru un playlist sau un post de
/// radio. Funcții pure — fără Flutter — ca să poată fi testate direct.
library;

import 'dart:math';

const String kDefaultThemeId = 'grecia';

/// Cod ISO de țară (ex. al unui post de radio) -> ID temă.
const Map<String, String> kCountryCodeToTheme = {
  'GR': 'grecia',
  'CY': 'grecia',
  'TR': 'turcia',
  'AM': 'armenia',
  'IR': 'iran',
  'AZ': 'azerbaidjan',
  'BA': 'bosnia',
  'RS': 'bosnia',
  'HR': 'bosnia',
  'ME': 'bosnia',
  'MK': 'bosnia',
  'XK': 'bosnia',
  'KZ': 'central asia',
  'UZ': 'central asia',
  'KG': 'central asia',
  'TJ': 'central asia',
  'TM': 'central asia',
};

String themeForCountryCode(String? countryCode) =>
    kCountryCodeToTheme[(countryCode ?? '').toUpperCase()] ?? kDefaultThemeId;

/// Cuvinte-cheie (fragmente regex, potrivite la începutul unui cuvânt).
const Map<String, List<String>> _keywords = {
  'grecia': [
    'greek', 'greece', 'grecia', 'grecesc', 'greceasc', 'ellinik', 'elliniko', 'ελλην',
    'rebetiko', 'ρεμπέτικ', 'laiko', 'laika', 'λαϊκ', 'zeibekiko', 'ζεϊμπέκικ',
    'bouzouki', 'μπουζούκ', 'nisiotika', 'νησιώτικ', 'skyladiko', 'σκυλάδικ',
  ],
  'turcia': [
    'turkish', 'turkey', 'türkiye', 'turkiye', 'türkçe', 'turkce', r'türk(?!men)', r'turk(?!men)',
    'turcia', 'turcesc', 'turceasc', 'arabesk', 'anadolu', 'anatolian', 'istanbul',
    'karadeniz', 'bağlama', 'baglama', 'türkü',
  ],
  'armenia': [
    'armenian', 'armenia', 'armenesc', 'armeneasc', 'hayeren', 'հայ', 'rabiz', 'duduk', 'yerevan',
  ],
  'iran': [
    'persian', 'iran', 'farsi', 'فارسی', 'ایران', 'persan', 'tehran',
  ],
  'azerbaidjan': [
    'azeri', 'azerbaijan', 'azerbaycan', 'azərbaycan', 'azerbaidjan', 'mugham', 'meyxana', 'meykhana', 'baku', 'bakı',
  ],
  'kurdistan': [
    'kurd', 'kurdî', 'kurdistan', 'کوردی', 'کورد', 'dengbêj', 'stranên',
  ],
  'bosnia': [
    'bosnia', 'bosna', 'bosansk', 'sevdah', 'sevdalink', 'balkan', 'yugo', 'jugo', 'ex-yu', 'exyu',
    'srpsk', 'hrvatsk', 'narodn', 'turbo ?folk', 'sarajevo', 'beograd', 'zagreb',
  ],
  'central asia': [
    'kazakh', 'qazaq', 'uzbek', 'oʻzbek', "o'zbek", 'kyrgyz', 'tajik', 'turkmen', 'türkmen',
    'central asia', 'asia centrala', 'dombra',
  ],
};

final Map<String, List<RegExp>> _keywordPatterns = {
  for (final e in _keywords.entries)
    e.key: e.value.map((k) => RegExp(r'(?:^|[^\p{L}])' + k, unicode: true, caseSensitive: false)).toList(),
};

// Semnale după alfabet / litere specifice unei limbi.
final RegExp _greekScript = RegExp(r'[Ͱ-Ͽἀ-῿]');
final RegExp _armenianScript = RegExp(r'[԰-֏]');
final RegExp _arabicScript = RegExp(r'[؀-ۿ]');
final RegExp _soraniLetters = RegExp(r'[ڕڵێۆە]');
final RegExp _azeriLetters = RegExp(r'[əƏ]');
final RegExp _turkishLetters = RegExp(r'[ğĞıİşŞ]');
final RegExp _kurmanjiLetters = RegExp(r'[êÊ]');
final RegExp _exYuLatin = RegExp(r'[đĐćĆ]');
final RegExp _exYuCyrillic = RegExp(r'[ђјљњћџЂЈЉЊЋЏ]');
final RegExp _centralAsianCyrillic = RegExp(r'[әғқңөұүһіӘҒҚҢӨҰҮҺІ]');

/// Țara indicată de alfabetul/literele dintr-un text, sau null.
String? _scriptSignal(String text) {
  if (_greekScript.hasMatch(text)) return 'grecia';
  if (_armenianScript.hasMatch(text)) return 'armenia';
  if (_arabicScript.hasMatch(text)) {
    return _soraniLetters.hasMatch(text) ? 'kurdistan' : 'iran';
  }
  if (_azeriLetters.hasMatch(text)) return 'azerbaidjan';
  if (_kurmanjiLetters.hasMatch(text)) return 'kurdistan';
  if (_turkishLetters.hasMatch(text)) return 'turcia';
  if (_exYuLatin.hasMatch(text) || _exYuCyrillic.hasMatch(text)) return 'bosnia';
  if (_centralAsianCyrillic.hasMatch(text)) return 'central asia';
  return null;
}

Set<String> _keywordHits(String text) {
  final hits = <String>{};
  _keywordPatterns.forEach((themeId, patterns) {
    if (patterns.any((r) => r.hasMatch(text))) hits.add(themeId);
  });
  return hits;
}

/// Alege tema pentru un playlist după titlu (cuvinte-cheie, pondere mare)
/// și după numele melodiilor (cuvinte-cheie + alfabet/diacritice, câte un
/// vot per melodie). Fără niciun semnal clar -> [kDefaultThemeId] (Grecia).
String detectThemeForPlaylist({required String title, required Iterable<String> songNames}) {
  final scores = <String, int>{};
  void add(String id, int points) => scores[id] = (scores[id] ?? 0) + points;

  final titleHits = _keywordHits(title);
  for (final id in titleHits) {
    add(id, 10);
  }
  final titleScript = _scriptSignal(title);
  if (titleScript != null) add(titleScript, 5);

  int songCount = 0;
  for (final song in songNames) {
    songCount++;
    for (final id in _keywordHits(song)) {
      add(id, 2);
    }
    final script = _scriptSignal(song);
    if (script != null) add(script, 1);
  }

  if (scores.isEmpty) return kDefaultThemeId;
  final best = scores.entries.reduce((a, b) => b.value > a.value ? b : a);

  // Fără indiciu în titlu, semnalul din melodii trebuie să acopere o parte
  // din playlist (~15%) — o singură piesă turcească într-un playlist mare
  // nu schimbă tema.
  final hasTitleSignal = titleHits.isNotEmpty || titleScript != null;
  final threshold = hasTitleSignal ? 1 : max(1, (songCount * 0.15).ceil());
  return best.value >= threshold ? best.key : kDefaultThemeId;
}
