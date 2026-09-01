import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/router.dart';
import '../../app/theme/app_colors.dart';
import '../../app/theme/app_theme.dart';
import '../../app/theme/app_typography.dart';
import '../../data/location/location_controller.dart';
import '../../data/providers.dart';
import '../../location_service.dart';

/// Not in the Figma set — a plain list that hosts the entries the design implies, and the
/// door to the tracking diagnostics screen.
class SettingsView extends ConsumerWidget {
  const SettingsView({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: AppColors.surface,
        surfaceTintColor: Colors.transparent,
        title: Text('Settings', style: AppText.display.copyWith(fontSize: 20)),
      ),
      body: ListView(
        padding: const EdgeInsets.all(AppShape.gutter),
        children: [
          const _SharingToggle(),
          const SizedBox(height: 9),
          _SettingsRow(
            label: 'Tracking diagnostics',
            hint: 'Permissions, last fix and upload counters',
            onTap: () => context.push(Routes.diagnostics),
          ),
          const SizedBox(height: 9),
          _SettingsRow(
            label: 'Notifications',
            hint: 'Coming soon',
            onTap: null,
          ),
          const SizedBox(height: 9),
          _SettingsRow(
            label: 'Sign out',
            hint: 'Stops sharing, clears the local session and restarts onboarding',
            onTap: () async {
              // Stop the native tracker and drop its copy of the token first. Signing out
              // while the service kept uploading would leave the previous user broadcasting
              // from a handset they have already handed back.
              await ref
                  .read(locationControllerProvider.notifier)
                  .stopSharing(clearCredential: true);
              await ref.read(authRepositoryProvider).signOut();
              if (context.mounted) context.go(Routes.splash);
            },
          ),
        ],
      ),
    );
  }
}

/// The off switch.
///
/// A location app without one is not shippable — Play Store's background-location review asks
/// for it by name, and more to the point someone who cannot stop sharing will uninstall
/// instead.
class _SharingToggle extends ConsumerWidget {
  const _SharingToggle();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(locationControllerProvider);
    final controller = ref.read(locationControllerProvider.notifier);

    final hint = state.problem ??
        'The people you have connected with can see where you are';

    return Material(
      color: AppColors.cardBlue,
      borderRadius: AppShape.card,
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(15, 8, 8, 8),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Share my location', style: AppText.rowLabel),
                  Text(hint, style: AppText.meta),
                ],
              ),
            ),
            Switch(
              value: state.isLive,
              // Nothing to toggle mid-flight, and a permission that can only be changed in
              // Settings must route there rather than silently doing nothing.
              onChanged: state.busy
                  ? null
                  : (wanted) {
                      if (!wanted) {
                        controller.stopSharing();
                      } else if (state.permission == LocationPermission.deniedForever) {
                        controller.openAppSettings();
                      } else {
                        controller.startSharing();
                      }
                    },
            ),
          ],
        ),
      ),
    );
  }
}

class _SettingsRow extends StatelessWidget {
  const _SettingsRow({required this.label, required this.hint, required this.onTap});

  final String label;
  final String hint;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return Opacity(
      opacity: onTap == null ? 0.5 : 1,
      child: Material(
        color: AppColors.cardBlue,
        borderRadius: AppShape.card,
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label, style: AppText.rowLabel),
                Text(hint, style: AppText.meta),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
