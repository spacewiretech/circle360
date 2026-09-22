import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../data/analytics/analytics_events.dart';
import '../../../../data/providers.dart';
import '../../../data/providers.dart';
import '../../../data/repositories/voice_lock_repository.dart';

/// What the Voice Lock screen is doing.
@immutable
class VoiceLockState {
  const VoiceLockState({
    this.settings = const VoiceLockSettings(),
    this.loading = true,
    this.busy = false,
    this.error,
  });

  final VoiceLockSettings settings;
  final bool loading;

  /// A permission round trip is in flight, so the switch shows a spinner rather than flapping.
  final bool busy;

  final String? error;

  /// Whether the setup rows can be used.
  ///
  /// **Nothing below the switch is reachable until the lock is on.** The flow is: turn it on,
  /// grant the microphone and the overlay, then record a phrase and set a passcode. Letting
  /// someone record a phrase first would leave them holding a configured lock that cannot run,
  /// with no clue that a permission was the missing piece.
  ///
  /// The rows are shown dimmed rather than hidden so it is obvious what turning the switch on
  /// leads to.
  bool get rowsActive => settings.enabled;

  /// Armed, but with nothing recorded yet — the state the user is in immediately after granting
  /// the permissions, and the one the screen has to give a next step for.
  bool get needsSetup => settings.enabled && !settings.configured;

  VoiceLockState copyWith({
    VoiceLockSettings? settings,
    bool? loading,
    bool? busy,
    String? error,
    bool clearError = false,
  }) => VoiceLockState(
    settings: settings ?? this.settings,
    loading: loading ?? this.loading,
    busy: busy ?? this.busy,
    error: clearError ? null : error ?? this.error,
  );
}

class VoiceLockViewModel extends Notifier<VoiceLockState> {
  @override
  VoiceLockState build() {
    _load();

    // The native side is the authority, and it changes without being asked: the service stops,
    // the overlay goes up, a permission is revoked in Settings. Mirroring it here is what stops
    // the switch claiming the phone is protected when nothing is listening.
    ref.listen(voiceLockStreamProvider, (_, next) {
      final settings = next.valueOrNull;
      if (settings != null) {
        state = state.copyWith(settings: settings, loading: false);
      }
    });

    return const VoiceLockState();
  }

  VoiceLockRepository get _repository => ref.read(voiceLockRepositoryProvider);

  /// The user asked to turn the lock on, and is away in a Settings screen granting what was
  /// missing. Spent by [refresh] on the way back.
  bool _enableOnReturn = false;

  Future<void> _load() async {
    // Awaited into a local first. `state = state.copyWith(settings: await …)` evaluates the
    // receiver `state` *before* the await — which is during `build()`, before the provider is
    // initialised — and throws "Tried to read the state of an uninitialized provider".
    final settings = await _repository.load();
    state = state.copyWith(settings: settings, loading: false);
  }

  /// Re-reads everything, and finishes an enable the user left mid-way.
  ///
  /// Called when the screen resumes. "Display over other apps" is a Settings screen rather than a
  /// dialog, so the only way to know the answer is to look once the user is back — and without
  /// this they would return to a switch still showing off, having just granted the thing it
  /// wanted.
  Future<void> refresh() async {
    await _load();
    if (!_enableOnReturn) return;

    if (state.settings.permissions.granted && !state.settings.enabled) {
      _enableOnReturn = false;
      await setEnabled(true);
    } else if (!state.settings.permissions.overlay) {
      // Came back without granting it. Now it is a real refusal.
      _enableOnReturn = false;
      state = state.copyWith(error: _refusalFor(state.settings.permissions));
    }
  }

