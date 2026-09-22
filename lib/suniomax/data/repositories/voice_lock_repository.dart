import 'package:flutter/foundation.dart';

/// What the voice lock still needs before it can actually run.
///
/// Three separate grants, each refusable on its own and each fatal to a different half of the
/// feature — so they are reported separately rather than as one "ready" boolean. A user who
/// granted the microphone but refused the overlay has a listener that hears the phrase and then
/// cannot draw anything, which is the worst state to be in silently.
@immutable
class VoiceLockPermissions {
  const VoiceLockPermissions({
    this.microphone = false,
    this.overlay = false,
    this.notifications = false,
    this.batteryOptimised = true,
  });

  /// `RECORD_AUDIO`. Without it nothing is heard at all.
  final bool microphone;

  /// `SYSTEM_ALERT_WINDOW` — "Display over other apps". Without it the lock screen cannot be
  /// drawn over anything, which is the entire feature.
  final bool overlay;

  /// `POST_NOTIFICATIONS`. Android 13+ hides the foreground service's notification without it.
  /// The service still runs, so this is a warning rather than a blocker.
  final bool notifications;

  /// True while the OS may still doze the listener. Not a permission — an exemption the user is
  /// asked for, and the single biggest cause of "it stopped hearing me after a while".
  final bool batteryOptimised;

  /// The two that the feature genuinely cannot work without.
  bool get granted => microphone && overlay;

  /// Everything is in place, including the advisory ones.
  bool get ideal => granted && notifications && !batteryOptimised;

  static VoiceLockPermissions fromMap(Object? raw) {
    if (raw is! Map) return const VoiceLockPermissions();
    bool read(String key) => raw[key] == true;
    return VoiceLockPermissions(
      microphone: read('microphone'),
      overlay: read('overlay'),
      notifications: read('notifications'),
      // Absent means "we could not tell", and the safe reading of that is "still optimised",
      // because the visible consequence is a prompt the user can dismiss rather than a silent
      // listener that dies overnight.
      batteryOptimised: raw['batteryOptimized'] != false,
    );
  }
}

/// Everything the Voice Lock screen shows, in one value.
///
/// One object from one call, for the same reason `FamilySnapshot` is: the screen renders the
/// master switch and the rows together, and two sources would let them disagree for a frame — a
/// switch reading "on" above a phrase row reading "not set" is a bug report.
@immutable
class VoiceLockSettings {
  const VoiceLockSettings({
    this.enabled = false,
    this.phrase,
    this.unlockPhrase,
    this.hasPasscode = false,
    this.permissions = const VoiceLockPermissions(),
    this.listening = false,
    this.locked = false,
    this.rearming = false,
  });

  /// The master switch. Meaningless until [configured] — arming a listener with no phrase and no
  /// passcode is a phone its owner can be locked out of.
  final bool enabled;

  /// What the user says to lock the phone.
  final String? phrase;

  /// What they say to unlock it. Separate from [phrase]: one phrase for both would unlock the
  /// phone the moment it heard the words that locked it.
  final String? unlockPhrase;

  /// Whether a backup passcode exists. The passcode itself is never returned — only checked.
  final bool hasPasscode;

  final VoiceLockPermissions permissions;

  /// Whether the native listener is actually running right now. Not the same claim as [enabled]:
  /// the switch is what the user asked for, this is what is true.
  final bool listening;

  /// Whether the lock overlay is on screen. Only ever true when something else is in the
  /// foreground, so in practice the app reads it on resume.
  final bool locked;

  bool get hasPhrase => (phrase ?? '').trim().isNotEmpty;
  bool get hasUnlockPhrase => (unlockPhrase ?? '').trim().isNotEmpty;

  /// Whether the feature can be switched on at all.
  bool get configured => hasPhrase && hasUnlockPhrase && hasPasscode;

  /// Armed and actually running.
  bool get active => enabled && listening;

  /// The native side is starting the listener right now, so `listening` being false says
  /// nothing yet. Starting a service is asynchronous and the answer arrives on the event channel
  /// a moment later.
  final bool rearming;

  /// The switch is on but the listener is not running — almost always a permission that was
  /// revoked in Settings after the fact.
  ///
  /// Excludes the moment a re-arm is in flight, which is otherwise reported as a fault on every
  /// single app open.
  bool get stalled => enabled && !listening && !rearming;

  /// Words in the lock phrase. Reported to analytics; the phrase itself never is.
  int get phraseWordCount =>
      hasPhrase ? phrase!.trim().split(RegExp(r'\s+')).length : 0;

  VoiceLockSettings copyWith({
    bool? enabled,
    String? phrase,
    String? unlockPhrase,
    bool? hasPasscode,
    VoiceLockPermissions? permissions,
    bool? listening,
    bool? locked,
    bool? rearming,
  }) => VoiceLockSettings(
    enabled: enabled ?? this.enabled,
    phrase: phrase ?? this.phrase,
    unlockPhrase: unlockPhrase ?? this.unlockPhrase,
    hasPasscode: hasPasscode ?? this.hasPasscode,
    permissions: permissions ?? this.permissions,
    listening: listening ?? this.listening,
    locked: locked ?? this.locked,
    rearming: rearming ?? this.rearming,
  );

  static VoiceLockSettings fromMap(Object? raw) {
    if (raw is! Map) return const VoiceLockSettings();
    String? text(String key) {
      final value = raw[key];
      return value is String && value.trim().isNotEmpty ? value : null;
    }

    return VoiceLockSettings(
      enabled: raw['enabled'] == true,
      phrase: text('phrase'),
      unlockPhrase: text('unlockPhrase'),
      hasPasscode: raw['hasPasscode'] == true,
      permissions: VoiceLockPermissions.fromMap(raw['permissions']),
      listening: raw['listening'] == true,
      locked: raw['locked'] == true,
      rearming: raw['rearming'] == true,
    );
  }
}

