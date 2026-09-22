import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'repositories/voice_lock_repository.dart';

/// The voice lock, backed by the Kotlin service.
///
/// Thin on purpose. Every decision — whether arming is allowed, whether a passcode matches, what
/// the phrase is — is made in `VoiceLockBridge` and `SunioState`, because `VoiceLockService` and
/// `LockOverlay` outlive the Flutter engine and cannot ask Dart anything once it is gone. This
/// holds no state of its own; it asks, and it relays what comes back.
///
/// The passcode travels one way. It goes in; only a boolean comes back.
class ChannelVoiceLockRepository implements VoiceLockRepository {
  ChannelVoiceLockRepository({MethodChannel? methods, EventChannel? events})
    : _methods = methods ?? const MethodChannel('suniomax/voicelock'),
      _events = events ?? const EventChannel('suniomax/voicelock_events');

  final MethodChannel _methods;
  final EventChannel _events;

  @override
  Future<VoiceLockSettings> load() => _call('getState');

  @override
  Stream<VoiceLockSettings> watch() => _events
      .receiveBroadcastStream()
      .map(VoiceLockSettings.fromMap)
      // A dead channel must not take the screen down with it; the last known state stands.
      .handleError(
        (Object error) => debugPrint('[voice-lock] event stream: $error'),
      );

  @override
  Future<VoiceLockSettings> setEnabled(bool value) =>
      _call('setEnabled', {'enabled': value});

  @override
  Future<VoiceLockSettings> setPhrase(String phrase) =>
      _call('setPhrase', {'phrase': phrase.trim()});

  @override
  Future<VoiceLockSettings> setUnlockPhrase(String phrase) =>
      _call('setUnlockPhrase', {'phrase': phrase.trim()});

  @override
  Future<VoiceLockSettings> setPasscode(String passcode) =>
      _call('setPasscode', {'passcode': passcode});

  @override
  Future<bool> verifyPasscode(String passcode) async {
    try {
      final ok = await _methods.invokeMethod<bool>('verifyPasscode', {
        'passcode': passcode,
      });
      return ok ?? false;
    } catch (error) {
      // A failed check is a refusal, never an acceptance.
      debugPrint('[voice-lock] could not verify the passcode: $error');
      return false;
    }
  }

  @override
  Future<VoiceLockPermissions> permissions() => _permissions('permissions');

  @override
  Future<VoiceLockPermissions> requestMicrophone() =>
      _permissions('requestMicrophone');

  @override
  Future<VoiceLockPermissions> requestOverlay() =>
      _permissions('requestOverlay');

  @override
  Future<VoiceLockPermissions> requestNotifications() =>
      _permissions('requestNotifications');

  @override
  Future<VoiceLockPermissions> requestIgnoreBatteryOptimizations() =>
      _permissions('requestIgnoreBatteryOptimizations');

  @override
  Future<void> clear() async {
    try {
      await _methods.invokeMethod<Map<Object?, Object?>>('clear');
    } catch (error) {
      debugPrint('[voice-lock] could not clear: $error');
    }
  }

  @override
  Future<PhraseCaptureResult> capturePhrase({String? language}) async {
    try {
      final raw = await _methods.invokeMethod<Map<Object?, Object?>>(
        'capturePhrase',
        {'language': language},
      );
      return PhraseCaptureResult.fromMap(raw);
    } catch (error) {
      debugPrint('[voice-lock] capturePhrase failed: $error');
      return const PhraseCaptureResult();
    }
  }

  Future<VoiceLockSettings> _call(
    String method, [
    Map<String, Object?>? args,
  ]) async {
    try {
      final raw = await _methods.invokeMethod<Map<Object?, Object?>>(
        method,
        args,
      );
      return VoiceLockSettings.fromMap(raw);
    } catch (error) {
      debugPrint('[voice-lock] $method failed: $error');
      return const VoiceLockSettings();
    }
  }

  Future<VoiceLockPermissions> _permissions(String method) async {
    try {
      final raw = await _methods.invokeMethod<Map<Object?, Object?>>(method);
      return VoiceLockPermissions.fromMap(raw);
    } catch (error) {
      debugPrint('[voice-lock] $method failed: $error');
      return const VoiceLockPermissions();
    }
  }
}
