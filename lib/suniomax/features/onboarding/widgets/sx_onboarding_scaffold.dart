import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../../data/analytics/analytics.dart';
import '../../../../data/analytics/analytics_events.dart';
import '../../../app/theme/sx_colors.dart';
import '../../../app/theme/sx_theme.dart';
import '../../../app/theme/sx_typography.dart';
import '../../../data/onboarding_audio.dart';
import '../../../widgets/sx_audio_button.dart';
import '../../../widgets/sx_primary_button.dart';
import '../../../widgets/sx_sheet_surface.dart';
import '../../../widgets/sx_wordmark.dart';

/// The frame behind the three SunioMax onboarding steps: a backdrop, then a white sheet over the
/// lower part holding logo → "Welcome to SunioMax" → prompt → field → button → legal.
///
/// Figma `13511:14622`, `13511:14662`, `13511:14645` differ only in [prompt] and [field].
///
/// The design puts a screenshot of the app itself behind the sheet, inside a phone frame. Those
/// exports are not in the repo (see `assets/suniomax/README.md`), so the backdrop is a soft
/// branded wash until they land — close enough in weight and colour that the sheet reads the same,
/// and obviously not the real thing.
///
/// Like `OnboardingScaffold`, it emits `Error Shown` itself when [error] changes, so the five
/// screens sharing it get that instrumentation without each remembering to add it.
class SxOnboardingScaffold extends StatefulWidget {
  const SxOnboardingScaffold({
    super.key,
    required this.prompt,
    required this.field,
    required this.buttonLabel,
    required this.onContinue,
    required this.analyticsId,
    required this.backdrop,
    required this.audioClip,
    this.busy = false,
    this.error,
    this.footer,
  });

  final String prompt;
  final Widget field;
  final String buttonLabel;
  final VoidCallback? onContinue;

  /// Required rather than optional: every step labels its button `continue`, so a derived id
  /// would report all three as the same tap.
  final String analyticsId;

  final bool busy;
  final String? error;

  /// An extra control between the field and the button — the OTP step's resend.
  final Widget? footer;

  /// The device mockup behind the sheet. One per step, so walking through onboarding shows three
  /// different pieces of the app rather than the same picture three times.
  final String backdrop;

  /// The spoken prompt for this step, and its control in the top-left corner.
  ///
  /// Required, not optional: all three steps have one, and a default would let a fourth step be
  /// added silently without a voice-over — which is exactly the kind of gap nobody notices,
  /// because a missing clip makes no sound and shows no control.
  final SxAudioClip audioClip;

  @override
  State<SxOnboardingScaffold> createState() => _SxOnboardingScaffoldState();
}

class _SxOnboardingScaffoldState extends State<SxOnboardingScaffold> {
  @override
  void didUpdateWidget(SxOnboardingScaffold oldWidget) {
    super.didUpdateWidget(oldWidget);

    // Only on a change: this rebuilds on every keystroke while the error text stays put, and what
    // the user was actually shown is the thing worth counting.
    final error = widget.error;
    if (error != null && error != oldWidget.error) {
      analytics.track(Ev.errorShown, {
        P.message: error,
        P.source: widget.analyticsId,
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: SxColors.pageBg,
      resizeToAvoidBottomInset: true,
      body: Stack(
        children: [
          Positioned.fill(child: _Backdrop(image: widget.backdrop)),
          Column(
            children: [
              const Spacer(),
              SxSheetSurface(
                padding: EdgeInsets.zero,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const SizedBox(height: 28),
                    const SxWordmark(height: 32),
                    const SizedBox(height: 20),
                    Text('Welcome to SunioMax', style: SxText.display),
                    const SizedBox(height: 6),
                    Text(widget.prompt, style: SxText.body),
                    const SizedBox(height: 22),
                    Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: SxShape.gutter,
                      ),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          widget.field,
                          if (widget.error != null) ...[
                            const SizedBox(height: 10),
                            Text(
                              widget.error!,
                              style: SxText.rowSubtitle.copyWith(
                                color: SxColors.danger,
                              ),
                              textAlign: TextAlign.center,
                            ),
                          ],
                          ?widget.footer,
                          const SizedBox(height: 18),
                          SxPrimaryButton(
                            label: widget.buttonLabel,
                            analyticsId: widget.analyticsId,
                            busy: widget.busy,
                            onPressed: widget.onContinue,
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 14),
                    const Padding(
                      padding: EdgeInsets.symmetric(horizontal: 16),
                      child: SxTermsFooter(),
                    ),
                    const SizedBox(height: 14),
                  ],
                ),
              ),
            ],
          ),
          // Last in the stack so it sits over the backdrop, and top-left so it is the first thing
          // reached rather than something to hunt for. Inside a SafeArea because the backdrop runs
          // under the status bar and this must not.
          Positioned(
            top: 0,
            left: SxShape.gutter,
            // `bottom: false` because this child is unconstrained downward: the bottom inset would
            // only pad empty space, and it changes when the keyboard opens.
            child: SafeArea(
              bottom: false,
              child: SxAudioButton(clip: widget.audioClip),
            ),
          ),
        ],
      ),
    );
  }
}

/// The artwork behind the sheet.
///
/// The same shape as Circle360's `OnboardingScaffold`: a soft page, one piece of art centred
/// above the sheet, and the opaque sheet cropping its lower edge. The design puts a screenshot of
/// the app itself there, which is exactly what these exports are.
class _Backdrop extends StatelessWidget {
  const _Backdrop({required this.image});

  final String image;

  /// The art's top edge as a ratio of screen height, so it holds on any handset — the same
  /// technique, and roughly the same value, as `OnboardingScaffold._heroTopRatio`.
  static const _topRatio = 30 / 917;

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);

    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [SxColors.brand.withValues(alpha: 0.07), SxColors.pageBg],
        ),
      ),
      child: Stack(
        children: [
          Positioned(
            // Never let the art ride up under the status bar on a short screen.
            top: math.max(media.padding.top + 8, media.size.height * _topRatio),
            left: 0,
            right: 0,
            child: Center(
              child: Image.asset(
                image,
                // Sized to the screen rather than fixed, so the mockup keeps the same proportion
                // of the page on a tall phone as on a short one.
                width: media.size.width * 0.72,
                fit: BoxFit.fitWidth,
                alignment: Alignment.topCenter,
                // A missing export must not take onboarding down — the sheet is the screen.
                errorBuilder: (context, error, stack) =>
                    const SizedBox.shrink(),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
