import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../data/analytics/analytics.dart';
import '../../../features/auth/sign_out.dart';
import '../../app/theme/sx_colors.dart';
import '../../app/theme/sx_theme.dart';
import '../../app/theme/sx_typography.dart';
import '../../data/language_preference.dart';
import '../../data/providers.dart';
import '../../widgets/sx_settings_row.dart';
import '../home/widgets/sx_prompt_sheet.dart';
import 'sx_settings_viewmodel.dart';

/// Figma `13538:15312` — Settings.
///
/// **Only the rows that do something are here.** The frame also lists a Sunio response language,
/// a command history, and a Find Phone section with clap count and sensitivity — none of which
/// exist in this build. A settings screen whose switches change nothing is worse than a shorter
/// one, because the user cannot tell which half is real.
///
/// What is here is wired end to end: the name is the account's, the language is the one the
/// recogniser uses, and Battery Usage opens the exemption that decides whether the voice lock
/// survives the night.
class SxSettingsView extends ConsumerWidget {
  const SxSettingsView({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(sxSettingsViewModelProvider);
    final language = ref.watch(selectedLanguageProvider).valueOrNull;

    return Scaffold(
      backgroundColor: SxColors.pageBg,
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(
            SxShape.gutter,
            8,
            SxShape.gutter,
            32,
          ),
          children: [
            Align(
              alignment: Alignment.centerLeft,
              child: _CircleBack(onTap: () => context.pop()),
            ),
            const SizedBox(height: 14),
            Text(
              'Settings',
              style: SxText.display,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 6),
            Text(
              'Customize your SunioMax experience',
              style: SxText.body,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 22),

            _Section(title: 'Profile'),
            SxSettingsRow(
              icon: Icons.edit_outlined,
              iconBackground: SxColors.iconGrey,
              title: 'Personal details',
              subtitle: state.name ?? 'Edit your details',
              trailing: const SxRowChevron(),
              analyticsId: 'sx_settings_name',
              onTap: () => _editName(context, ref, state.name),
            ),

            const SizedBox(height: 18),
            _Section(title: 'Sunio'),
            SxSettingsRow(
              icon: Icons.translate,
              iconBackground: SxColors.iconViolet,
              title: 'Voice Commands Language',
              subtitle: language?.latin ?? 'English',
              trailing: const SxRowChevron(),
              analyticsId: 'sx_settings_language',
              onTap: () => _pickLanguage(context, ref, language),
            ),

            const SizedBox(height: 18),
            _Section(title: 'SunioMax App'),
            SxSettingsRow(
              icon: Icons.battery_saver_outlined,
              iconBackground: SxColors.iconGreen,
              title: 'Battery Usage',
              // Not a vanity row. Android dozes the listener without this exemption, and a voice
              // lock that quietly stops hearing you overnight is the single most likely way this
              // feature disappoints somebody.
              subtitle: state.batteryOptimised
                  ? 'Battery saver may stop the voice lock listening'
                  : 'Voice lock is exempt from battery saver',
              trailing: state.batteryOptimised
                  ? const SxRowAction(label: 'Fix')
                  : const Icon(
                      Icons.check_circle,
                      size: 20,
                      color: SxColors.accent,
                    ),
              analyticsId: 'sx_settings_battery',
              onTap: ref
                  .read(sxSettingsViewModelProvider.notifier)
                  .requestBatteryExemption,
            ),
            const SizedBox(height: 10),
            SxSettingsRow(
              icon: Icons.help_outline,
              iconBackground: SxColors.iconBlue,
              title: 'Help & Support',
              subtitle: 'Get help or contact our support team.',
              trailing: const SxRowChevron(),
              analyticsId: 'sx_settings_support',
              onTap: () => _open(_support),
            ),
            const SizedBox(height: 10),
            SxSettingsRow(
              icon: Icons.info_outline,
              iconBackground: SxColors.iconAmber,
              title: 'About',
              subtitle: 'Version, privacy, T&C more',
              trailing: const SxRowChevron(),
              analyticsId: 'sx_settings_about',
              onTap: () => _showAbout(context, state.version),
            ),

            const SizedBox(height: 10),
            SxSettingsRow(
              icon: Icons.logout,
              iconBackground: SxColors.iconPink,
              title: 'Log out',
              // Named plainly, because the consequence is not obvious: the voice lock goes with
              // the account. Leaving the phrases behind would let whoever signs in next be
              // protected by this user's voice.
              subtitle: 'Signs you out and forgets your voice lock',
              trailing: const SxRowChevron(),
              analyticsId: 'sx_settings_logout',
              onTap: () => confirmSignOut(
                context,
                ref,
                source: 'sx_settings',
                message:
                    'Your lock phrase, unlock phrase and backup passcode will be erased '
                    'from this phone, and you will need to sign in with your number again.',
              ),
            ),

            const SizedBox(height: 24),
            Text(
              state.version == null ? '' : 'Version ${state.version}',
              style: SxText.rowAction,
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }

  static final _support = Uri.parse('mailto:support@spacewiretech.com');
  static final _terms = Uri.parse('https://loc360.app/terms');
  static final _privacy = Uri.parse('https://loc360.app/privacy');

  Future<void> _open(Uri url) async {
    // Best effort. A settings link that cannot open is not worth an error state.
    await launchUrl(
      url,
      mode: LaunchMode.externalApplication,
    ).catchError((_) => false);
  }

  Future<void> _editName(
    BuildContext context,
    WidgetRef ref,
    String? current,
  ) async {
    final name = await showSxPromptSheet(
      context,
      title: 'Personal details',
      message: 'The name SunioMax greets you by.',
      hint: 'Your name',
      initialValue: current,
      analyticsId: 'sx_settings_name_sheet',
    );
    if (name == null) return;
    await ref.read(sxSettingsViewModelProvider.notifier).setName(name);
  }

  Future<void> _pickLanguage(
    BuildContext context,
    WidgetRef ref,
    SxLanguage? current,
  ) async {
    final chosen = await showModalBottomSheet<SxLanguage>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      routeSettings: const RouteSettings(name: 'sx_settings_language_sheet'),
      builder: (context) => _LanguageSheet(current: current),
    );
    if (chosen == null) return;
    await ref.read(sxSettingsViewModelProvider.notifier).setLanguage(chosen);
  }

  void _showAbout(BuildContext context, String? version) {
    showDialog<void>(
      context: context,
      routeSettings: const RouteSettings(name: 'sx_settings_about_dialog'),
      builder: (context) => AlertDialog(
        title: Text('About SunioMax', style: SxText.rowTitle),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              version == null ? 'SunioMax' : 'SunioMax $version',
              style: SxText.rowSubtitle,
            ),
            const SizedBox(height: 16),
            GestureDetector(
              onTap: () => _open(_terms),
              child: Text('Terms of Service', style: SxText.rowAction),
            ),
            const SizedBox(height: 12),
            GestureDetector(
              onTap: () => _open(_privacy),
              child: Text('Privacy Policy', style: SxText.rowAction),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text('Close', style: SxText.rowAction),
          ),
        ],
      ),
    );
  }
}

/// A section heading — "Profile", "Sunio", "SunioMax App".
class _Section extends StatelessWidget {
  const _Section({required this.title});

