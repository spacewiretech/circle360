import 'package:flutter/material.dart';

import '../app/assets.dart';
import '../app/theme/app_colors.dart';
import 'app_icon.dart';

/// A circular photo with the optional 12pt presence dot tucked into its lower-right.
///
/// The dot is a fixed 12pt in the design regardless of avatar size, so it is not scaled.
class Avatar extends StatelessWidget {
  const Avatar({
    super.key,
    required this.asset,
    this.size = 56,
    this.showPresence = false,
    this.ring,
  });

  final String asset;
  final double size;
  final bool showPresence;

  /// A white ring, used on the map marker so the avatar reads against the tiles.
  final Color? ring;

  @override
  Widget build(BuildContext context) {
    final photo = Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        border: ring == null ? null : Border.all(color: ring!, width: 3),
        image: DecorationImage(image: AssetImage(asset), fit: BoxFit.cover),
        boxShadow: ring == null ? null : const [AppColors.floatingShadow],
      ),
    );

    if (!showPresence) return photo;

    return SizedBox(
      width: size,
      height: size,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          photo,
          const Positioned(
            right: 0,
            bottom: 0,
            child: AppIcon(Svg.presenceDot, size: 12),
          ),
        ],
      ),
    );
  }
}
