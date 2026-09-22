import 'package:flutter/material.dart';

import '../../data/analytics/analytics.dart';
import '../../data/analytics/analytics_events.dart';
import '../app/theme/sx_colors.dart';
import '../app/theme/sx_theme.dart';
import '../app/theme/sx_typography.dart';

/// The master switch at the top of the Voice Lock and Find Phone tabs.
///
/// Figma `13511:14745` / `13511:14662`. Wider and flatter than an [SxSettingsRow], with a tinted
/// ground when on — it is the one control on the tab that decides whether any of the rows beneath
/// it do anything.
class SxToggleCard extends StatelessWidget {
  const SxToggleCard({
    super.key,
    required this.title,
    required this.subtitle,
    required this.value,
    required this.onChanged,
    required this.analyticsId,
  });

  final String title;
  final String subtitle;
  final bool value;

  /// Null while the stored value is still loading, which disables the switch rather than
  /// showing it in a state the user did not choose.
  final ValueChanged<bool>? onChanged;

  /// Required rather than optional: this is the most consequential toggle in the app, and a
  /// generated id derived from the title would change the day the copy did.
  final String analyticsId;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 14, 12, 14),
      decoration: BoxDecoration(
        color: value ? SxColors.enabledBg : SxColors.card,
        borderRadius: SxShape.card,
        border: Border.all(
          color: value
              ? SxColors.accent.withValues(alpha: 0.45)
              : SxColors.cardBorder,
        ),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(title, style: SxText.rowTitle),
                const SizedBox(height: 2),
                Text(subtitle, style: SxText.rowSubtitle),
              ],
            ),
          ),
          Switch(
            value: value,
            activeThumbColor: Colors.white,
            activeTrackColor: SxColors.accent,
            inactiveThumbColor: Colors.white,
            trackOutlineColor: const WidgetStatePropertyAll(Colors.transparent),
            onChanged: onChanged == null
                ? null
                : (next) {
                    // Tracked here rather than in the ViewModel so the *intent* is recorded even
                    // when the write behind it fails — which is exactly the case worth seeing.
                    analytics.track(Ev.elementTapped, {
                      P.elementId: analyticsId,
                      P.label: title,
                      P.enabled: next,
                    });
                    onChanged!(next);
                  },
          ),
        ],
      ),
    );
  }
}
