import '../models/app_user.dart';

/// Phone + OTP onboarding. Backed by a fake today; the Supabase implementation will wrap
/// `supabase.auth.signInWithOtp` / `verifyOTP` behind the same three calls.
abstract interface class AuthRepository {
  /// The signed-in user, or null when onboarding has not finished.
  Future<AppUser?> currentUser();

  /// Sends a fresh code. Throws [OtpSendException] when the provider refuses.
  Future<void> sendOtp(String phone);

  /// Redelivers the code from the last [sendOtp] rather than issuing a new one, falling back
  /// to a fresh send once the provider's redelivery window has closed.
  Future<void> resendOtp(String phone);

  /// Returns the user record created (or re-loaded) for [phone].
  ///
  /// Throws [InvalidOtpException] when the code does not match, [OtpExpiredException] when it
  /// has aged out or was already used.
  Future<AppUser> verifyOtp({required String phone, required String code});

  Future<AppUser> saveName(String name);

  Future<void> signOut();
}

/// The code was wrong. The user can retry with the same code still outstanding.
class InvalidOtpException implements Exception {
  const InvalidOtpException([this.message = 'That code is not right. Try again.']);

  final String message;

  @override
  String toString() => message;
}

/// The code aged out or was already used — retrying is pointless, a resend is needed.
class OtpExpiredException implements Exception {
  const OtpExpiredException([
    this.message = 'That code has expired. Tap resend to get a new one.',
  ]);

  final String message;

  @override
  String toString() => message;
}

/// The SMS could not be sent. [message] is already safe to show on screen.
class OtpSendException implements Exception {
  const OtpSendException(this.message);

  final String message;

  @override
  String toString() => message;
}
