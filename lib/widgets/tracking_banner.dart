import 'package:flutter/material.dart';

import '../app/theme/app_colors.dart';
import '../app/theme/app_theme.dart';
import '../app/theme/app_typography.dart';

/// Says whether this device's location is actually going out.
///
/// The most important honesty affordance in the app. Without it "sharing is on" and "sharing
/// silently died because the OEM battery manager killed the service" look identical, and a
/// person relying on being findable would have no way to tell — which is the one failure this
/// product cannot have.
class TrackingBanner extends StatelessWidget {
  const TrackingBanner({
    super.key,
    required this.message,
    required this.onTap,
    this.actionLabel = 'Fix',
  });

  /// What is wrong. Null renders nothing — see [LocationState.problem].
  final String message;
  final VoidCallback onTap;
  final String actionLabel;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: _warningFill,
      borderRadius: AppShape.control,
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          child: Row(
            children: [
              const Icon(Icons.location_off_outlined, size: 18, color: _warningInk),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  message,
                  style: AppText.meta.copyWith(color: _warningInk),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              const SizedBox(width: 8),
              Text(
                actionLabel,
                style: AppText.chip.copyWith(color: _warningInk),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Amber rather than red: sharing being off is a state to correct, not a failure to alarm
/// about, and a red bar over the map every time someone pauses tracking would train them to
/// ignore it.
const _warningFill = Color(0xFFFFF4E0);
const _warningInk = Color(0xFF8A5A00);

/// The counterpart shown when everything is working, so "is it on?" always has an answer on
/// screen rather than only being visible when it breaks.
class TrackingOkChip extends StatelessWidget {
  const TrackingOkChip({super.key, this.label = 'Sharing your location'});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(12),
        boxShadow: const [AppColors.floatingShadow],
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 8,
            height: 8,
            decoration: const BoxDecoration(
              color: AppColors.presence,
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: 6),
          Text(label, style: AppText.chip),
        ],
      ),
    );
  }
}
