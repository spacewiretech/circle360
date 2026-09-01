import '../../app/assets.dart';
import '../fast2sms/fast2sms_client.dart';
import '../models/app_user.dart';
import '../repositories/auth_repository.dart';
import 'fake_session.dart';

/// Accepts any 4-digit code. Replace with Supabase phone auth by swapping the provider in
/// `data/providers.dart`.
class FakeAuthRepository implements AuthRepository {
  FakeAuthRepository(this._session);

  final FakeSession _session;

  @override
  Future<AppUser?> currentUser() async {
    await FakeSession.latency(250);
    return _session.user;
  }

  @override
  Future<void> sendOtp(String phone) => FakeSession.latency(600);

  @override
  Future<void> resendOtp(String phone) => FakeSession.latency(600);

  @override
  Future<AppUser> verifyOtp({required String phone, required String code}) async {
    await FakeSession.latency(600);
    if (code.length != Fast2SmsClient.otpLength || int.tryParse(code) == null) {
      throw const InvalidOtpException();
    }
    final user = AppUser(
      id: 'local-user',
      phone: phone,
      avatarAsset: Img.avatarMeLarge,
    );
    _session.user = user;
    return user;
  }

  @override
  Future<AppUser> saveName(String name) async {
    await FakeSession.latency();
    final user = (_session.user ??
            const AppUser(id: 'local-user', phone: '', avatarAsset: Img.avatarMeLarge))
        .copyWith(name: name.trim());
    _session.user = user;
    return user;
  }

  @override
  Future<void> signOut() async {
    await FakeSession.latency(200);
    _session.reset();
  }
}
