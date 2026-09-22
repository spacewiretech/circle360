import 'package:flutter/material.dart';

/// Raw palette from the SunioMax Figma frames.
///
/// Separate from `AppColors` rather than layered over it: the two apps in this build share a
/// codebase, not a brand, and a colour that drifts to keep both happy is wrong in both. The
/// structure mirrors `lib/app/theme/app_colors.dart` so the two stay easy to compare.
abstract final class SxColors {
  /// Primary action colour — buttons, active borders, the selected language card.
  static const brand = Color(0xFF2C6AA2);

  /// Headings on white. Darker and cooler than Circle360's.
  static const heading = Color(0xFF0E1E3C);

  /// The green half of the wordmark, and the Voice Lock / Find Phone master toggles.
  static const accent = Color(0xFF8CC63F);

  /// Secondary and paragraph copy.
  static const muted = Color(0xFF7A7068);

  /// Page background. Barely off-white, so the cards read as raised.
  static const pageBg = Color(0xFFFAFBFD);

  /// Settings row cards.
  static const card = Color(0xFFFFFFFF);

  /// Hairline around a card, and the unselected language option.
  static const cardBorder = Color(0xFFE8ECF1);

  /// The tinted ground behind an enabled master-toggle card.
  static const enabledBg = Color(0xFFFAFDF7);

  /// Leading-icon wells on the settings rows, one per row in the design.
  static const iconBlue = Color(0xFFEAF2FA);
  static const iconGreen = Color(0xFFE9F7EC);
  static const iconPink = Color(0xFFFDEDF5);
  static const iconViolet = Color(0xFFF1EDFD);
  static const iconAmber = Color(0xFFFDF4E3);
  static const iconGrey = Color(0xFFF1F3F5);

  /// Payment outcome accents. Same two jobs as Circle360's, different hues.
  static const success = Color(0xFF12B120);
  static const danger = Color(0xFFED1C24);

  /// A struck-through reference price on the paywall.
  static const strike = Color(0xFF9AA3AD);

  static const surface = Colors.white;

  /// Drop shadow under the floating tab bar and the mic blob.
  static const floatingShadow = BoxShadow(
    color: Color(0x1A0E1E3C),
    offset: Offset(0, 4),
    blurRadius: 16,
  );
}
