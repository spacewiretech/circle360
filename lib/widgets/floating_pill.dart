import 'package:flutter/material.dart';

import '../app/assets.dart';
import '../app/theme/app_colors.dart';
import '../app/theme/app_typography.dart';
import 'app_icon.dart';

/// White pill floating over the map — "Emergency Contacts" on Home.
class FloatingPill extends StatelessWidget {
  const FloatingPill({
    super.key,
    required this.label,
    required this.trailing,
    this.onTap,
  });

  final String label;
  final Widget trailing;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: AppColors.surface,
      borderRadius: BorderRadius.circular(12),
      clipBehavior: Clip.antiAlias,
      elevation: 4,
      shadowColor: const Color(0x33000000),
      child: InkWell(
        onTap: onTap,
        child: Container(
          height: 44,
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(label, style: AppText.pill),
              const SizedBox(width: 8),
              trailing,
            ],
          ),
        ),
      ),
    );
  }
}

/// The 40pt circular back button that sits over the map or at the top of a sheet.
class CircleBackButton extends StatelessWidget {
  const CircleBackButton({super.key, required this.onTap, this.bordered = false});

  final VoidCallback onTap;

  /// The profile screen outlines the button; the emergency screen does not.
  final bool bordered;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: AppColors.scrim,
      shape: CircleBorder(
        side: bordered
            ? const BorderSide(color: AppColors.headingAlt)
            : BorderSide.none,
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: const SizedBox(
          width: 40,
          height: 40,
          child: Center(child: AppIcon(Svg.iconBack, size: 24)),
        ),
      ),
    );
  }
}
