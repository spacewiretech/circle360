import 'package:flutter/material.dart';

import '../app/theme/app_colors.dart';
import '../app/theme/app_theme.dart';
import '../app/theme/app_typography.dart';
import '../data/models/tracked_person.dart';
import 'avatar.dart';

/// Someone has added this account and is waiting for it to share back.
///
/// Styled apart from [PersonCard] on purpose — it is the one place in the app where the user
/// grants access to their own position, so it should not look like just another row. The copy
/// says plainly what accepting does and what it does not: they see you either way is *not*
/// true here, and the card must not imply it.
class RequestCard extends StatelessWidget {
  const RequestCard({
    super.key,
    required this.person,
    required this.onAccept,
    required this.onDecline,
  });

  final TrackedPerson person;
  final VoidCallback onAccept;
  final VoidCallback onDecline;

  @override
  Widget build(BuildContext context) {
    final who = person.name.isEmpty ? person.phone : person.name;

    return Container(
      decoration: BoxDecoration(color: AppColors.chipBlue, borderRadius: AppShape.card),
      padding: const EdgeInsets.fromLTRB(15, 12, 15, 12),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Avatar(asset: person.avatarAsset),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(who, style: AppText.title),
                    Text(
                      'Wants to see your location',
                      style: AppText.meta,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Text(
            'They are already sharing theirs with you. Accept to share yours back.',
            style: AppText.meta,
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: _RequestButton(
                  label: 'Decline',
                  onPressed: onDecline,
                  filled: false,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: _RequestButton(
                  label: 'Accept',
                  onPressed: onAccept,
                  filled: true,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// A shorter, paired version of [PrimaryButton] — two of those side by side would be taller
/// than the card they sit in.
class _RequestButton extends StatelessWidget {
  const _RequestButton({
    required this.label,
    required this.onPressed,
    required this.filled,
  });

  final String label;
  final VoidCallback onPressed;
  final bool filled;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: filled ? AppColors.brand : AppColors.surface,
      borderRadius: AppShape.control,
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onPressed,
        child: SizedBox(
          height: 40,
          child: Center(
            child: Text(
              label,
              style: AppText.button.copyWith(
                fontSize: 14,
                color: filled ? AppColors.surface : AppColors.heading,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
