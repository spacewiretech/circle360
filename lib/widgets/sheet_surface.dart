import 'package:flutter/material.dart';

import '../app/theme/app_colors.dart';
import '../app/theme/app_theme.dart';

/// The white panel every screen sits on: full width, pinned to the bottom, 56pt radius on the
/// top corners only.
class SheetSurface extends StatelessWidget {
  const SheetSurface({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.symmetric(horizontal: AppShape.gutter),
  });

  final Widget child;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      decoration: const BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.vertical(top: Radius.circular(AppShape.sheetRadius)),
      ),
      clipBehavior: Clip.antiAlias,
      child: SafeArea(
        top: false,
        child: Padding(padding: padding, child: child),
      ),
    );
  }
}

/// A [SheetSurface] the user can drag up over the map, used on Home.
///
/// [builder] receives the scroll controller the sheet needs to hand to its scrollable, so the
/// list and the sheet drag as one gesture.
///
/// Snapping is deliberately off: the sheet's content resizes when a card expands, and the
/// snap simulation reacts to that by collapsing the sheet to its minimum.
class DraggableSheetSurface extends StatelessWidget {
  const DraggableSheetSurface({
    super.key,
    required this.builder,
    this.controller,
    this.initialSize = 0.58,
    this.minSize = 0.36,
    this.maxSize = 0.92,
  });

  final Widget Function(BuildContext context, ScrollController controller) builder;
  final DraggableScrollableController? controller;
  final double initialSize;
  final double minSize;
  final double maxSize;

  @override
  Widget build(BuildContext context) {
    return DraggableScrollableSheet(
      controller: controller,
      initialChildSize: initialSize,
      minChildSize: minSize,
      maxChildSize: maxSize,
      builder: (context, controller) {
        return Container(
          decoration: const BoxDecoration(
            color: AppColors.surface,
            borderRadius:
                BorderRadius.vertical(top: Radius.circular(AppShape.sheetRadius)),
            boxShadow: [AppColors.floatingShadow],
          ),
          clipBehavior: Clip.antiAlias,
          child: builder(context, controller),
        );
      },
    );
  }
}
