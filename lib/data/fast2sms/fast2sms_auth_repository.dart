import 'package:flutter/foundation.dart';

import '../../app/assets.dart';
import '../fake/fake_session.dart';
import '../models/app_user.dart';
import '../repositories/auth_repository.dart';
import 'fast2sms_client.dart';
import 'fast2sms_exception.dart';

/// Real OTP delivery over Fast2SMS.
///
/// Only the OTP half is real. The account record still lives in [FakeSession], so
/// `saveName`/`currentUser`/`signOut` behave exactly as they did on the fake until Supabase
/// takes over persistence.
class Fast2SmsAuthRepository implements AuthRepository {
  Fast2SmsAuthRepository(this._client, this._session);

  final Fast2SmsClient _client;
  final FakeSession _session;

  @override
  Future<AppUser?> currentUser() async => _session.user;

  @override
  Future<void> sendOtp(String phone) async {
    try {
      await _client.sendOtp(phone);
    } on Fast2SmsException catch (e) {
      throw OtpSendException(e.userMessage);
    }
  }

  @override
  Future<void> resendOtp(String phone) async {
    try {
      await _client.resendOtp(phone);
    } on Fast2SmsException catch (e) {
      // 404 means the 10-minute redelivery window has closed, so issue a fresh code instead
      // of leaving the user on a dead screen.
      if (e.code == 404) {
        debugPrint('[Fast2SMS] resend window closed, sending a new code');
        await sendOtp(phone);
        return;
      }
      // 400 on resend is the server-side cap, which reads differently from a send failure.
      if (e.code == 400) {
        throw const OtpSendException(
          'You have requested too many codes. Please try again later.',
        );
      }
      throw OtpSendException(e.userMessage);
    }
  }

  @override
  Future<AppUser> verifyOtp({required String phone, required String code}) async {
    final VerifyResult result;
    try {
      result = await _client.verifyOtp(mobile: phone, otp: code);
    } on Fast2SmsException catch (e) {
      throw OtpSendException(e.userMessage);
    }

    switch (result) {
      case VerifyResult.wrongCode:
        throw const InvalidOtpException();
      case VerifyResult.expiredOrUsed:
        throw const OtpExpiredException();
      case VerifyResult.verified:
        final user = AppUser(
          id: 'user-$phone',
          phone: phone,
          avatarAsset: Img.avatarMeLarge,
        );
        _session.user = user;
        return user;
    }
  }

  @override
  Future<AppUser> saveName(String name) async {
    final user = (_session.user ??
            const AppUser(id: 'local-user', phone: '', avatarAsset: Img.avatarMeLarge))
        .copyWith(name: name.trim());
    _session.user = user;
    return user;
  }

  @override
  Future<void> signOut() async => _session.reset();
}
