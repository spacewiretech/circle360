import 'package:flutter/material.dart';

import '../app/assets.dart';
import '../app/theme/app_colors.dart';
import '../app/theme/app_theme.dart';
import '../app/theme/app_typography.dart';
import '../data/models/tracked_person.dart';
import 'action_tile.dart';
import 'app_icon.dart';
import 'avatar.dart';

/// A tracked person. Tapping the row expands it in place to reveal the four actions.
class PersonCard extends StatelessWidget {
  const PersonCard({
    super.key,
    required this.person,
    required this.expanded,
    required this.onToggle,
    required this.onAction,
    required this.onRemove,
    this.tint = AppColors.cardBlue,
  });

  final TrackedPerson person;
  final bool expanded;
  final VoidCallback onToggle;
  final void Function(PersonAction action) onAction;

  /// Ends the connection, or withdraws an invite. Offered on every card, because a person who
  /// can see your location must always be one tap from being removed.
  final VoidCallback onRemove;

  /// The design alternates the card fill between the blue and warm tints.
  final Color tint;

  /// Only a connected person has actions worth opening to; the other states have nothing to
  /// show behind the chevron, so it is hidden rather than opening an empty drawer.
  bool get _isConnected => person.status == ShareStatus.sharing;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(color: tint, borderRadius: AppShape.card),
      clipBehavior: Clip.antiAlias,
      child: AnimatedSize(
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOutCubic,
        alignment: Alignment.topCenter,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            InkWell(
              onTap: _isConnected ? onToggle : null,
              // A long-press is the only affordance the design leaves for removal, and every
              // state needs one — including an invite that was sent to a wrong number.
              onLongPress: () => _confirmRemove(context),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(15, 10, 12, 10),
                child: Row(
                  children: [
                    Avatar(
                      asset: person.avatarAsset,
                      showPresence: _isConnected && person.isOnline,
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            person.name.isEmpty ? person.phone : person.name,
                            style: AppText.title,
                          ),
                          Text(
                            person.subtitle,
                            style: AppText.meta,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ],
                      ),
                    ),
                    // One chevron asset, flipped when the card is open. Absent while there is
                    // nothing behind it to open.
                    if (_isConnected)
                      AnimatedRotation(
                        turns: expanded ? 0.5 : 0,
                        duration: const Duration(milliseconds: 220),
                        child: const AppIcon(Svg.chevronDown, size: 24),
                      )
                    else
                      const _WaitingDot(),
                  ],
                ),
              ),
            ),
            if (expanded)
              Padding(
                padding: const EdgeInsets.fromLTRB(8, 8, 8, 16),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    for (final action in PersonAction.available)
                      ActionTile(action: action, onTap: () => onAction(action)),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }

  /// Removal is mutual and cannot be undone without asking the other person again, so it is
  /// worth one confirmation.
  Future<void> _confirmRemove(BuildContext context) async {
    final who = person.name.isEmpty ? person.phone : person.name;
    final isInvite = person.status == ShareStatus.invited;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(isInvite ? 'Withdraw invite?' : 'Stop sharing with $who?'),
        content: Text(
          isInvite
              ? 'They will no longer be connected to you if they install the app.'
              : 'You will stop seeing each other. $who will need to be added again.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(isInvite ? 'Withdraw' : 'Stop sharing'),
          ),
        ],
      ),
    );

    if (confirmed == true) onRemove();
  }
}

/// Stands in for the chevron on a card that cannot expand, so the rows stay the same width.
class _WaitingDot extends StatelessWidget {
  const _WaitingDot();

  @override
  Widget build(BuildContext context) {
    return const SizedBox(
      width: 24,
      height: 24,
      child: Center(
        child: SizedBox(
          width: 8,
          height: 8,
          child: DecoratedBox(
            decoration: BoxDecoration(color: AppColors.muted, shape: BoxShape.circle),
          ),
        ),
      ),
    );
  }
}

/// The "Add Person" row that closes both the Home list and the Emergency Contacts list.
class AddPersonCard extends StatelessWidget {
  const AddPersonCard({
    super.key,
    required this.onTap,
    this.title = 'Add Person',
    this.subtitle = 'You can add up to 3 people',
  });

  final VoidCallback onTap;
  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: AppColors.cardBlue,
      borderRadius: AppShape.card,
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(15, 10, 12, 10),
          child: Row(
            children: [
              Container(
                width: AppShape.avatar,
                height: AppShape.avatar,
                decoration: const BoxDecoration(
                  color: AppColors.surface,
                  shape: BoxShape.circle,
                ),
                child: const Center(child: AppIcon(Svg.addPlus, size: 24)),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(title, style: AppText.title),
                    Text(subtitle, style: AppText.meta),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
