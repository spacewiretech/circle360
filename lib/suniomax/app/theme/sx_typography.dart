import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import 'sx_colors.dart';

/// SunioMax type. Poppins throughout, which is where it parts company with Circle360's
/// Poppins/Inter pairing — the SunioMax frames set body copy in the same family as the headings.
///
/// Runtime `google_fonts` like the rest of the project; `pubspec.yaml` bundles no font files.
abstract final class SxText {
  /// "Just say it", "Set Your Voice Phrase", "Welcome to SunioMax".
  static TextStyle get display => GoogleFonts.poppins(
    fontSize: 28,
    fontWeight: FontWeight.w700,
    height: 1.25,
    color: SxColors.heading,
  );

  /// The blue half of a two-tone headline — "Just say **it**".
  static TextStyle get displayAccent => display.copyWith(color: SxColors.brand);

  /// "Payment Successful!", "Payment Failed".
  static TextStyle get outcome => GoogleFonts.poppins(
    fontSize: 26,
    fontWeight: FontWeight.w600,
    height: 1.25,
    color: SxColors.heading,
  );

  /// Settings row titles — "Voice Phrase", "Clap Pattern".
  static TextStyle get rowTitle => GoogleFonts.poppins(
    fontSize: 16,
    fontWeight: FontWeight.w600,
    height: 22 / 16,
    color: SxColors.heading,
  );

  /// The second line of a settings row.
  static TextStyle get rowSubtitle =>
      GoogleFonts.poppins(fontSize: 13, height: 18 / 13, color: SxColors.muted);

  /// The blue "Change" affordance on a settings row.
  static TextStyle get rowAction => GoogleFonts.poppins(
    fontSize: 14,
    fontWeight: FontWeight.w600,
    color: SxColors.brand,
  );

  /// Subtitles and paragraph copy.
  static TextStyle get body =>
      GoogleFonts.poppins(fontSize: 15, height: 22 / 15, color: SxColors.muted);

  /// A language option's native script — देवनागरी, தமிழ், ಕನ್ನಡ.
  static TextStyle get languageNative => GoogleFonts.poppins(
    fontSize: 19,
    fontWeight: FontWeight.w600,
    height: 1.3,
    color: SxColors.heading,
  );

  /// The English name beneath it.
  static TextStyle get languageLatin =>
      GoogleFonts.poppins(fontSize: 14, height: 1.3, color: SxColors.muted);

  static TextStyle get button => GoogleFonts.poppins(
    fontSize: 17,
    fontWeight: FontWeight.w600,
    color: Colors.white,
  );

  /// Text typed into a field, and the digits on the passcode keypad.
  static TextStyle get input => GoogleFonts.poppins(
    fontSize: 18,
    fontWeight: FontWeight.w500,
    color: SxColors.heading,
  );

  /// Labels under the floating tab bar.
  static TextStyle get tab => GoogleFonts.poppins(
    fontSize: 12,
    fontWeight: FontWeight.w500,
    color: SxColors.muted,
  );

  /// The plan name on the paywall.
  static TextStyle get planName => GoogleFonts.poppins(
    fontSize: 17,
    fontWeight: FontWeight.w600,
    color: SxColors.heading,
  );

  /// The price actually charged.
  static TextStyle get price => GoogleFonts.poppins(
    fontSize: 18,
    fontWeight: FontWeight.w700,
    color: SxColors.heading,
  );

  /// The crossed-out reference price beside it.
  static TextStyle get priceStrike => GoogleFonts.poppins(
    fontSize: 17,
    fontWeight: FontWeight.w500,
    color: SxColors.strike,
    decoration: TextDecoration.lineThrough,
    decorationColor: SxColors.strike,
  );

  /// Terms and privacy footer.
  static TextStyle get legal =>
      GoogleFonts.poppins(fontSize: 11, color: SxColors.heading);

  /// The clock on the lock screen — build 2, defined here so the scale stays in one file.
  static TextStyle get clock => GoogleFonts.poppins(
    fontSize: 52,
    fontWeight: FontWeight.w700,
    height: 1.1,
    color: SxColors.heading,
  );
}
