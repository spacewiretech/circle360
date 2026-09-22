import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../repositories/voice_lock_repository.dart';

/// The voice lock with nothing behind it.
///
/// Stores the settings and answers honestly that nothing is listening. This is what runs where
/// the native side does not exist — iOS, the web build, and every widget test — so the screens
/// stay usable and testable without a platform channel.
///
/// On Android the real implementation is `ChannelVoiceLockRepository`, and the authoritative copy
/// of all of this lives in Kotlin's `SunioState`, because the service outlives the Flutter engine.
class LocalVoiceLockRepository implements VoiceLockRepository {
  LocalVoiceLockRepository([FlutterSecureStorage? secure])
    : _secure = secure ?? const FlutterSecureStorage();

  final FlutterSecureStorage _secure;
  final _changes = StreamController<VoiceLockSettings>.broadcast();

  static const _phraseKey = 'suniomax.voice_phrase';
  static const _unlockPhraseKey = 'suniomax.unlock_phrase';
  static const _passcodeKey = 'suniomax.passcode';
  static const _enabledKey = 'suniomax.voice_lock_enabled';

  @override
  Stream<VoiceLockSettings> watch() => _changes.stream;

  @override
  Future<VoiceLockSettings> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final passcode = await _secure.read(key: _passcodeKey);

      final settings = VoiceLockSettings(
        enabled: prefs.getBool(_enabledKey) ?? false,
        phrase: await _secure.read(key: _phraseKey),
        unlockPhrase: await _secure.read(key: _unlockPhraseKey),
        hasPasscode: passcode != null,
        // Nothing is listening here, and saying otherwise would make the screen claim the phone
        // is protected when it is not.
        listening: false,
      );

      return settings;
    } catch (error) {
      debugPrint('[voice-lock] could not read settings: $error');
      return const VoiceLockSettings();
    }
  }

  @override
  Future<VoiceLockSettings> setEnabled(bool value) async {
    final current = await load();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_enabledKey, value);
    return _emit(current.copyWith(enabled: value));
  }

  @override
  Future<VoiceLockSettings> setPhrase(String phrase) =>
      _writePhrase(_phraseKey, phrase);

  @override
  Future<VoiceLockSettings> setUnlockPhrase(String phrase) =>
      _writePhrase(_unlockPhraseKey, phrase);

  Future<VoiceLockSettings> _writePhrase(String key, String phrase) async {
    final trimmed = phrase.trim();
    if (trimmed.isEmpty) return load();
    await _secure.write(key: key, value: trimmed);
    return _emit(await load());
  }

  @override
  Future<VoiceLockSettings> setPasscode(String passcode) async {
    // A fresh salt per write, so setting the same passcode twice does not produce the same value.
    final salt = _newSalt();
    await _secure.write(
      key: _passcodeKey,
      value: '$salt:${_hash(passcode, salt)}',
    );
    return _emit(await load());
  }

  @override
  Future<bool> verifyPasscode(String passcode) async {
    try {
      final stored = await _secure.read(key: _passcodeKey);
      if (stored == null) return false;

      final separator = stored.indexOf(':');
      if (separator <= 0) return false;

      return _constantTimeEquals(
        _hash(passcode, stored.substring(0, separator)),
        stored.substring(separator + 1),
      );
    } catch (error) {
      debugPrint('[voice-lock] could not verify the passcode: $error');
      return false;
    }
  }

  // Nothing to grant where there is no native side: every answer is "as good as it gets".
  @override
  Future<VoiceLockPermissions> permissions() async =>
      const VoiceLockPermissions();

  @override
  Future<VoiceLockPermissions> requestMicrophone() => permissions();

  @override
  Future<VoiceLockPermissions> requestOverlay() => permissions();

  @override
  Future<VoiceLockPermissions> requestNotifications() => permissions();

  @override
  Future<VoiceLockPermissions> requestIgnoreBatteryOptimizations() =>
      permissions();

  @override
  Future<void> clear() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_enabledKey);
      await _secure.delete(key: _phraseKey);
      await _secure.delete(key: _unlockPhraseKey);
      await _secure.delete(key: _passcodeKey);
      _emit(const VoiceLockSettings());
    } catch (error) {
      debugPrint('[voice-lock] could not clear: $error');
    }
  }

  @override
  Future<PhraseCaptureResult> capturePhrase({String? language}) async {
    // No recogniser here. Reported as "heard nothing" rather than as a refused microphone,
    // because that is what the screen should say on a platform with no capture at all.
    debugPrint('[voice-lock] phrase capture needs the native recogniser');
    return const PhraseCaptureResult();
  }

  VoiceLockSettings _emit(VoiceLockSettings settings) {
    if (!_changes.isClosed) _changes.add(settings);
    return settings;
  }

  /// Salted SHA-256.
  ///
  /// Worth being honest about what this buys: a four-digit passcode has ten thousand
  /// possibilities, so anyone holding this string recovers it in microseconds whatever the hash.
  /// The protection is the Keychain/Keystore the string sits in. The hash is here so the passcode
  /// is not in plaintext in a backup, and so lengthening it later is a change to one screen
  /// rather than to the storage format.
  static String _hash(String passcode, String salt) =>
      sha256.convert(utf8.encode('$salt:$passcode')).toString();

  static String _newSalt() {
    final random = Random.secure();
    return base64Url.encode(List.generate(16, (_) => random.nextInt(256)));
  }

  /// Compares without returning early, so the time taken says nothing about how much matched.
  static bool _constantTimeEquals(String a, String b) {
    if (a.length != b.length) return false;
    var difference = 0;
    for (var i = 0; i < a.length; i++) {
      difference |= a.codeUnitAt(i) ^ b.codeUnitAt(i);
    }
    return difference == 0;
  }
}
