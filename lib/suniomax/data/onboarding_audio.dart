import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player/video_player.dart';

import '../../data/analytics/analytics.dart';
import '../../data/analytics/analytics_events.dart';
import '../../data/repositories/app_config_repository.dart';
import '../../features/subscription/promo_video.dart';
import 'providers.dart';

/// The spoken prompts on SunioMax's onboarding, and the mute the user can set once.
///
/// SunioMax is a voice-controlled product sold through Hindi-language campaigns to people who may
/// not read English comfortably, and its picker offers nine Indian languages — yet every
/// instruction in its onboarding is written text. These four clips let the screens be heard.
///
/// Three things here are not obvious and are each the result of something that would otherwise
/// break:
///
///  * **Playback is single-slot.** `context.push(SxRoutes.otp)` leaves the phone screen *mounted*
///    beneath the OTP screen, so its `dispose` does not run on the way forward. A controller
///    tied naively to widget lifecycle would have two voices talking at once.
///  * **`PromoVideo` cannot be reused for this.** It rejects a stream whose reported size is zero,
///    and an audio-only file reports exactly that. See [_open].
///  * **The home screen deliberately has no clip.** That is where the microphone listens, and a
///    voice-over transcribed by a live `SpeechRecognizer` can match the lock phrase and lock the
///    user's phone by itself.

/// One clip, and the `app_config` row it comes from.
///
/// An enum rather than four strings at four call sites so that exactly one place knows which
/// screen plays what — and so a screen cannot silently ask for a row that does not exist.
enum SxAudioClip {
  language(sunioMaxAudioLanguageKey),
  phone(sunioMaxAudioPhoneKey),
  otp(sunioMaxAudioOtpKey),
  name(sunioMaxAudioNameKey);

  const SxAudioClip(this.configKey);

  /// The public `app_config` row holding this clip's https URL. Blank is the normal state.
  final String configKey;
}

/// The URL for [clip], or empty when there is nothing playable.
///
/// Empty covers every "no" identically — no row, a blank row, a row someone typed an `http://` URL
/// into — because the screen treats them the same way: no control, no sound, and a screen that
/// looks exactly as it did before this feature existed.
///
/// The https rule is [promoVideoUri]'s, deliberately shared rather than restated: iOS ATS and
/// Android's default `usesCleartextTraffic = false` both refuse cleartext, so an `http://` value
/// fails on every device rather than on some, and is better treated as unset here than discovered
/// twelve seconds later at the end of a timeout.
String audioUrlFor(SxAudioClip clip, Map<String, String> config) {
  final url = config.configString(clip.configKey);
  return promoVideoUri(url) == null ? '' : url.trim();
}

/// SunioMax's paywall promo, falling back to Circle360's.
///
/// Both apps showed `paywall_video_url` until this split, and that row is Circle360's footage — a
/// map, a family, a location pin, none of which SunioMax sells. The fallback is what lets
/// `suniomax_paywall_video_url` ship blank and change nothing: SunioMax keeps showing what it
/// shows today until somebody pastes in footage of its own.
///
/// Unlike [audioUrlFor] this does not apply the https rule, because it does not need to —
/// `PromoVideo` applies it itself, to whatever it is handed. Filtering here would only mean a
/// malformed SunioMax row silently fell back to Circle360's video, which is a worse answer than
/// no video: it would look deliberate.
String sunioPaywallVideoUrl(Map<String, String> config) {
  final own = config.configString(sunioMaxPaywallVideoKey).trim();
  return own.isNotEmpty ? own : config.configString(paywallVideoKey).trim();
}

/// Whether the user has muted the voice-over, remembered across launches.
///
/// `SharedPreferences` rather than the secure store, for the same reason as `LanguagePreference`
/// beside it: this is a preference, not a credential, and nothing here reaches a server.
///
/// **An unreadable store means unmuted.** The clips are the accessibility affordance this whole
/// feature exists for, so the failure direction is "plays when it should not" rather than "silent
/// for a user who needs it" — the first is one tap to fix and the second is invisible.
class SxAudioPreference {
  const SxAudioPreference();

