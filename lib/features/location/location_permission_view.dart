import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/router.dart';
import '../../app/theme/app_colors.dart';
import '../../app/theme/app_theme.dart';
import '../../app/theme/app_typography.dart';
import '../../data/location/location_controller.dart';
import '../../location_service.dart';
import '../onboarding/widgets/onboarding_scaffold.dart';

/// Asks for location once, in the app's own words, before the OS dialog appears.
///
/// Deliberately **not a gate**. Whatever the user answers, Continue takes them to Home — a
/// refusal leaves them with a banner they can act on later, not a wall. Trapping someone on
/// this screen would cost the account without ever winning the permission, and the OS will not
/// re-prompt after a hard denial anyway.
///
/// It reuses [OnboardingScaffold] so it reads as the last step of onboarding rather than an
/// interruption after payment.
class LocationPermissionView extends ConsumerStatefulWidget {
  const LocationPermissionView({super.key});

  @override
  ConsumerState<LocationPermissionView> createState() => _LocationPermissionViewState();
}

class _LocationPermissionViewState extends ConsumerState<LocationPermissionView>
    with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // The reason this screen appeared stuck. On Android 11+ "Allow all the time" can only be
    // granted in system Settings, and the native call resolves with the *pre-change* status
    // the moment Settings opens. The status stream is fed by the tracking service, not by
    // permission changes, so nothing else here ever learns the answer — the screen sat on
    // stale state until the user tapped again. Re-ask the OS on the way back in.
    if (state == AppLifecycleState.resumed) {
      ref.read(locationControllerProvider.notifier).refresh();
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(locationControllerProvider);
    final controller = ref.read(locationControllerProvider.notifier);
    final permission = state.permission;

    void toHome() => context.go(Routes.home);

    // The primary button is the way forward the moment tracking is possible. It used to become
    // a *second* ask once foreground permission landed — "Allow all the time" — which left the
    // only route onward as a small text link most people never found. The background upgrade is
    // still offered, but as the secondary action it always was in importance.
    final (String label, VoidCallback action, String? hint, _Upgrade? upgrade) =
        switch (permission) {
      LocationPermission.notRequested || LocationPermission.denied => (
          'Turn on location',
          controller.requestPermission,
          null,
          null,
        ),
      // The OS stops showing the prompt after a hard denial, so Settings is the only route
      // left. Copy lifted from the diagnostics screen, which already got this right.
      LocationPermission.deniedForever => (
          'Open Settings',
          controller.openAppSettings,
          'Permission was permanently denied — it can only be re-enabled in Settings.',
          null,
        ),
      LocationPermission.whileInUse => (
          'Continue',
          toHome,
          Platform.isIOS
              ? 'Without "Always", sharing stops when the app is force-quit and cannot restart.'
              : 'Without background access, sharing will not resume after a reboot.',
          _Upgrade(
            label: Platform.isIOS ? 'Allow "Always"' : 'Allow all the time',
            onTap: controller.requestBackgroundPermission,
          ),
        ),
      LocationPermission.always => ('Continue', toHome, null, null),
    };

    return OnboardingScaffold(
      prompt: 'Circle360 shares your location with the people you add, so they can find you '
          'when it matters.',
      field: _Rationale(hint: hint, permission: permission, upgrade: upgrade),
      buttonLabel: label,
      busy: state.busy,
      error: state.error,
      onContinue: action,
      hero: const _LocationHero(),
    );
  }
}

/// The optional second ask, offered alongside the forward action rather than instead of it.
class _Upgrade {
  const _Upgrade({required this.label, required this.onTap});

  final String label;
  final VoidCallback onTap;
}

/// What the permission buys, and what the current answer costs.
class _Rationale extends ConsumerWidget {
  const _Rationale({required this.hint, required this.permission, this.upgrade});

  final String? hint;
  final LocationPermission permission;
  final _Upgrade? upgrade;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        const _Point(
          icon: Icons.people_outline,
          text: 'Only people you add — and who accept — can ever see where you are.',
        ),
        const SizedBox(height: 10),
        const _Point(
          icon: Icons.pause_circle_outline,
          text: 'You can pause sharing at any time from Settings.',
        ),
        if (hint != null) ...[
          const SizedBox(height: 12),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: AppColors.cardWarm,
              borderRadius: AppShape.card,
            ),
            child: Text(hint!, style: AppText.meta),
          ),
        ],
        // The background upgrade, once foreground location is in hand. Full width so it reads
        // as a real option, outlined so it never competes with the solid blue Continue above.
        if (upgrade != null) ...[
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            height: AppShape.buttonHeight,
            child: OutlinedButton(
              onPressed: upgrade!.onTap,
              style: OutlinedButton.styleFrom(
                side: const BorderSide(color: AppColors.brand),
                shape: const RoundedRectangleBorder(borderRadius: AppShape.control),
              ),
              child: Text(
                upgrade!.label,
                style: AppText.pill.copyWith(color: AppColors.brand),
              ),
            ),
          ),
        ],

        // An escape hatch only while there is nothing to continue *to*. Once permission is
        // granted the primary button says Continue, and a second link saying the same thing is
        // what made the forward action ambiguous in the first place. The user has already paid,
        // so a refusal must still never trap them here.
        if (!permission.canTrack) ...[
          const SizedBox(height: 4),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton(
              onPressed: () => context.go(Routes.home),
              style: TextButton.styleFrom(padding: EdgeInsets.zero),
              child: Text(
                'Not now',
                style: AppText.meta.copyWith(color: AppColors.brand),
              ),
            ),
          ),
        ],
      ],
    );
  }
}

class _Point extends StatelessWidget {
  const _Point({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 18, color: AppColors.brand),
        const SizedBox(width: 10),
        Expanded(child: Text(text, style: AppText.meta)),
      ],
    );
  }
}

/// No artwork exists for this step in the Figma set, so the hero is drawn from the design
/// tokens rather than shipping an asset that does not match the rest.
class _LocationHero extends StatelessWidget {
  const _LocationHero();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 132,
      height: 132,
      decoration: const BoxDecoration(
        color: AppColors.chipBlue,
        shape: BoxShape.circle,
      ),
      child: const Center(
        child: Icon(Icons.my_location, size: 56, color: AppColors.brand),
      ),
    );
  }
}
