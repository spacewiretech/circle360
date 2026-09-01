import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import 'app_colors.dart';

/// Poppins carries headings, labels and buttons; Inter carries body copy — as in the design.
abstract final class AppText {
  /// Screen titles — "People You're Tracking", "My Profile".
  static TextStyle get display => GoogleFonts.poppins(
        fontSize: 24,
        fontWeight: FontWeight.w600,
        height: 1.2,
        color: AppColors.heading,
      );

  /// "Welcome to" — same size as [display] but a lighter weight.
  static TextStyle get welcome => GoogleFonts.poppins(
        fontSize: 24,
        fontWeight: FontWeight.w500,
        height: 1.2,
        color: AppColors.heading,
      );

  /// Row and card titles — a person's name, a settings row.
  static TextStyle get title => GoogleFonts.poppins(
        fontSize: 16,
        fontWeight: FontWeight.w500,
        height: 22 / 16,
        color: Colors.black,
      );

  /// Settings-style rows use the same size in the heading colour.
  static TextStyle get rowLabel => GoogleFonts.poppins(
        fontSize: 16,
        height: 22 / 16,
        color: AppColors.heading,
      );

  /// Two-line labels under the circular action tiles.
  static TextStyle get tileLabel => GoogleFonts.poppins(
        fontSize: 11,
        fontWeight: FontWeight.w500,
        height: 1.25,
        color: Colors.black,
      );

  /// Floating pill over the map.
  static TextStyle get pill => GoogleFonts.poppins(
        fontSize: 14,
        fontWeight: FontWeight.w500,
        color: AppColors.heading,
      );

  /// Place chip over the map.
  static TextStyle get chip => GoogleFonts.poppins(
        fontSize: 12,
        fontWeight: FontWeight.w500,
        color: AppColors.brand,
      );

  static TextStyle get button => GoogleFonts.poppins(
        fontSize: 16,
        fontWeight: FontWeight.w700,
        color: Colors.white,
      );

  /// Subtitles and paragraph copy.
  static TextStyle get body => GoogleFonts.inter(
        fontSize: 16,
        height: 22 / 16,
        color: AppColors.muted,
      );

  /// "2.4 km away • Updated now".
  static TextStyle get meta => GoogleFonts.inter(
        fontSize: 14,
        height: 22 / 14,
        color: AppColors.muted,
      );

  /// Text typed into a field.
  static TextStyle get input => GoogleFonts.inter(
        fontSize: 18,
        fontWeight: FontWeight.w500,
        color: AppColors.headingAlt,
      );

  /// Terms and privacy footer.
  static TextStyle get legal => GoogleFonts.inter(
        fontSize: 10,
        color: AppColors.headingAlt,
      );

  static TextStyle get price => GoogleFonts.poppins(
        fontSize: 18,
        fontWeight: FontWeight.w600,
        color: AppColors.heading,
      );
}
