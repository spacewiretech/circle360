import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

/// A Figma-exported SVG at an explicit size.
///
/// The exports already carry their own strokes and fills, so [color] is only for the few
/// glyphs the design places on a coloured surface.
class AppIcon extends StatelessWidget {
  const AppIcon(this.asset, {super.key, this.size = 24, this.color});

  final String asset;
  final double size;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    return SvgPicture.asset(
      asset,
      width: size,
      height: size,
      colorFilter: color == null ? null : ColorFilter.mode(color!, BlendMode.srcIn),
    );
  }
}
