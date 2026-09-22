import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// A language SunioMax is offered in.
///
/// The nine from the design, in the order the frame lists them. `code` is a BCP-47 tag, which is
/// what `SpeechRecognizer` will want in build 2 — the picker exists so that the recogniser has an
/// answer before it is ever asked, not because the UI is translated yet.
enum SxLanguage {
  english(code: 'en-IN', native: 'English', latin: 'English'),
  hindi(code: 'hi-IN', native: 'हिंदी', latin: 'Hindi'),
  telugu(code: 'te-IN', native: 'తెలుగు', latin: 'Telugu'),
  tamil(code: 'ta-IN', native: 'தமிழ்', latin: 'Tamil'),
  kannada(code: 'kn-IN', native: 'ಕನ್ನಡ', latin: 'Kanada'),
  malayalam(code: 'ml-IN', native: 'മലയാളം', latin: 'Malayalam'),
  marathi(code: 'mr-IN', native: 'मराठी', latin: 'Marathi'),
  odia(code: 'or-IN', native: 'ଓଡ଼ିଆ', latin: 'Odia'),
  bangla(code: 'bn-IN', native: 'বাংলা', latin: 'Bangla');

  const SxLanguage({
    required this.code,
    required this.native,
    required this.latin,
  });

  /// BCP-47, and the stored value. Stable — it reaches Mixpanel as `app_locale`.
  final String code;

  /// The name in its own script, which is the line the design sets largest.
  final String native;

  /// The English name beneath it. Spelled as the Figma frame spells it — "Kanada", not
  /// "Kannada" — because matching the design is the point of a copy string. The enum name and
  /// the [code] use the correct spelling, so nothing downstream inherits the typo.
  final String latin;

  static SxLanguage? parse(String? code) {
    if (code == null) return null;
    for (final language in SxLanguage.values) {
      if (language.code == code) return language;
    }
    return null;
  }
}

/// Which language the user picked, remembered across launches.
///
/// `SharedPreferences` rather than the secure store: a language is a preference, not a
/// credential. Nothing here is sent to a server — SunioMax's account lives in the same `users`
/// table as Circle360's, and the language is a device setting, not an account one.
class LanguagePreference {
  const LanguagePreference();

  static const _key = 'suniomax.language';

  /// The stored language, or null when the user has not been asked yet.
  ///
  /// Null is what puts the picker in front of them, so an unreadable store shows the picker
  /// again rather than silently guessing English.
  Future<SxLanguage?> read() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return SxLanguage.parse(prefs.getString(_key));
    } catch (error) {
      debugPrint('[language] could not read the stored language: $error');
      return null;
    }
  }

  Future<void> write(SxLanguage language) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_key, language.code);
    } catch (error) {
      // Costs the user one extra tap on the next launch. Not worth failing the step over.
      debugPrint('[language] could not store $language: $error');
    }
  }
}
