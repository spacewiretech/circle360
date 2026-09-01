import 'package:flutter/material.dart';

import '../app/assets.dart';
import '../app/theme/app_colors.dart';
import '../app/theme/app_typography.dart';
import '../data/models/tracked_person.dart';
import 'app_icon.dart';

/// One of the four circular actions revealed when a person's card expands.
class ActionTile extends StatelessWidget {
  const ActionTile({super.key, required this.action, required this.onTap});

  final PersonAction action;
  final VoidCallback onTap;

  static const _icons = {
    PersonAction.beep: Svg.actionBeep,
    PersonAction.call: Svg.actionCall,
    PersonAction.shareLive: Svg.actionShareLive,
    PersonAction.shareCurrent: Svg.actionShareCurrent,
  };

  @override
  Widget build(BuildContext context) {
    final (top, bottom) = action.labelLines;

    return Semantics(
      button: true,
      label: action.label,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 56,
                height: 56,
                decoration: const BoxDecoration(
                  color: AppColors.surface,
                  shape: BoxShape.circle,
                  boxShadow: [
                    BoxShadow(
                      color: Color(0x1A026BFE),
                      blurRadius: 8,
                      offset: Offset(0, 2),
                    ),
                  ],
                ),
                child: Center(child: AppIcon(_icons[action]!, size: 24)),
              ),
              const SizedBox(height: 6),
              Text(top, style: AppText.tileLabel, textAlign: TextAlign.center),
              Text(bottom, style: AppText.tileLabel, textAlign: TextAlign.center),
            ],
          ),
        ),
      ),
    );
  }
}
