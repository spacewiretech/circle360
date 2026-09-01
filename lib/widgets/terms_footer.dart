import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';

import '../app/theme/app_colors.dart';
import '../app/theme/app_typography.dart';

/// "By continuing you agree to our Terms of Service and Privacy Policy".
///
/// [compact] renders the paywall variant — just the two links separated by a pipe.
class TermsFooter extends StatefulWidget {
  const TermsFooter({super.key, this.compact = false});

  final bool compact;

  @override
  State<TermsFooter> createState() => _TermsFooterState();
}

class _TermsFooterState extends State<TermsFooter> {
  final _recognizers = <TapGestureRecognizer>[];

  @override
  void dispose() {
    for (final recognizer in _recognizers) {
      recognizer.dispose();
    }
    super.dispose();
  }

  TapGestureRecognizer _tap(String what) {
    final recognizer = TapGestureRecognizer()
      ..onTap = () {
        if (!mounted) return;
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(SnackBar(content: Text('$what — coming soon')));
      };
    _recognizers.add(recognizer);
    return recognizer;
  }

  @override
  Widget build(BuildContext context) {
    final link = AppText.legal.copyWith(
      color: AppColors.brand,
      decoration: TextDecoration.underline,
      decorationColor: AppColors.brand,
    );

    return Text.rich(
      TextSpan(
        style: AppText.legal,
        children: [
          if (!widget.compact) const TextSpan(text: 'By continuing you agree to our '),
          TextSpan(
            text: 'Terms of Service',
            style: link,
            recognizer: _tap('Terms of Service'),
          ),
          TextSpan(text: widget.compact ? ' | ' : ' and '),
          TextSpan(
            text: 'Privacy Policy',
            style: link,
            recognizer: _tap('Privacy Policy'),
          ),
        ],
      ),
      textAlign: TextAlign.center,
    );
  }
}
