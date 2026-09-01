import 'package:flutter/foundation.dart';

import '../models/app_user.dart';
import '../repositories/auth_repository.dart';
import 'edge_functions.dart';
import 'session_store.dart';

/// Calls the Edge Functions rather than the tables directly.
///
/// `users` has RLS on with no policies, so the anon key cannot read or write it at all. Every
/// mutation goes through a function holding the service_role key, which also keeps the
/// Fast2SMS credentials off the device.
class SupabaseAuthRepository implements AuthRepository {
  SupabaseAuthRepository(this._functions, this._sessions);

  final EdgeFunctions _functions;
  final SessionStore _sessions;

  @override
  Future<void> sendOtp(String phone) =>
      _guard(() => _functions.call('send-otp', body: {'mobile': phone}));

  @override
  Future<void> resendOtp(String phone) =>
      _guard(() => _functions.call('resend-otp', body: {'mobile': phone}));

  @override
  Future<AppUser> verifyOtp({required String phone, required String code}) async {
    final data = await _guard(
      () => _functions.call('verify-otp', body: {'mobile': phone, 'otp': code}),
    );

    final token = data['token'] as String?;
    final user = _userFrom(data['user']);
    if (token == null || user == null) {
      throw const OtpSendException('Could not complete sign in. Please try again.');
    }

    await _sessions.save(token: token, user: user);
    return user;
  }

  @override
  Future<AppUser> saveName(String name) async {
    final data = await _guard(
      () async => _functions.call(
        'update-profile',
        body: {'name': name.trim()},
        bearerToken: await _requireToken(),
      ),
    );

    final user = _userFrom(data['user']);
    if (user == null) {
      throw const OtpSendException('Could not save your name. Please try again.');
    }
    await _sessions.cacheUser(user);
    return user;
  }

  @override
  Future<AppUser?> currentUser() async {
    final token = await _sessions.readToken();
    if (token == null) return null;

    try {
      final data = await _functions.call('me', bearerToken: token);
      final user = _userFrom(data['user']);
      if (user != null) await _sessions.cacheUser(user);
      return user;
    } on EdgeError catch (e) {
      // A rejected session must not be reused; an unreachable backend must not dump a
      // signed-in user back into onboarding.
      if (e.code == 'unauthorized') {
        await _sessions.clear();
        return null;
      }
      return _sessions.readCachedUser();
    }
  }

  @override
  Future<void> signOut() async {
    final token = await _sessions.readToken();
    if (token != null) {
      try {
        await _functions.call('me', bearerToken: token, delete: true);
      } catch (error) {
        debugPrint('sign out call failed, clearing locally anyway: $error');
      }
    }
    await _sessions.clear();
  }

  Future<String> _requireToken() async {
    final token = await _sessions.readToken();
    if (token == null) throw const OtpSendException('Please sign in again.');
    return token;
  }

  /// Entitlement comes back computed by the Edge Function, dates and all — see
  /// `_shared/entitlement.ts`. The client deliberately does not re-derive it while online.
  AppUser? _userFrom(Object? raw) => AppUser.fromServer(raw);

  /// Turns an [EdgeError] into the exception types the ViewModel already handles, so the
  /// Supabase and direct-Fast2SMS paths behave identically on screen.
  Future<T> _guard<T>(Future<T> Function() action) async {
    try {
      return await action();
    } on EdgeError catch (e) {
      throw switch (e.code) {
        'invalid_otp' => InvalidOtpException(e.message),
        'otp_expired' => OtpExpiredException(e.message),
        'unauthorized' => const OtpSendException('Please sign in again.'),
        _ => OtpSendException(e.message),
      };
    }
  }
}
