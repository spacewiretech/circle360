import 'package:flutter/material.dart';

/// Raw palette from the Figma file. The file defines no Figma variables, so these are the
/// hex values read straight off the design nodes.
abstract final class AppColors {
  /// Primary action colour — buttons, active borders, icons.
  static const brand = Color(0xFF026BFE);

  /// Headings on white.
  static const heading = Color(0xFF0A1544);

  /// Heading variant used inside inputs and on the back-button border.
  static const headingAlt = Color(0xFF000C2B);

  /// Secondary/body copy.
  static const muted = Color(0xFF7C6C6C);

  /// Warm page background behind the onboarding sheets.
  static const onboardingBg = Color(0xFFFBF8F5);

  /// List/row card fill (blue tinted).
  static const cardBlue = Color(0xFFF9FAFE);

  /// List card fill used for the alternate row (warm tinted).
  static const cardWarm = Color(0xFFFAF8F8);

  /// Chip fill behind the dismiss action on emergency contacts.
  static const chipBlue = Color(0xFFE0ECFE);

  /// "Online" dot on avatars, and the tick on the payment-success screen.
  static const presence = Color(0xFF07B819);

  /// Payment outcome accents. Only the status screens use these — a failed charge is the one
  /// place in the app that earns a red, and it must not be mistaken for the brand blue.
  static const danger = Color(0xFFFA2600);
  static const warning = Color(0xFFFFC800);

  /// Barely-there grounds behind the success and failure screens, so the outcome reads before
  /// the copy does.
  static const successBg = Color(0xFFF7FDF9);
  static const dangerBg = Color(0xFFFFFDFC);

  /// Translucent fill behind circular back buttons sitting over the map.
  static const scrim = Color(0x3DDDDEDF);

  static const surface = Colors.white;

  /// Drop shadow shared by every element floating over the map.
  static const floatingShadow = BoxShadow(
    color: Color(0x33000000),
    offset: Offset(0, 4),
    blurRadius: 14.5,
  );
}
