import 'package:flutter/material.dart';

import '../../data/analytics/analytics.dart';
import '../app/theme/sx_colors.dart';
import '../app/theme/sx_theme.dart';
import '../app/theme/sx_typography.dart';

/// A card row on the Voice Lock and Find Phone tabs: icon well, title, subtitle, trailing.
///
/// Figma `13511:14745` and `13511:14662`. One widget for all of them because the frames differ
/// only in the trailing element — a "Change" link, a chevron, or a switch — and building three
/// near-identical cards is how the corner radii drift apart.
class SxSettingsRow extends StatelessWidget {
  const SxSettingsRow({
    super.key,
    required this.icon,
    required this.iconBackground,
    required this.title,
    this.subtitle,
    this.subtitleWidget,
    this.trailing,
    this.onTap,
    this.analyticsId,
  });

  final IconData icon;
  final Color iconBackground;
  final String title;
  final String? subtitle;

  /// Replaces [subtitle] when the second line is not text — the App Lock row shows the icons of
  /// the apps it covers.
  final Widget? subtitleWidget;

  final Widget? trailing;
  final VoidCallback? onTap;
  final String? analyticsId;

  @override
  Widget build(BuildContext context) {
    final second =
        subtitleWidget ??
        (subtitle == null ? null : Text(subtitle!, style: SxText.rowSubtitle));

    return Material(
      color: SxColors.card,
      borderRadius: SxShape.card,
      child: InkWell(
        onTap: trackedTap(onTap, id: analyticsId, label: title),
        borderRadius: SxShape.card,
        child: Ink(
          decoration: BoxDecoration(
            borderRadius: SxShape.card,
            border: Border.all(color: SxColors.cardBorder),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
          child: Row(
            children: [
              Container(
                height: SxShape.iconWell,
                width: SxShape.iconWell,
                decoration: BoxDecoration(
                  color: iconBackground,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(icon, size: 20, color: SxColors.heading),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(title, style: SxText.rowTitle),
                    if (second != null) ...[const SizedBox(height: 2), second],
                  ],
                ),
              ),
              if (trailing != null) ...[const SizedBox(width: 10), trailing!],
            ],
          ),
        ),
      ),
    );
  }
}

/// The blue "Change" affordance on the right of a row.
///
/// Text rather than a button because the whole row is already tappable — a second tap target
/// inside it would report two different ids for the same intent.
class SxRowAction extends StatelessWidget {
  const SxRowAction({super.key, this.label = 'Change'});

  final String label;

  @override
  Widget build(BuildContext context) => Text(label, style: SxText.rowAction);
}

/// The chevron on a row that opens another screen.
class SxRowChevron extends StatelessWidget {
  const SxRowChevron({super.key});

  @override
  Widget build(BuildContext context) =>
      const Icon(Icons.chevron_right, size: 22, color: SxColors.muted);
}
