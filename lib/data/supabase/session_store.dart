import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../models/app_user.dart';

/// Holds the session token issued by `verify-otp`.
///
/// The token is a bearer credential for this account, so it belongs in the Keychain/Keystore
/// rather than shared preferences. The cached user beside it is only a convenience for
/// rendering before `me` responds — the server is always the authority on who is signed in.
class SessionStore {
  SessionStore([FlutterSecureStorage? storage])
      : _storage = storage ?? const FlutterSecureStorage();

  final FlutterSecureStorage _storage;

  static const _tokenKey = 'loc360.session_token';
  static const _userKey = 'loc360.cached_user';

  /// Bumped whenever the cached shape changes. An older payload is dropped rather than
  /// half-parsed, so a build that adds a field cannot inherit a stale entitlement from one
  /// that did not have it.
  static const _version = 2;

  Future<String?> readToken() => _storage.read(key: _tokenKey);

  Future<void> save({required String token, required AppUser user}) async {
    await _storage.write(key: _tokenKey, value: token);
    await _cacheUser(user);
  }

  Future<void> _cacheUser(AppUser user) => _storage.write(
        key: _userKey,
        value: jsonEncode({
          'v': _version,
          'id': user.id,
          'phone': user.phone,
          'name': user.name,
          'paymentType': user.paymentType.name,
          'trialEndsAt': user.trialEndsAt?.toIso8601String(),
          'currentPeriodEnd': user.currentPeriodEnd?.toIso8601String(),
          'entitled': user.entitled,
        }),
      );

  Future<void> cacheUser(AppUser user) => _cacheUser(user);

  /// The last known user, with entitlement re-derived from the stored dates.
  ///
  /// The stored `entitled` flag was true at the moment it was written, which says nothing about
  /// now — without [AppUser.recomputeOffline] a trial that ended overnight would keep opening
  /// the app for as long as the device stayed offline.
  Future<AppUser?> readCachedUser() async {
    final raw = await _storage.read(key: _userKey);
    if (raw == null) return null;
    try {
      final map = jsonDecode(raw) as Map<String, dynamic>;
      if (map['v'] != _version) {
        await _storage.delete(key: _userKey);
        return null;
      }

      return AppUser(
        id: map['id'] as String,
        phone: map['phone'] as String? ?? '',
        name: map['name'] as String? ?? '',
        paymentType: PaymentType.parse(map['paymentType']),
        trialEndsAt: DateTime.tryParse(map['trialEndsAt'] as String? ?? ''),
        currentPeriodEnd: DateTime.tryParse(map['currentPeriodEnd'] as String? ?? ''),
        entitled: map['entitled'] as bool? ?? false,
      ).recomputeOffline();
    } catch (_) {
      // A cache written by an older build is not worth crashing over.
      await clear();
      return null;
    }
  }

  Future<void> clear() async {
    await _storage.delete(key: _tokenKey);
    await _storage.delete(key: _userKey);
  }
}