  static const _key = 'suniomax.audio_muted';

  Future<bool> read() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getBool(_key) ?? false;
    } catch (error) {
      debugPrint('[sx audio] could not read the mute preference: $error');
      return false;
    }
  }

  Future<void> write(bool muted) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_key, muted);
    } catch (error) {
      // Costs the user one extra tap on the next launch. Not worth failing a tap over.
      debugPrint('[sx audio] could not store the mute preference: $error');
    }
  }
}

/// The mute, shared by every screen.
///
/// A [Notifier] rather than per-screen state so that muting on the phone step is already true when
/// the OTP step builds. Re-asking a user who has just said no is what makes an app feel like it is
/// not listening — which is a particularly bad thing for this app to feel like.
///
/// Starts unmuted and corrects itself once the stored value arrives. That order is deliberate: the
/// read is a disk hit, and blocking the first clip behind it would cost the opening of every
/// voice-over for the sake of a preference most users never set. A muted user hears at most the
/// first instant of the first clip of a launch, and only because the prompt autoplays.
class AudioMutedNotifier extends Notifier<bool> {
  @override
  bool build() {
    // The disk read outlives this notifier whenever SunioMax's onboarding is left quickly, and
    // assigning `state` after disposal throws. A flag rather than a `mounted` getter because
    // Riverpod 2 does not offer one on [Notifier].
    var disposed = false;
    ref.onDispose(() => disposed = true);

    final preference = ref.watch(sxAudioPreferenceProvider);
    unawaited(
      preference.read().then((muted) {
        if (!disposed && muted != state) state = muted;
      }),
    );
    return false;
  }

  Future<void> toggle() => set(!state);

  Future<void> set(bool muted) async {
    state = muted;
    // Applied to whatever is playing right now, so the tap is heard rather than taking effect on
    // the next screen.
    ref.read(onboardingAudioControllerProvider).applyMuted(muted);
    await ref.read(sxAudioPreferenceProvider).write(muted);
  }
}

/// Plays one onboarding clip at a time, and only one.
///
/// Single-slot because the screens are not: `context.push(SxRoutes.otp)` leaves the phone screen
/// mounted underneath, so a controller owned by each screen and disposed with it would play the
/// phone clip and the OTP clip together — the phone screen never disposes on the way forward.
/// Ownership lives here instead, and a screen may only stop what it still owns
/// ([stopIfCurrent]).
///
/// No warm-up, unlike the paywall's video. `PromoVideoWarmup` transfers a player exactly once and
/// then forgets it, which is correct for a screen reached once; onboarding can be walked backwards
/// and a second visit would find the clip already taken and re-download it. These are a few
/// seconds of speech — the machinery costs more than it saves.
///
/// **A clip plays once, when its screen is first reached, and does not replay on the way back.**
/// Going forward there is no overlap — [play] disposes the outgoing player before it opens the
/// next — and coming back leaves the screen silent, which is the right answer for the reason
/// people come back: a mistyped number or a rejected code, not a prompt they want repeated. The
/// control stays a mute *preference*, not a play button, so it is never claiming a sound that is
/// not happening.
class OnboardingAudioController {
  OnboardingAudioController(this._muted);

  /// Reads the live mute rather than holding a copy, so a controller opened during a toggle cannot
  /// come up at the wrong volume.
  final bool Function() _muted;

  VideoPlayerController? _player;

  /// What [_player] is playing, and what [stopIfCurrent] compares against. Set *before* the open
  /// begins, so a second `play` during the first one's await is recognised as a newer generation.
  SxAudioClip? _current;

  /// Two screens appearing in quick succession leave two `initialize()` futures in flight. Without
  /// this the slower one wins and installs a player the flow has already moved past.
  int _generation = 0;

  /// The plugin has no timeout of its own: a host that accepts the connection and then goes quiet
  /// leaves `initialize()` pending forever, holding a player nothing will ever stop.
  static const _initTimeout = Duration(seconds: 12);

  /// Which clip this controller currently owns, if any.
  @visibleForTesting
  SxAudioClip? get current => _current;