  /// Turns the lock on, collecting whatever it still needs on the way.
  ///
  /// The permissions are requested here rather than up front: asking for a microphone and an
  /// always-on-top window before the user has said they want the feature is how a permission gets
  /// refused permanently.
  Future<void> setEnabled(bool value) async {
    if (state.busy) return;

    if (!value) {
      _enableOnReturn = false;
      final settings = await _repository.setEnabled(false);
      state = state.copyWith(settings: settings, clearError: true);
      _track(settings);
      return;
    }

    state = state.copyWith(busy: true, clearError: true);

    var permissions = await _repository.permissions();
    if (!permissions.microphone) {
      permissions = await _repository.requestMicrophone();
    }
    // Sequential, not parallel: each opens something the user has to answer, and two system
    // screens at once means one is dismissed without being read.
    //
    // Deliberately NOT gated on the microphone. This is the step the explainer dialog promised
    // would "Open Settings", and a button that opens nothing because an unrelated permission was
    // refused is the worst kind of dead control.
    if (!permissions.overlay) {
      permissions = await _repository.requestOverlay();
    }
    if (permissions.granted && !permissions.notifications) {
      permissions = await _repository.requestNotifications();
    }

    final settings = await _repository.setEnabled(true);

    // `requestOverlay` only *opens* the Settings screen — it cannot wait for an answer, because
    // the user has left the app to give one. So an enable that failed on the overlay is not a
    // refusal yet; it is a pending one, finished by [refresh] when they come back.
    _enableOnReturn = !settings.enabled && !settings.permissions.overlay;

    state = state.copyWith(
      settings: settings,
      busy: false,
      // Nothing scary while they are away answering. The error is for a real refusal.
      error: settings.enabled || _enableOnReturn
          ? null
          : _refusalFor(settings.permissions),
      clearError: settings.enabled || _enableOnReturn,
    );
    if (settings.enabled) _track(settings);
  }

  /// Which missing grant stopped it, in the user's terms.
  String _refusalFor(VoiceLockPermissions permissions) {
    if (!permissions.microphone) {
      return 'Voice lock needs the microphone to hear your phrase.';
    }
    if (!permissions.overlay) {
      return 'Voice lock needs permission to display over other apps, or the lock screen '
          'cannot appear.';
    }
    return 'Voice lock could not start. Check the app’s permissions in Settings.';
  }

  Future<void> setPhrase(String phrase) async {
    final clash = state.settings.unlockPhrase;
    if (clash != null && phrasesConflict(phrase, clash)) {
      state = state.copyWith(
        error:
            'That is too close to your unlock phrase (\u201C$clash\u201D). One would '
            'trigger the other \u2014 record something different.',
      );
      return;
    }

    final settings = await _repository.setPhrase(phrase);
    state = state.copyWith(settings: settings, clearError: true);

    // The word count, never the phrase. It unlocks a phone.
    ref.read(analyticsProvider).track(Ev.voicePhraseSaved, {
      P.phraseWordCount: settings.phraseWordCount,
    });
  }

  Future<void> setUnlockPhrase(String phrase) async {
    // Checked before it is stored. Two phrases where one contains the other leave one of the two
    // commands permanently unreachable, and nothing on screen would ever say why.
    final clash = state.settings.phrase;
    if (clash != null && phrasesConflict(phrase, clash)) {
      state = state.copyWith(
        error:
            'That is too close to your lock phrase (\u201C$clash\u201D). One would '
            'trigger the other \u2014 record something different.',
      );
      return;
    }

    final settings = await _repository.setUnlockPhrase(phrase);
    state = state.copyWith(settings: settings, clearError: true);
  }

  Future<void> setPasscode(String passcode) async {
    final settings = await _repository.setPasscode(passcode);
    state = state.copyWith(settings: settings, clearError: true);

    ref.read(analyticsProvider).track(Ev.backupPasscodeSet, {
      P.hasPasscode: settings.hasPasscode,
    });
  }

  void _track(VoiceLockSettings settings) {
    ref.read(analyticsProvider).track(Ev.voiceLockChanged, {
      P.enabled: settings.enabled,
      P.phraseWordCount: settings.phraseWordCount,
      P.hasPasscode: settings.hasPasscode,
    });
  }
}

final voiceLockViewModelProvider =
    NotifierProvider<VoiceLockViewModel, VoiceLockState>(
      VoiceLockViewModel.new,
    );
