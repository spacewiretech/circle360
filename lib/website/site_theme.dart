import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../app/theme/app_colors.dart';

/// Where the layout changes shape. Below [Breaks.mobile] everything is one column; between
/// the two the grids halve; above [Breaks.tablet] the hero splits in two.
abstract final class Breaks {
  static const mobile = 720.0;
  static const tablet = 1024.0;
}

abstract final class SiteShape {
  /// Content never runs wider than this, however wide the window gets.
  static const maxWidth = 1120.0;

  static const gutter = 24.0;
  static const gutterMobile = 20.0;

  /// Height of the sticky nav bar, and the offset in-page anchors have to clear.
  static const navHeight = 72.0;

  static const cardRadius = BorderRadius.all(Radius.circular(20));
  static const pillRadius = BorderRadius.all(Radius.circular(999));
}

bool isMobile(BuildContext context) => MediaQuery.sizeOf(context).width < Breaks.mobile;

bool isDesktop(BuildContext context) => MediaQuery.sizeOf(context).width >= Breaks.tablet;

/// How many columns a card grid gets at this width: 4 / 2 / 1.
int gridColumns(BuildContext context, {int max = 4}) {
  final width = MediaQuery.sizeOf(context).width;
  if (width < Breaks.mobile) return 1;
  if (width < Breaks.tablet) return max >= 4 ? 2 : max;
  return max;
}

/// Extra palette the site needs and the app does not — the app never renders a dark band or
/// a hairline divider, so these are not in [AppColors].
abstract final class SiteColors {
  /// Deep navy band behind the closing call to action.
  static const ink = Color(0xFF061033);

  /// Section ground that separates a band from the white above it.
  static const tint = Color(0xFFF6F9FF);

  static const border = Color(0xFFE6EAF2);

  /// Footer body copy on [ink].
  static const onInkMuted = Color(0xFFA9B4D0);

  /// The brand blue lifted enough to read on [ink]. `AppColors.brand` is tuned for white.
  static const brandOnInk = Color(0xFF4D9BFF);
}

/// Web-scale type. The app's [AppText] tops out at 24px for a phone sheet; a landing page
/// hero needs more than double that, so the site keeps its own ramp on the same two families
/// — Poppins for headings, Inter for body.
abstract final class SiteText {
  static TextStyle hero(BuildContext context) => GoogleFonts.poppins(
        fontSize: isMobile(context) ? 36 : (isDesktop(context) ? 56 : 44),
        fontWeight: FontWeight.w700,
        height: 1.12,
        letterSpacing: -1.2,
        color: AppColors.heading,
      );

  static TextStyle heroSub(BuildContext context) => GoogleFonts.inter(
        fontSize: isMobile(context) ? 16 : 19,
        height: 1.6,
        color: AppColors.muted,
      );

  /// Section headings — "Why families choose Circle360".
  static TextStyle section(BuildContext context) => GoogleFonts.poppins(
        fontSize: isMobile(context) ? 27 : 38,
        fontWeight: FontWeight.w600,
        height: 1.22,
        letterSpacing: -0.6,
        color: AppColors.heading,
      );

  /// The line under a section heading.
  static TextStyle sectionSub(BuildContext context) => GoogleFonts.inter(
        fontSize: isMobile(context) ? 15 : 17,
        height: 1.6,
        color: AppColors.muted,
      );

  static TextStyle cardTitle(BuildContext context) => GoogleFonts.poppins(
        fontSize: 18,
        fontWeight: FontWeight.w600,
        height: 1.35,
        color: AppColors.heading,
      );

  static TextStyle cardBody(BuildContext context) => GoogleFonts.inter(
        fontSize: 15,
        height: 1.62,
        color: AppColors.muted,
      );

  /// Long-form policy paragraphs. Slightly looser than [cardBody] — these pages are read,
  /// not scanned.
  static TextStyle prose(BuildContext context) => GoogleFonts.inter(
        fontSize: 15.5,
        height: 1.78,
        color: const Color(0xFF454F6B),
      );

  static TextStyle policyHeading(BuildContext context) => GoogleFonts.poppins(
        fontSize: isMobile(context) ? 19 : 21,
        fontWeight: FontWeight.w600,
        height: 1.35,
        color: AppColors.heading,
      );

  static TextStyle navLink = GoogleFonts.inter(
    fontSize: 15,
    fontWeight: FontWeight.w500,
    color: AppColors.heading,
  );

  static TextStyle eyebrow = GoogleFonts.inter(
    fontSize: 12.5,
    fontWeight: FontWeight.w600,
    letterSpacing: 0.9,
    color: AppColors.brand,
  );

  static TextStyle footerLink = GoogleFonts.inter(
    fontSize: 14.5,
    height: 2.0,
    color: SiteColors.onInkMuted,
  );

  static TextStyle footerHeading = GoogleFonts.poppins(
    fontSize: 14,
    fontWeight: FontWeight.w600,
    letterSpacing: 0.4,
    color: Colors.white,
  );
}

ThemeData buildSiteTheme() {
  final base = ThemeData(
    useMaterial3: true,
    colorScheme: ColorScheme.fromSeed(
      seedColor: AppColors.brand,
      primary: AppColors.brand,
    ),
    scaffoldBackgroundColor: AppColors.surface,
  );

  return base.copyWith(
    // A landing page is read with a mouse; the phone app's ink splash reads as a misfire here.
    splashFactory: NoSplash.splashFactory,
    dividerTheme: const DividerThemeData(color: SiteColors.border, thickness: 1, space: 1),
  );
}
