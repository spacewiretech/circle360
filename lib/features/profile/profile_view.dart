import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/assets.dart';
import '../../app/router.dart';
import '../../app/theme/app_colors.dart';
import '../../app/theme/app_theme.dart';
import '../../app/theme/app_typography.dart';
import '../../data/fake/fake_session.dart';
import '../../widgets/app_icon.dart';
import '../../widgets/floating_pill.dart';
import '../../widgets/map_background.dart';
import '../auth/sign_out.dart';
import 'profile_viewmodel.dart';

/// Figma `12352:11678` — avatar straddling the sheet edge, three navigation rows.
class ProfileView extends ConsumerWidget {
  const ProfileView({super.key});

  static const _avatarSize = 110.0;

  void _todo(BuildContext context, String what) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text('$what — coming soon')));
  }

  /// The sheet edge sits 236/917 down the Figma frame; keeping it proportional puts the
  /// avatar in the same place on every screen size.
  static const _sheetTopRatio = 236 / 917;

  /// How far the avatar rises above the sheet edge in the design (236 - 152).
  static const _avatarOverlap = 84.0;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final user = ref.watch(profileViewModelProvider).valueOrNull;
    final sheetTop = MediaQuery.sizeOf(context).height * _sheetTopRatio;

    return Scaffold(
      // Every child below is positioned, so the Stack needs to be told to fill the screen.
      body: SizedBox.expand(
        child: Stack(
          children: [
            const Positioned.fill(child: MapBackground(center: FakeSession.home)),
            // The sheet stops short of the top so the map and avatar show through.
            Positioned.fill(
              top: sheetTop,
              child: Container(
                decoration: const BoxDecoration(
                  color: AppColors.surface,
                  borderRadius: BorderRadius.vertical(
                    top: Radius.circular(AppShape.sheetRadius),
                  ),
                ),
                child: SafeArea(
                  top: false,
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(
                      AppShape.gutter,
                      81,
                      AppShape.gutter,
                      AppShape.gutter,
                    ),
                    child: Column(
                      children: [
                        _ProfileRow(
                          icon: const AppIcon(Svg.iconEdit, size: 24),
                          label: 'Edit Your Details',
                          onTap: () => _todo(context, 'Edit Your Details'),
                        ),
                        const SizedBox(height: 9),
                        _ProfileRow(
                          icon: const AppIcon(Svg.iconFamily, size: 24),
                          label: 'My family',
                          onTap: () => context.pop(),
                        ),
                        const SizedBox(height: 9),
                        _ProfileRow(
                          icon: const AppIcon(Svg.iconSettings, size: 24),
                          label: 'Settings',
                          onTap: () => context.push(Routes.settings),
                        ),
                        const SizedBox(height: 9),
                        // The only way out of the app, and the only red in it outside the
                        // payment screens — a row that ends the session should not look like
                        // three rows that merely navigate.
                        _ProfileRow(
                          icon: const Icon(
                            Icons.logout,
                            size: 24,
                            color: AppColors.danger,
                          ),
                          label: 'Log out',
                          tint: AppColors.danger,
                          showChevron: false,
                          onTap: () => confirmSignOut(context, ref, source: 'profile'),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
            SafeArea(
              bottom: false,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(19, 13, 19, 0),
                child: Row(
                  children: [
                    CircleBackButton(onTap: () => context.pop(), bordered: true),
                    Expanded(
                      child: Text(
                        'My Profile',
                        style: AppText.display,
                        textAlign: TextAlign.center,
                      ),
                    ),
                    const SizedBox(width: 40),
                  ],
                ),
              ),
            ),
            Positioned(
              top: sheetTop - _avatarOverlap,
              left: 0,
              right: 0,
              child: Center(
                child: _EditableAvatar(
                  asset: user?.avatarAsset ?? Img.avatarMeLarge,
                  size: _avatarSize,
                  onTap: () => _todo(context, 'Change photo'),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _EditableAvatar extends StatelessWidget {
  const _EditableAvatar({required this.asset, required this.size, required this.onTap});

  final String asset;
  final double size;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: size + 20,
      height: size + 20,
      child: Stack(
        children: [
          Positioned(
            left: 10,
            top: 10,
            child: Container(
              width: size,
              height: size,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(color: AppColors.surface, width: 4),
                image: DecorationImage(image: AssetImage(asset), fit: BoxFit.cover),
              ),
            ),
          ),
          Positioned(
            left: 85,
            top: 94,
            child: Material(
              color: AppColors.brand,
              borderRadius: BorderRadius.circular(16),
              clipBehavior: Clip.antiAlias,
              child: InkWell(
                onTap: onTap,
                // The export is already a white body with a blue lens, drawn for this badge —
                // tinting it would flatten the lens away.
                child: const SizedBox(
                  width: 32,
                  height: 32,
                  child: Center(child: AppIcon(Svg.iconCamera, size: 20)),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// One 54pt navigation row: icon, label, chevron.
class _ProfileRow extends StatelessWidget {
  const _ProfileRow({
    required this.icon,
    required this.label,
    required this.onTap,
    this.tint,
    this.showChevron = true,
  });

  /// A widget rather than an SVG asset path: every row in the Figma set has an export, but the
  /// sign-out row does not, and a Material glyph is better than inventing one.
  final Widget icon;
  final String label;
  final VoidCallback onTap;

  /// Recolours the label. Only sign-out sets it — see [AppColors.danger].
  final Color? tint;

  /// A chevron promises forward navigation, which sign-out does not offer.
  final bool showChevron;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: AppColors.cardBlue,
      borderRadius: AppShape.card,
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Container(
          height: 54,
          padding: const EdgeInsets.symmetric(horizontal: 15),
          child: Row(
            children: [
              icon,
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  label,
                  style: tint == null
                      ? AppText.rowLabel
                      : AppText.rowLabel.copyWith(color: tint),
                ),
              ),
              // The design reuses the down chevron rotated a quarter turn.
              if (showChevron)
                const RotatedBox(quarterTurns: 3, child: AppIcon(Svg.chevron, size: 24)),
            ],
          ),
        ),
      ),
    );
  }
}
