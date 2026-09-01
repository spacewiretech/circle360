import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../app/theme/app_colors.dart';
import '../../../app/theme/app_typography.dart';
import '../../../widgets/brand_logo.dart';
import '../../../widgets/primary_button.dart';
import '../../../widgets/sheet_surface.dart';
import '../../../widgets/terms_footer.dart';

/// The shared frame behind the onboarding steps: warm page, white sheet pinned to the
/// bottom, logo → "Welcome to Loc360" → prompt → field → button → legal.
///
/// Figma `12310:11223`, `12310:11248`, `12310:11274` differ only in [prompt] and [field];
/// `12362:12297` (invite) additionally fills the space above the sheet with a [hero].
class OnboardingScaffold extends StatelessWidget {
  const OnboardingScaffold({
    super.key,
    required this.prompt,
    required this.field,
    required this.buttonLabel,
    required this.onContinue,
    this.busy = false,
    this.error,
    this.hero,
  });

  final String prompt;
  final Widget field;
  final String buttonLabel;
  final VoidCallback? onContinue;
  final bool busy;
  final String? error;

  /// Artwork centred on the page behind the sheet. The design lets the sheet crop its lower
  /// part, which falls out of the paint order below.
  final Widget? hero;

  /// The hero's top edge in the 412x917 design frame, kept as a ratio so it holds on any
  /// screen height.
  static const _heroTopRatio = 30 / 917;

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);

    final sheet = Column(
      children: [
        const Spacer(),
        SheetSurface(
            // The legal line runs edge to edge, so padding is applied per block rather than
            // to the whole sheet.
            padding: EdgeInsets.zero,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 34),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const SizedBox(height: 43),
                      const LogoPin(),
                      const SizedBox(height: 18),
                      const WelcomeHeading(),
                      const SizedBox(height: 12),
                      Text(prompt, style: AppText.body),
                      const SizedBox(height: 19),
                      field,
                      if (error != null) ...[
                        const SizedBox(height: 8),
                        Text(
                          error!,
                          style: AppText.meta
                              .copyWith(color: Theme.of(context).colorScheme.error),
                        ),
                      ],
                      const SizedBox(height: 15),
                      PrimaryButton(
                        label: buttonLabel,
                        onPressed: onContinue,
                        busy: busy,
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 16),
                const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 12),
                  child: Center(child: TermsFooter()),
                ),
                const SizedBox(height: 16),
              ],
            ),
        ),
      ],
    );

    return Scaffold(
      backgroundColor: AppColors.onboardingBg,
      resizeToAvoidBottomInset: true,
      body: hero == null
          ? sheet
          : Stack(
              children: [
                Positioned(
                  // Never let the artwork ride up under the status bar on a short screen.
                  top: math.max(
                    media.padding.top + 8,
                    media.size.height * _heroTopRatio,
                  ),
                  left: 0,
                  right: 0,
                  child: Center(child: hero),
                ),
                // Painted after the hero, so the opaque sheet crops it exactly as designed.
                sheet,
              ],
            ),
    );
  }
}