  final String title;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(left: 4, bottom: 10),
      child: Text(title, style: SxText.rowAction.copyWith(fontSize: 15)),
    );
  }
}

/// The circular back control from the frame.
class _CircleBack extends StatelessWidget {
  const _CircleBack({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkResponse(
      onTap: trackedTap(onTap, id: 'sx_settings_back', label: 'Back'),
      radius: 26,
      child: Container(
        height: 42,
        width: 42,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          border: Border.all(color: SxColors.heading, width: 1.3),
        ),
        child: const Icon(
          Icons.chevron_left,
          size: 24,
          color: SxColors.heading,
        ),
      ),
    );
  }
}

/// The nine languages, as a sheet.
///
/// Reuses the picker's data rather than its screen: the onboarding step is a full page with a
/// continue button, and re-entering that flow from settings would be a worse way to change one
/// value than a list you tap.
class _LanguageSheet extends StatelessWidget {
  const _LanguageSheet({required this.current});

  final SxLanguage? current;

  @override
  Widget build(BuildContext context) {
    return Container(
      constraints: BoxConstraints(
        maxHeight: MediaQuery.of(context).size.height * 0.75,
      ),
      decoration: const BoxDecoration(
        color: SxColors.surface,
        borderRadius: SxShape.sheet,
      ),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 18),
            Text('Voice Commands Language', style: SxText.outcome),
            const SizedBox(height: 6),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: SxShape.gutter),
              child: Text(
                'What SunioMax listens for. Changing it does not re-record your '
                'phrases — record them again if they stop being recognised.',
                style: SxText.body,
                textAlign: TextAlign.center,
              ),
            ),
            const SizedBox(height: 12),
            Flexible(
              child: ListView(
                shrinkWrap: true,
                children: [
                  for (final language in SxLanguage.values)
                    ListTile(
                      onTap: () => Navigator.of(context).pop(language),
                      title: Text(language.native, style: SxText.rowTitle),
                      subtitle: Text(language.latin, style: SxText.rowSubtitle),
                      trailing: language == current
                          ? const Icon(
                              Icons.check_circle,
                              color: SxColors.brand,
                            )
                          : null,
                    ),
                ],
              ),
            ),
            const SizedBox(height: 12),
          ],
        ),
      ),
    );
  }
}
