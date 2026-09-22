import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/analytics/analytics.dart';
import '../../data/analytics/analytics_events.dart';
import '../../data/providers.dart';
import '../app/theme/sx_colors.dart';
import '../data/onboarding_audio.dart';
import '../data/providers.dart';

/// The spoken prompt on a SunioMax onboarding screen, and the one control over it.
///
/// Self-contained on purpose: a screen adds it and gets the clip, the autoplay, the mute and the
/// teardown, or — when its `app_config` row is blank — gets nothing at all and looks exactly as it
/// did before this existed. That is the normal state for an unrecorded clip, so it must be the
/// quiet one: no placeholder, no disabled button, no apology.
///
/// Autoplays, unmuted. The point of a voice-over for users who do not read the screen comfortably
/// is that they hear it without first finding a control; a play button they have to notice is the
/// same barrier as the text. The mute is [audioMutedProvider] — app-wide and remembered — so a
/// user who says no once is not asked again on the next screen or the next launch.
///
/// The playback itself lives in [OnboardingAudioController], not here. `context.push` leaves the
/// phone screen mounted beneath the OTP screen, so a player owned by this widget and disposed with
/// it would play two clips at once.
class SxAudioButton extends ConsumerStatefulWidget {
  const SxAudioButton({super.key, required this.clip});

  final SxAudioClip clip;

  @override
  ConsumerState<SxAudioButton> createState() => _SxAudioButtonState();
}

class _SxAudioButtonState extends ConsumerState<SxAudioButton>
    with WidgetsBindingObserver {
  /// The URL this widget has already asked the controller to play, so a rebuild — a keystroke in
  /// the field below, an error appearing — does not restart a clip mid-sentence. The controller
  /// guards this too; keeping it here as well means the common case never reaches it.
  String _playing = '';

  /// Resolved in [initState] rather than lazily, and held rather than read in [dispose].
  ///
  /// The controller is an app-lifetime `Provider`, so the reference stays good. Resolving it
  /// eagerly is what matters: a screen whose row is blank returns early from `build` and never
  /// touches this, so a lazy initialiser would fire its `ref.read` for the first time *during*
  /// `dispose` — reaching for `ref` while the element is being torn down.
  late final OnboardingAudioController _audio;

  @override
  void initState() {
    super.initState();
    _audio = ref.read(onboardingAudioControllerProvider);
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    // Only if this screen still owns the clip. On the way *forward* the phone screen is still
    // mounted under the OTP screen and this never runs; on the way back it does, and by then the
    // OTP clip may be playing — stopping it would cut off a clip this screen does not own.
    _audio.stopIfCurrent(widget.clip);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // `video_player`'s own observer only handles `paused`. On iOS the control centre and the app
    // switcher stop at `inactive` and never reach it, and a voice carrying on over either is worse
    // than a promo doing the same — this is speech the user is meant to follow.
    if (state != AppLifecycleState.resumed) _audio.pauseForBackground();
  }

  /// Asks the controller for [url], once. Scheduled out of `build` because it is asynchronous and
  /// starts a player, neither of which belongs inside a build pass.
  void _start(String url) {
    if (url == _playing) return;
    _playing = url;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _audio.play(widget.clip, url);
    });
  }

  @override
  Widget build(BuildContext context) {
    // `valueOrNull`, not a `when`: the config resolves from a six-hour disk cache and is normally
    // there on the first build, and the honest answer while it is not is "no clip yet" — which is
    // the same empty box a blank row gets. A spinner here would announce a feature that may not
    // exist on this screen at all.
    final config = ref.watch(appConfigProvider).valueOrNull;
    final url = config == null ? '' : audioUrlFor(widget.clip, config);

    // No row, a blank row, or an `http://` row that no device would play. The screen keeps the
    // shape it had before this feature.
    if (url.isEmpty) return const SizedBox.shrink();

    final muted = ref.watch(audioMutedProvider);
    _start(url);

    return Semantics(
      button: true,
      label: muted
          ? 'Play the spoken instructions'
          : 'Mute the spoken instructions',
      child: Material(
        color: SxColors.iconBlue,
        shape: const CircleBorder(),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: trackedTap(
            () => ref.read(audioMutedProvider.notifier).toggle(),
            id: 'sx_onboarding_audio_mute',
            // The state being moved *to*, so the two directions stay separable. A high mute rate
            // on the first screen is the signal that autoplay was the wrong call; a high unmute
            // rate would say the opposite.
            properties: {
              P.action: muted ? 'unmute' : 'mute',
              P.configKey: widget.clip.configKey,
            },
          ),
          child: SizedBox(
            width: 40,
            height: 40,
            child: Center(
              child: Icon(
                muted ? Icons.volume_off_rounded : Icons.volume_up_rounded,
                size: 22,
                color: SxColors.brand,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
