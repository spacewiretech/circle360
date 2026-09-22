import 'package:flutter/material.dart';

import '../../data/analytics/analytics.dart';
import '../app/theme/sx_colors.dart';
import '../app/theme/sx_theme.dart';
import '../app/theme/sx_typography.dart';

/// The full-width rounded CTA at the foot of every SunioMax screen.
///
/// Mirrors `PrimaryButton`, including the `analyticsId` discipline: the tap is reported by the
/// button itself through [trackedTap], so a screen never has to remember to instrument its own
/// CTA. Pin [analyticsId] wherever the label carries a price or a count — otherwise the id moves
/// the day the copy does, and the funnel breaks silently.
class SxPrimaryButton extends StatelessWidget {
  const SxPrimaryButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.busy = false,
    this.analyticsId,
  });

  final String label;
  final VoidCallback? onPressed;
  final bool busy;
  final String? analyticsId;

  @override
  Widget build(BuildContext context) {
    // Busy disables the button as firmly as a null handler would: the second tap on a payment
    // button is the one that costs money twice.
    final enabled = onPressed != null && !busy;

    return SizedBox(
      width: double.infinity,
      height: SxShape.buttonHeight,
      child: ElevatedButton(
        onPressed: enabled
            ? trackedTap(onPressed, id: analyticsId, label: label)
            : null,
        style: ElevatedButton.styleFrom(
          backgroundColor: SxColors.brand,
          disabledBackgroundColor: SxColors.brand.withValues(alpha: 0.4),
          foregroundColor: Colors.white,
          elevation: 0,
          shape: const RoundedRectangleBorder(borderRadius: SxShape.control),
        ),
        child: busy
            ? const SizedBox(
                height: 22,
                width: 22,
                child: CircularProgressIndicator(
                  strokeWidth: 2.2,
                  valueColor: AlwaysStoppedAnimation(Colors.white),
                ),
              )
            : Text(label, style: SxText.button),
      ),
    );
  }
}

/// The outlined variant — "Enter passcode" on the lock screen, "Cancel" on the keypad.
class SxSecondaryButton extends StatelessWidget {
  const SxSecondaryButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.analyticsId,
  });

  final String label;
  final VoidCallback? onPressed;
  final String? analyticsId;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: SxShape.buttonHeight,
      child: OutlinedButton(
        onPressed: trackedTap(onPressed, id: analyticsId, label: label),
        style: OutlinedButton.styleFrom(
          foregroundColor: SxColors.brand,
          side: const BorderSide(color: SxColors.brand, width: 1.4),
          shape: const RoundedRectangleBorder(borderRadius: SxShape.control),
          padding: const EdgeInsets.symmetric(horizontal: 44),
        ),
        child: Text(
          label,
          style: SxText.button.copyWith(color: SxColors.brand),
        ),
      ),
    );
  }
}