/// The voice lock.
///
/// Two implementations: `LocalVoiceLockRepository` stores settings and nothing else, and
/// `ChannelVoiceLockRepository` talks to the Kotlin service that actually listens and draws the
/// overlay. Which one is live is decided in `lib/suniomax/data/providers.dart` — on iOS and in
/// tests there is no channel, so the local one keeps every screen working.
abstract interface class VoiceLockRepository {
  Future<VoiceLockSettings> load();

  /// Fires whenever the native side changes anything — the listener starting or stopping, the
  /// overlay appearing, a permission being granted in Settings while the app was backgrounded.
  Stream<VoiceLockSettings> watch();

  /// Arms or disarms the listener.
  ///
  /// Returns the state that actually resulted, which is not always what was asked for: arming
  /// without a phrase, without a passcode, or without the microphone and overlay grants leaves
  /// this off.
  Future<VoiceLockSettings> setEnabled(bool value);

  /// What the user says to lock, and to unlock.
  Future<VoiceLockSettings> setPhrase(String phrase);
  Future<VoiceLockSettings> setUnlockPhrase(String phrase);

  /// Replaces the backup passcode. Stored hashed and never read back.
  Future<VoiceLockSettings> setPasscode(String passcode);

  /// Whether [passcode] matches the stored one. False when none is set — an unset passcode must
  /// not be something an empty guess satisfies.
  Future<bool> verifyPasscode(String passcode);

  /// Asks for whichever grant is still missing. Each opens a system screen the user may simply
  /// come back from, so the answer is always re-read rather than assumed.
  Future<VoiceLockPermissions> requestMicrophone();
  Future<VoiceLockPermissions> requestOverlay();
  Future<VoiceLockPermissions> requestNotifications();
  Future<VoiceLockPermissions> requestIgnoreBatteryOptimizations();
  Future<VoiceLockPermissions> permissions();

  /// Disarms the lock and forgets the phrases and the passcode.
  ///
  /// For sign-out. Both phrases and the passcode are credentials stored on the device rather than
  /// on the account, so leaving them behind would let the next person to sign in be protected —
  /// and locked out — by a stranger's voice.
  Future<void> clear();

  /// Records one phrase and returns what the recogniser heard.
  ///
  /// The phrase is spoken rather than typed because the recogniser has its own idea of what the
  /// words are: "Hare Krishna" may come back as "hairy krishna" on a given device and language,
  /// consistently. A typed phrase would then never match what the listener hears, and the lock
  /// would simply never fire. Capturing it through the same engine that will later match it is
  /// what makes the feature work at all.
  Future<PhraseCaptureResult> capturePhrase({String? language});
}

/// Whether two phrases are too alike for the listener to tell apart.
///
/// Mirrors `VoiceLockService.containsPhrase` in Kotlin: one phrase's words appearing as a
/// contiguous run inside the other's is a genuine conflict, because the listener matches
/// containment rather than equality — a user who says "ok, lock my phone" should still be
/// understood.
///
/// The case that prompted this: "lock my phone" and "unlock my phone" are distinct as *words*, so
/// the matcher handles them — but "lock my phone" and "please lock my phone now" are not, and
/// picking that pair makes one of the two commands unreachable with nothing on screen to say so.
bool phrasesConflict(String a, String b) {
  List<String> words(String value) => value
      .toLowerCase()
      .replaceAll(RegExp(r'[^\p{L}\p{N}\s]', unicode: true), '')
      .split(RegExp(r'\s+'))
      .where((word) => word.isNotEmpty)
      .toList();

  final first = words(a);
  final second = words(b);
  if (first.isEmpty || second.isEmpty) return false;

  bool contains(List<String> haystack, List<String> needle) {
    if (needle.length > haystack.length) return false;
    for (var start = 0; start <= haystack.length - needle.length; start++) {
      var all = true;
      for (var i = 0; i < needle.length; i++) {
        if (haystack[start + i] != needle[i]) {
          all = false;
          break;
        }
      }
      if (all) return true;
    }
    return false;
  }

  return contains(first, second) || contains(second, first);
}

/// The outcome of one recording.
@immutable
class PhraseCaptureResult {
  const PhraseCaptureResult({
    this.phrase,
    this.reason,
    this.microphoneDenied = false,
  });

  /// What the recogniser heard, or null when it heard nothing usable.
  final String? phrase;

  /// Why it failed, already worded for the screen. Null on success.
  ///
  /// This exists because collapsing every failure into "nothing was heard" is actively
  /// misleading: a busy recogniser, a refused microphone, a missing speech engine and genuine
  /// silence need four different things done about them, and only the last is the user's doing.
  /// The native side names which it was.
  final String? reason;

  /// The microphone was refused, which needs a trip to Settings rather than another attempt.
  final bool microphoneDenied;

  bool get captured => (phrase ?? '').trim().isNotEmpty;

  static PhraseCaptureResult fromMap(Object? raw) {
    if (raw is! Map) {
      return const PhraseCaptureResult(
        reason: 'Could not reach the microphone.',
      );
    }
    final phrase = raw['phrase'];
    final reason = raw['reason'];
    return PhraseCaptureResult(
      phrase: phrase is String && phrase.trim().isNotEmpty
          ? phrase.trim()
          : null,
      reason: reason is String && reason.trim().isNotEmpty
          ? reason.trim()
          : null,
      microphoneDenied: raw['granted'] == false,
    );
  }
}
