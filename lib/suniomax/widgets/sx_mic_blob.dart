import 'package:flutter/material.dart';

import '../app/assets.dart';
import '../app/theme/sx_colors.dart';

/// The blue blob — SunioMax's one signature visual.
///
/// It carries "Tap to speak" on the home screen, "Speak to unlock" on the lock screen and
/// "Tap to Start" when capturing a clap pattern, so it is one widget with a swappable icon and
/// label rather than three near-copies.
///
/// Falls back to a drawn approximation when `assets/suniomax/mic_blob.png` is missing. The real
/// export is an organic soft-edged shape that cannot be reproduced in Flutter primitives; the
/// fallback is a rounded squircle with the same gradient and glow, close enough to build against
/// and obviously not the real thing. See `assets/suniomax/README.md`.
class SxMicBlob extends StatelessWidget {
  const SxMicBlob({
    super.key,
    this.icon = Icons.mic_none,
    this.size = 240,
    this.onTap,
  });

  /// Drawn only by the fallback. The real artwork carries its own glyph.
  final IconData icon;

  final double size;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final content = SizedBox(
      height: size,
      width: size,
      child: Stack(
        alignment: Alignment.center,
        children: [
          Image.asset(
            SxImg.micBlob,
            height: size,
            width: size,
            fit: BoxFit.contain,
            // Only the fallback draws an icon. The real export already has the microphone and
            // its caption painted in, and overlaying a second label on top of it is what made
            // "Tap to Start" appear twice.
            errorBuilder: (context, error, stack) =>
                _DrawnBlob(size: size, icon: icon),
          ),
        ],
      ),
    );

    if (onTap == null) return content;
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: content,
    );
  }
}

/// The stand-in: a soft outer halo behind a gradient squircle.
class _DrawnBlob extends StatelessWidget {
  const _DrawnBlob({required this.size, required this.icon});

  final double size;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    return Stack(
      alignment: Alignment.center,
      children: [
        // The pale halo the real artwork has around its edge.
        Container(
          height: size * 0.97,
          width: size * 0.97,
          decoration: BoxDecoration(
            color: SxColors.brand.withValues(alpha: 0.10),
            borderRadius: BorderRadius.circular(size * 0.40),
          ),
        ),
        Container(
          height: size * 0.84,
          width: size * 0.84,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(size * 0.36),
            gradient: const LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [Color(0xFF5CA9E8), SxColors.brand],
            ),
            boxShadow: [
              BoxShadow(
                color: SxColors.brand.withValues(alpha: 0.30),
                offset: const Offset(0, 8),
                blurRadius: 24,
              ),
            ],
          ),
        ),
      ],
    );
  }
}
