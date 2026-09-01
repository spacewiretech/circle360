import 'package:flutter/material.dart';

import 'app_colors.dart';
import 'app_typography.dart';

/// Geometry the design repeats across every screen.
abstract final class AppShape {
  /// Horizontal padding inside the white sheet — 412 frame minus the 356 card width.
  static const gutter = 28.0;

  /// The sheets are 412 wide with a 56 radius on the top two corners only.
  static const sheetRadius = 56.0;

  static const cardRadius = 10.0;
  static const controlRadius = 12.0;

  static const buttonHeight = 48.0;
  static const inputHeight = 50.0;
  static const avatar = 56.0;

  static const card = BorderRadius.all(Radius.circular(cardRadius));
  static const control = BorderRadius.all(Radius.circular(controlRadius));
}

ThemeData buildAppTheme() {
  final base = ThemeData(
    useMaterial3: true,
    colorScheme: ColorScheme.fromSeed(
      seedColor: AppColors.brand,
      primary: AppColors.brand,
    ),
    scaffoldBackgroundColor: AppColors.surface,
  );

  return base.copyWith(
    textTheme: base.textTheme.copyWith(
      headlineSmall: AppText.display,
      titleMedium: AppText.title,
      bodyLarge: AppText.body,
      bodyMedium: AppText.meta,
    ),
    splashFactory: InkRipple.splashFactory,
  );
}
