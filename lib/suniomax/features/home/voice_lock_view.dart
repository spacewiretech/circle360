import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../data/analytics/analytics.dart';
import '../../../data/analytics/analytics_events.dart';
import '../../app/assets.dart';
import '../../app/router.dart';
import '../../app/theme/sx_colors.dart';
import '../../app/theme/sx_theme.dart';
import '../../app/theme/sx_typography.dart';
import '../../data/repositories/voice_lock_repository.dart';
import '../../widgets/sx_settings_row.dart';
import '../../widgets/sx_toggle_card.dart';
import '../../widgets/sx_wordmark.dart';
import 'voice_lock/voice_lock_viewmodel.dart';
import 'widgets/sx_phrase_capture_sheet.dart';
import 'widgets/sx_prompt_sheet.dart';

/// SunioMax's home: the voice lock, and nothing else.
///
/// Figma `13511:14745`. One screen rather than a tab bar — the other two tabs in the original
/// frames were a voice-command surface and a clap-to-find setting, neither of which exists, and a
/// bar with two dead tabs is worse than no bar.
///
/// Everything below the master switch dims when the lock is off. Dimmed rather than hidden: the
/// phrase and passcode rows are what a new user must fill in *before* the switch will turn on, so
/// hiding them would hide the only way forward.
class VoiceLockView extends ConsumerStatefulWidget {
  const VoiceLockView({super.key});

  @override
  ConsumerState<VoiceLockView> createState() => _VoiceLockViewState();
}

