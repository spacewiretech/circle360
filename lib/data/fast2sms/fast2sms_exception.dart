/// A Fast2SMS call that did not succeed.
///
/// Carries two messages on purpose: [userMessage] is safe to show on screen, [developerDetail]
/// names the real cause (bad key, empty wallet, KYC) and only ever reaches the debug log.
class Fast2SmsException implements Exception {
  const Fast2SmsException({
    required this.code,
    required this.userMessage,
    required this.developerDetail,
  });

  /// Fast2SMS `status_code`, or null for transport-level failures.
  final int? code;
  final String userMessage;
  final String developerDetail;

  /// True when the fix is on the account or in `.env`, not something the user can act on.
  bool get isConfigurationProblem => const {
        400, // Invalid OTP ID
        401, 402, 403, 404, 405, // missing parameters
        406, 407, 408, 409, 410, 414, 417, 424, 425, 426, // invalid parameters
        412, 413, // auth key bad or disabled
        415, 416, // account disabled / no balance
        500, // sender or template blacklisted at DLT
        990, 996, 999, // deprecated API, KYC, wallet minimum
      }.contains(code);

  @override
  String toString() => 'Fast2SmsException($code): $developerDetail';
}

/// Everything the user cannot fix reads the same on screen.
const _unavailable = 'Verification is temporarily unavailable. Please try again later.';

/// Maps a Fast2SMS `status_code` onto the pair of messages.
///
/// Codes are from https://docs.fast2sms.com/reference/error-code-list — anything unlisted
/// falls through to the generic pair rather than surfacing a raw provider string.
Fast2SmsException mapFast2SmsError(int? code, String? providerMessage) {
  final detail = 'Fast2SMS ${code ?? 'transport'}: ${providerMessage ?? 'no message'}';

  final userMessage = switch (code) {
    // Things the user can actually do something about.
    411 => 'That mobile number is not valid.',
    995 => 'Too many codes requested for this number. Please wait a few minutes.',

    // Account, credential and template problems — never explained on screen.
    400 || 401 || 402 || 403 || 404 || 405 => _unavailable,
    406 || 407 || 408 || 409 || 410 || 417 || 424 || 425 || 426 => _unavailable,
    412 || 413 || 414 || 415 || 416 => _unavailable,
    500 || 990 || 996 || 997 || 998 || 999 => _unavailable,

    _ => _unavailable,
  };

  return Fast2SmsException(
    code: code,
    userMessage: userMessage,
    developerDetail: detail,
  );
}
