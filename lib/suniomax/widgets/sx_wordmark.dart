import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../app/assets.dart';
import '../app/theme/sx_colors.dart';

/// The SUNIOMAX lockup — blue "SUNIO", a microphone, then "MAX" reversed out of a green
/// speech bubble.
///
/// Figma `13538:15312`. It appears on the splash, on every onboarding sheet, on the paywall and
/// in the home header, which is why it is a widget rather than an `Image.asset` at six call sites.
///
/// Falls back to a drawn approximation when `assets/suniomax/wordmark.png` is missing, so the
/// whole flow is walkable before the export lands. The fallback is close enough to develop
/// against and not close enough to ship — see `assets/suniomax/README.md`.
class SxWordmark extends StatelessWidget {
  const SxWordmark({super.key, this.height = 34});

  final double height;

  @override
  Widget build(BuildContext context) {
    return Image.asset(
      SxImg.wordmark,
      height: height,
      fit: BoxFit.contain,
      errorBuilder: (context, error, stack) => _DrawnWordmark(height: height),
    );
  }
}

/// The stand-in. Built from type and a rounded rectangle rather than a vector copy of the logo:
/// approximating the real mark closely would make it harder to notice the export is still missing.
class _DrawnWordmark extends StatelessWidget {
  const _DrawnWordmark({required this.height});

  final double height;

  @override
  Widget build(BuildContext context) {
    final size = height * 0.62;

    return SizedBox(
      height: height,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Text(
            'SUNIO',
            style: GoogleFonts.poppins(
              fontSize: size,
              fontWeight: FontWeight.w800,
              height: 1,
              letterSpacing: -0.5,
              color: SxColors.brand,
            ),
          ),
          SizedBox(width: height * 0.08),
          Container(
            padding: EdgeInsets.symmetric(
              horizontal: height * 0.16,
              vertical: height * 0.09,
            ),
            decoration: BoxDecoration(
              color: SxColors.accent,
              borderRadius: BorderRadius.circular(height * 0.18),
            ),
            child: Text(
              'MAX',
              style: GoogleFonts.poppins(
                fontSize: size,
                fontWeight: FontWeight.w800,
                height: 1,
                letterSpacing: -0.5,
                color: Colors.white,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