class _VoiceLockViewState extends ConsumerState<VoiceLockView>
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
    // Both grants the lock needs are Settings screens, so the user answers them outside the app
    // and comes back. Without this the switch would still be showing the refusal that sent them
    // there in the first place.
    if (state == AppLifecycleState.resumed) {
      ref.read(voiceLockViewModelProvider.notifier).refresh();
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(voiceLockViewModelProvider);
    final notifier = ref.read(voiceLockViewModelProvider.notifier);
    final settings = state.settings;

    return Scaffold(
      backgroundColor: SxColors.pageBg,
      body: SafeArea(
        child: Column(
          children: [
            const _Header(),
            Expanded(
              child: state.loading
                  ? const Center(child: CircularProgressIndicator())
                  : ListView(
                      padding: const EdgeInsets.fromLTRB(
                        SxShape.gutter,
                        8,
                        SxShape.gutter,
                        28,
                      ),
                      children: [
                        SxToggleCard(
                          title: 'Voice Lock',
                          subtitle: settings.active
                              ? 'Listening for your phrase'
                              : 'Your voice keeps your phone secure',
                          value: settings.enabled,
                          analyticsId: 'sx_voice_lock_master',
                          onChanged: state.busy
                              ? null
                              : (value) => _toggle(notifier, settings, value),
                        ),
                        if (state.busy) ...[
                          const SizedBox(height: 12),
                          const LinearProgressIndicator(minHeight: 2),
                        ],
                        if (state.error != null) ...[
                          const SizedBox(height: 12),
                          _Notice(
                            message: state.error!,
                            tone: _NoticeTone.danger,
                          ),
                        ],
                        // The switch is on but nothing is listening — almost always a permission
                        // revoked in Settings after the fact. Worth saying loudly: the user
                        // believes their phone is protected.
                        if (settings.stalled && state.error == null) ...[
                          const SizedBox(height: 12),
                          const _Notice(
                            message:
                                'Voice lock is on but not listening. Reopen the app, or '
                                'check its permissions in Settings.',
                            tone: _NoticeTone.danger,
                          ),
                        ],
                        // Two different next steps, and saying the wrong one is how a setup
                        // screen strands somebody.
                        if (!settings.enabled) ...[
                          const SizedBox(height: 12),
                          const _Notice(
                            message:
                                'Turn Voice Lock on and allow the permissions it asks '
                                'for. You can record your phrases after that.',
                            tone: _NoticeTone.info,
                          ),
                        ] else if (state.needsSetup) ...[
                          const SizedBox(height: 12),
                          _Notice(
                            message: !settings.hasPasscode
                                // The passcode is the only thing that makes locking safe, so it
                                // is the step named first once the lock is armed.
                                ? 'Set a backup passcode, then record your lock phrase. '
                                      'Without a passcode the lock will not engage.'
                                : 'Record your lock phrase and your unlock phrase to '
                                      'start using it.',
                            tone: _NoticeTone.info,
                          ),
                        ],
                        // The design's empty state. Dropped once everything is recorded, when
                        // the rows themselves are the useful thing on screen.
                        if (!settings.configured) ...[
                          const SizedBox(height: 18),
                          const _Hero(),
                        ],
                        const SizedBox(height: 16),
                        _Dimmed(
                          active: state.rowsActive,
                          child: Column(
                            children: [
                              SxSettingsRow(
                                icon: Icons.mic_none,
                                iconBackground: SxColors.iconBlue,
                                title: 'Lock Phrase',
                                subtitle:
                                    settings.phrase ??
                                    'Record what you say to lock the phone',
                                trailing: SxRowAction(
                                  label: settings.hasPhrase
                                      ? 'Change'
                                      : 'Record',
                                ),
                                analyticsId: 'sx_lock_phrase_row',
                                onTap: () =>
                                    _editLockPhrase(notifier, settings),
                              ),
                              const SizedBox(height: 10),
                              SxSettingsRow(
                                icon: Icons.lock_open_outlined,
                                iconBackground: SxColors.iconGreen,
                                title: 'Unlock Phrase',
                                subtitle:
                                    settings.unlockPhrase ??
                                    'Record what you say to unlock it',
                                trailing: SxRowAction(
                                  label: settings.hasUnlockPhrase
                                      ? 'Change'
                                      : 'Record',
                                ),
                                analyticsId: 'sx_unlock_phrase_row',
                                onTap: () =>
                                    _editUnlockPhrase(notifier, settings),
                              ),
                              const SizedBox(height: 10),
                              SxSettingsRow(
                                icon: Icons.password_outlined,
                                iconBackground: SxColors.iconViolet,
                                title: 'Backup Passcode',
                                subtitle: settings.hasPasscode
                                    ? '••••'
                                    : 'Used when your voice does not work',
                                trailing: SxRowAction(
                                  label: settings.hasPasscode
                                      ? 'Change'
                                      : 'Set',
                                ),
                                analyticsId: 'sx_passcode_row',
                                onTap: () => _editPasscode(notifier, settings),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 24),
                        const _Limits(),
                      ],
                    ),
            ),
          ],
        ),
      ),
    );
  }

  /// Turns the lock on, explaining the overlay grant before Android's Settings screen appears.
  ///
  /// Without this the switch silently throws the user into a system page with no idea what they
  /// are being asked for or why — which is how a permission gets refused, and this is the one
  /// grant the whole feature rests on: no overlay, no lock screen.
  Future<void> _toggle(
    VoiceLockViewModel notifier,
    VoiceLockSettings settings,
    bool value,
  ) async {
    if (value && !settings.permissions.overlay && !await _explainOverlay()) {
      return;
    }
    await notifier.setEnabled(value);
  }

  /// Returns whether the user agreed to be sent to Settings.
  Future<bool> _explainOverlay() async {
    final agreed = await showDialog<bool>(
      context: context,
      routeSettings: const RouteSettings(name: 'sx_overlay_explainer'),
      builder: (context) => AlertDialog(
        title: Text('Allow the lock screen', style: SxText.rowTitle),
        content: Text(
          'To cover your phone when you say your lock phrase, SunioMax needs permission to '
          'display over other apps.\n\nAndroid only grants this from its Settings screen. '
          'Find SunioMax in the list and turn it on, then come back.',
          style: SxText.rowSubtitle,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(
              'Not now',
              style: SxText.rowAction.copyWith(color: SxColors.muted),
            ),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text('Open Settings', style: SxText.rowAction),
          ),
        ],
      ),
    );
    return agreed ?? false;
  }

  Future<void> _editLockPhrase(
    VoiceLockViewModel notifier,
    VoiceLockSettings settings,
  ) async {
    final phrase = await showSxPhraseCaptureSheet(
      context,
      title: 'Lock Phrase',
      message:
          'Say the words that will lock your phone. Two or three work best — a single '
          'word is easy to mishear, and something you say in normal conversation will lock '
          'your phone when you did not mean to.',
      currentPhrase: settings.phrase,
      analyticsId: 'sx_lock_phrase_sheet',
    );
    if (phrase == null) return;
    await notifier.setPhrase(phrase);
  }

  Future<void> _editUnlockPhrase(
    VoiceLockViewModel notifier,
    VoiceLockSettings settings,
  ) async {
    final phrase = await showSxPhraseCaptureSheet(
      context,
      title: 'Unlock Phrase',
      message:
          'Say the words that will unlock it again. They must be different from your lock '
          'phrase — one phrase for both would unlock the phone the moment it heard the '
          'words that locked it.',
      currentPhrase: settings.unlockPhrase,
      analyticsId: 'sx_unlock_phrase_sheet',
    );
    if (phrase == null) return;
    await notifier.setUnlockPhrase(phrase);
  }

  Future<void> _editPasscode(
    VoiceLockViewModel notifier,
    VoiceLockSettings settings,
  ) async {
    final passcode = await showSxPromptSheet(
      context,
      title: settings.hasPasscode
          ? 'Change Backup Passcode'
          : 'Backup Passcode',
      message:
          'Four digits, used when your voice phrase does not work. Without one there is no '
          'way back into a locked phone.',
      // A stored passcode is a salted hash, so it cannot be shown back — only replaced. Saying
      // so is the difference between "already set" and "the app forgot it".
      existingNote: settings.hasPasscode
          ? 'A passcode is already set. Typing a new one replaces it.'
          : null,
      hint: settings.hasPasscode ? 'New 4 digits' : '4 digits',
      digitsOnly: true,
      maxLength: 4,
      exactLength: 4,
      analyticsId: 'sx_passcode_sheet',
    );
    if (passcode == null) return;
    await notifier.setPasscode(passcode);
  }
}

/// The illustration on the empty state.
///
/// Figma `13511:14745`. Falls back to a plain panel if the export goes missing — the whole screen
/// should not break over a picture.
class _Hero extends StatelessWidget {
  const _Hero();

  @override
  Widget build(BuildContext context) {
    return Image.asset(
      SxImg.voiceLockHero,
      height: 190,
      fit: BoxFit.contain,
      errorBuilder: (context, error, stack) => Container(
        height: 150,
        decoration: BoxDecoration(
          color: SxColors.iconBlue,
          borderRadius: SxShape.card,
        ),
        child: const Center(
          child: Icon(Icons.lock_outline, size: 52, color: SxColors.brand),
        ),
      ),
    );
  }
}

/// Fades its child and stops it responding while the lock is off.
///
/// Genuinely inert, not merely faded: `IgnorePointer` is what makes "turn Voice Lock on first"
/// true rather than a suggestion. A dimmed row that still opens is worse than either state,
/// because it teaches the user the dimming means nothing.
class _Dimmed extends StatelessWidget {
  const _Dimmed({required this.active, required this.child});

  final bool active;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      ignoring: !active,
      child: AnimatedOpacity(
        duration: const Duration(milliseconds: 220),
        opacity: active ? 1 : 0.4,
        child: child,
      ),
    );
  }
}

