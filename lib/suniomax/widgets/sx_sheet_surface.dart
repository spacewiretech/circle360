import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../app/theme/sx_colors.dart';
import '../app/theme/sx_theme.dart';
import '../app/theme/sx_typography.dart';

/// The white panel pinned to the bottom of the onboarding and paywall frames.
///
/// Mirrors `SheetSurface`. It carries the bottom safe-area padding itself so the callers do not
/// each have to remember the gesture bar.
class SxSheetSurface extends StatelessWidget {
  const SxSheetSurface({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.symmetric(horizontal: SxShape.gutter),
  });

  final Widget child;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      decoration: const BoxDecoration(
        color: SxColors.surface,
        borderRadius: SxShape.sheet,
        boxShadow: [SxColors.floatingShadow],
      ),
      child: SafeArea(
        top: false,
        child: Padding(padding: padding, child: child),
      ),
    );
  }
}

/// "By continuing you agree to our Terms of Service and Privacy Policy".
///
/// A separate widget from Circle360's `TermsFooter` because the SunioMax frames set it in two
/// shapes: a sentence on the onboarding sheets, and two links either side of a pipe on the
/// paywall. Both open the same documents.
class SxTermsFooter extends StatelessWidget {
  const SxTermsFooter({super.key, this.compact = false});

  /// The paywall variant — "Terms of Service | Privacy Policy", with no leading sentence.
  final bool compact;

  static final _terms = Uri.parse('https://loc360.app/terms');
  static final _privacy = Uri.parse('https://loc360.app/privacy');

  Future<void> _open(Uri url) async {
    // Best effort. A footer link that cannot open is not worth an error state on a screen whose
    // job is to take a payment.
    await launchUrl(
      url,
      mode: LaunchMode.externalApplication,
    ).catchError((_) => false);
  }

  @override
  Widget build(BuildContext context) {
    final link = SxText.legal.copyWith(
      decoration: TextDecoration.underline,
      fontWeight: FontWeight.w600,
    );

    if (compact) {
      return Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          GestureDetector(
            onTap: () => _open(_terms),
            child: Text('Terms of Service', style: link),
          ),
          Text('  |  ', style: SxText.legal),
          GestureDetector(
            onTap: () => _open(_privacy),
            child: Text('Privacy Policy', style: link),
          ),
        ],
      );
    }

    return Text.rich(
      TextSpan(
        style: SxText.legal,
        children: [
          const TextSpan(text: 'By continuing you agree to our '),
          TextSpan(
            text: 'Terms of Service',
            style: link,
            recognizer: _tap(() => _open(_terms)),
          ),
          const TextSpan(text: ' and '),
          TextSpan(
            text: 'Privacy Policy',
            style: link,
            recognizer: _tap(() => _open(_privacy)),
          ),
        ],
      ),
      textAlign: TextAlign.center,
    );
  }

  /// A recognizer per span. They are never disposed, which is correct here and only here: this
  /// widget lives for as long as the screen does and is rebuilt on keystrokes, so pairing each
  /// one with a `StatefulWidget` to dispose it would cost more than it saves.
  static GestureRecognizer _tap(VoidCallback onTap) =>
      TapGestureRecognizer()..onTap = onTap;
}
