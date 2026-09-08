import 'package:flutter/material.dart';

import '../app/theme/app_colors.dart';
import '../app/theme/app_theme.dart';
import '../app/theme/app_typography.dart';
import '../data/analytics/analytics.dart';

/// The solid blue 48pt action button used at the foot of every sheet.
///
/// A disabled button keeps its shape and fades — the design has no separate disabled style,
/// so opacity is the least surprising treatment.
///
/// Every press reports itself. This is the main CTA on eight screens, so instrumenting it here
/// rather than at each call site is the difference between tap tracking that stays complete and
/// tap tracking that decays as screens are added.
class PrimaryButton extends StatelessWidget {
  const PrimaryButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.busy = false,
    this.analyticsId,
  });

  final String label;
  final VoidCallback? onPressed;
  final bool busy;

  /// Overrides the id derived from [label]. Worth setting wherever the label is interpolated or
  /// changes between states, so the button keeps one identity across every render.
  final String? analyticsId;

  @override
  Widget build(BuildContext context) {
    final enabled = onPressed != null && !busy;

    return Opacity(
      opacity: enabled ? 1 : 0.45,
      child: SizedBox(
        width: double.infinity,
        height: AppShape.buttonHeight,
        child: Material(
          color: AppColors.brand,
          borderRadius: AppShape.control,
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: enabled
                ? trackedTap(onPressed, id: analyticsId, label: label)
                : null,
            child: Center(
              child: busy
                  ? const SizedBox(
                      height: 20,
                      width: 20,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Colors.white,
                      ),
                    )
                  : Text(label, style: AppText.button),
            ),
          ),
        ),
      ),
    );
  }
}