enum _NoticeTone { info, danger }

/// A short explanation under the switch.
class _Notice extends StatelessWidget {
  const _Notice({required this.message, required this.tone});

  final String message;
  final _NoticeTone tone;

  @override
  Widget build(BuildContext context) {
    final danger = tone == _NoticeTone.danger;
    final colour = danger ? SxColors.danger : SxColors.brand;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: colour.withValues(alpha: 0.06),
        borderRadius: SxShape.card,
        border: Border.all(color: colour.withValues(alpha: 0.30)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            danger ? Icons.error_outline : Icons.info_outline,
            size: 18,
            color: colour,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              message,
              style: SxText.rowSubtitle.copyWith(color: colour),
            ),
          ),
        ],
      ),
    );
  }
}

/// What the lock does and does not cover.
///
/// On screen rather than buried in a doc because the gap is one a user will find within a day,
/// and finding it unannounced reads as the app being broken.
class _Limits extends StatelessWidget {
  const _Limits();

  @override
  Widget build(BuildContext context) {
    return Text(
      'The lock screen stays on top of every app, and Back and Home will not dismiss it. '
      'The notification shade can still be pulled down over it — Android gives no way to '
      'block that.',
      style: SxText.legal.copyWith(color: SxColors.muted, height: 1.6),
      textAlign: TextAlign.center,
    );
  }
}

/// The wordmark and the settings gear.
class _Header extends StatelessWidget {
  const _Header();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        SxShape.gutter,
        8,
        SxShape.gutter - 6,
        4,
      ),
      child: Row(
        children: [
          const SxWordmark(height: 28),
          const Spacer(),
          IconButton(
            onPressed: () => _openSettings(context),
            icon: const Icon(Icons.settings_outlined, color: SxColors.heading),
            tooltip: 'Settings',
          ),
        ],
      ),
    );
  }

  void _openSettings(BuildContext context) {
    analytics.track(Ev.elementTapped, {
      P.elementId: 'sx_settings',
      P.label: 'Settings',
    });
    context.push(SxRoutes.settings);
  }
}
