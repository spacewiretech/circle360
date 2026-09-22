import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'channel_voice_lock_repository.dart';
import 'language_preference.dart';
import 'local/local_voice_lock_repository.dart';
import 'onboarding_audio.dart';
import 'repositories/voice_lock_repository.dart';

/// SunioMax's bindings.
///
/// A sibling of `lib/data/providers.dart`, not a replacement for it. Everything SunioMax shares
/// with Circle360 — auth, subscriptions, the Cashfree checkout, analytics, the session store, the
/// whole three-rung ladder — is bound there and used from here unchanged. Only what is SunioMax's
/// alone lives in this file.
///
/// The rule the root `CLAUDE.md` states still holds and is the reason for the split: no view and
/// no ViewModel imports a concrete implementation, so swapping an implementation is a change to
/// the right-hand side of one line.

/// `appVariantProvider` is deliberately **not** here — it lives in `lib/data/providers.dart`
/// with the rest of the shared bindings, because `authRepositoryProvider` depends on it to stamp
/// new accounts with the app they signed up in. Re-exported so a SunioMax file needs one import.
export '../../data/providers.dart' show appVariantProvider;

final languagePreferenceProvider = Provider<LanguagePreference>(
  (ref) => const LanguagePreference(),
);

/// The chosen language, or null while it loads and when none has been chosen.
///
/// Watched by the splash to decide whether the picker is the next screen, and read by the native
/// recogniser for its language tag.
final selectedLanguageProvider = FutureProvider<SxLanguage?>(
  (ref) => ref.watch(languagePreferenceProvider).read(),
);

/// The spoken prompts on the four onboarding screens.
///
/// Three bindings rather than one because they have three different lifetimes: the store is
/// stateless, the mute is state the whole flow shares, and the player is a native resource that
/// must be released. They live here and not inside the screens because **the screens outlive each
/// other** — `context.push` leaves the phone screen mounted beneath the OTP screen, so a player
/// owned by a screen would play two clips at once. See `onboarding_audio.dart`.
final sxAudioPreferenceProvider = Provider<SxAudioPreference>(
  (ref) => const SxAudioPreference(),
);

/// Whether the voice-over is muted, app-wide and remembered across launches.
final audioMutedProvider = NotifierProvider<AudioMutedNotifier, bool>(
  AudioMutedNotifier.new,
);

/// The one player, for the whole flow.
final onboardingAudioControllerProvider = Provider<OnboardingAudioController>((
  ref,
) {
  // `ref.read` inside the closure rather than `ref.watch` out here: watching the mute would
  // rebuild this provider on every toggle, disposing the player mid-sentence to apply a volume
  // change [AudioMutedNotifier.set] has already applied directly.
  final controller = OnboardingAudioController(
    () => ref.read(audioMutedProvider),
  );
  ref.onDispose(controller.dispose);
  return controller;
});

/// The voice lock.
///
/// Android gets the real thing: a Kotlin foreground service that listens, and a window drawn over
/// every other app. Everywhere else — iOS, the web build, every widget test — gets the local
/// implementation, which stores the settings and is honest that nothing is listening.
///
/// This one line is the whole platform boundary. No screen and no ViewModel knows which is live.
final voiceLockRepositoryProvider = Provider<VoiceLockRepository>((ref) {
  if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) {
    return ChannelVoiceLockRepository();
  }
  return LocalVoiceLockRepository();
});

/// Pushes every native change — the listener starting or stopping, the overlay going up, a
/// permission granted in Settings while the app was backgrounded — into the screen.
final voiceLockStreamProvider = StreamProvider<VoiceLockSettings>(
  (ref) => ref.watch(voiceLockRepositoryProvider).watch(),
);
