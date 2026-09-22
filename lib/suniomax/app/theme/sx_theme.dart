import 'package:flutter/material.dart';

import 'sx_colors.dart';
import 'sx_typography.dart';

/// Geometry the SunioMax frames repeat. Mirrors `AppShape`, with SunioMax's own numbers —
/// the design is rounder and roomier than Circle360's.
abstract final class SxShape {
  /// Page side margin.
  static const gutter = 20.0;

  /// The white sheet over the onboarding screenshots.
  static const sheetRadius = 36.0;

  /// Settings rows, language options, the plan row.
  static const cardRadius = 16.0;

  /// Buttons and text fields, which are fully rounded in the design.
  static const controlRadius = 30.0;

  static const buttonHeight = 56.0;
  static const inputHeight = 56.0;

  /// The leading icon well on a settings row.
  static const iconWell = 40.0;

  /// The floating pill tab bar.
  static const tabBarHeight = 68.0;
  static const tabBarRadius = 34.0;

  static const card = BorderRadius.all(Radius.circular(cardRadius));
  static const control = BorderRadius.all(Radius.circular(controlRadius));
  static const sheet = BorderRadius.vertical(top: Radius.circular(sheetRadius));
}

/// SunioMax's `ThemeData`.
///
/// Light only, exactly as `buildAppTheme()` is: neither app has a dark theme, and the frames are
/// drawn on white. Kept a separate function rather than a variant of the Circle360 builder so
/// that changing one brand can never move the other.
ThemeData buildSunioTheme() {
  final base = ThemeData(
    useMaterial3: true,
    colorScheme: ColorScheme.fromSeed(
      seedColor: SxColors.brand,
      primary: SxColors.brand,
    ),
    scaffoldBackgroundColor: SxColors.pageBg,
  );

  return base.copyWith(
    textTheme: base.textTheme.copyWith(
      headlineSmall: SxText.display,
      titleMedium: SxText.rowTitle,
      bodyLarge: SxText.body,
      bodyMedium: SxText.rowSubtitle,
    ),
    splashFactory: InkRipple.splashFactory,
  );
}