  /// Starts [clip], replacing whatever was playing.
  ///
  /// A no-op when [clip] is already the current one, which is what makes this safe to call from
  /// `build`: a rebuild must not restart a clip halfway through.
  Future<void> play(SxAudioClip clip, String url) async {
    if (_current == clip) return;
    final generation = ++_generation;
    _current = clip;

    await _disposePlayer();
    if (generation != _generation) return;

    final uri = promoVideoUri(url);
    if (uri == null) {
      // Not a failure worth reporting: an operator who has not filled the row in yet is the
      // normal state, and [audioUrlFor] has already kept the control off the screen for it.
      _current = null;
      return;
    }

    final player = VideoPlayerController.networkUrl(
      uri,
      videoPlayerOptions: VideoPlayerOptions(
        // Defaults to true, and true is meant for something the user chose to watch. This is a
        // prompt on a form; holding the screen awake for it would be wrong.
        preventsDisplaySleepDuringVideoPlayback: false,
        // The default, passed explicitly because it is a decision. False means the clip takes
        // audio focus and stops whatever the user was listening to, which is what speech the user
        // is meant to follow should do; true would run both streams at once and read as a bug.
        mixWithOthers: false,
      ),
    );

    try {
      await player.initialize().timeout(_initTimeout);
    } catch (error) {
      unawaited(player.dispose());
      if (generation != _generation) return;
      _current = null;
      _report(clip, uri, error);
      return;
    }

    // Deliberately **not** the zero-size check `PromoVideo` makes here. That guard is what stops
    // an HTML error page served with a video content type being handed to `FittedBox` as a
    // zero-sized child — and an audio-only file reports `Size.zero` legitimately, so reusing
    // `PromoVideo` for this would reject every clip as broken. Nothing paints this player; there
    // is no size to divide by.
    if (generation != _generation) {
      unawaited(player.dispose());
      return;
    }

    await player.setVolume(_muted() ? 0 : 1);

    // Checked again: that await is a gap like any other, and a newer clip can arrive inside it.
    if (generation != _generation) {
      unawaited(player.dispose());
      return;
    }

    _player = player;
    unawaited(player.play());
  }

  /// Stops [clip] — but only if it is still the one playing.
  ///
  /// The guard is the whole point. The phone screen stays mounted under the OTP screen and
  /// disposes only when the user comes *back* past it, by which time the OTP clip is playing; an
  /// unguarded stop-on-dispose would cut off a clip the screen no longer owns.
  Future<void> stopIfCurrent(SxAudioClip clip) async {
    if (_current != clip) return;
    _generation++;
    _current = null;
    await _disposePlayer();
  }

  /// Volume, applied to whatever is playing. Called by [AudioMutedNotifier.set].
  void applyMuted(bool muted) => unawaited(_player?.setVolume(muted ? 0 : 1));

  /// Held quiet whenever the app is not the thing on screen.
  ///
  /// `video_player` installs an observer of its own, but it only handles `paused`. On iOS the
  /// control centre and the app switcher stop at `inactive` and never reach `paused` at all, and a
  /// voice talking over either is worse here than on the paywall — it is speech, not background
  /// music. Resuming is deliberately not paired with this: a prompt the user has already half
  /// heard, restarting mid-sentence when they come back, is noise.
  void pauseForBackground() => unawaited(_player?.pause());

  Future<void> _disposePlayer() async {
    final player = _player;
    _player = null;
    if (player == null) return;
    await player.dispose();
  }

  void dispose() {
    _generation++;
    _current = null;
    unawaited(_disposePlayer());
  }

  void _report(SxAudioClip clip, Uri uri, Object? error) {
    analytics.track(Ev.onboardingAudioFailed, {
      // Which row to fix — the only actionable half of this event.
      P.configKey: clip.configKey,
      // The host, not the URL: the row is operator-entered and could carry a signed link with a
      // token in its query string. A host is enough to tell a dead bucket from a bad encode, and
      // it matches what `Ev.paywallVideoFailed` reports.
      P.source: uri.host,
      P.error: error.toString(),
    });
  }
}
