import 'package:flutter/foundation.dart';

import '../../data/fast2sms/fast2sms_client.dart';

/// The three onboarding steps share one state object because the phone number entered in
/// step 1 is what step 2 verifies.
@immutable
class OnboardingState {
  const OnboardingState({
    this.phone = '',
    this.code = '',
    this.name = '',
    this.busy = false,
    this.error,
    this.attemptsLeft = maxAttempts,
    this.resendsUsed = 0,
    this.resendAvailableAt,
    this.now,
  });

  final String phone;
  final String code;
  final String name;
  final bool busy;
  final String? error;

  /// Wrong codes remaining before a resend is required.
  final int attemptsLeft;
  final int resendsUsed;

  /// Wall-clock instant the resend unlocks, so the countdown survives backgrounding rather
  /// than counting ticks the app did not receive.
  final DateTime? resendAvailableAt;

  /// Injected by the ViewModel's ticker so the countdown recomputes; never set by views.
  final DateTime? now;

  static const otpLength = Fast2SmsClient.otpLength;
  static const phoneLength = 10;

  /// Fast2SMS caps resends at 5 per 10-minute window.
  static const maxResends = 5;
  static const maxAttempts = 5;
  static const resendCooldown = Duration(seconds: 30);

  /// Indian mobile numbers are 10 digits starting 6–9.
  static bool isValidIndianMobile(String value) =>
      RegExp(r'^[6-9]\d{9}$').hasMatch(value);

  bool get phoneComplete => phone.length == phoneLength;

  bool get phoneValid => isValidIndianMobile(phone);

  bool get canSendOtp => phoneValid && !busy;

  bool get outOfAttempts => attemptsLeft <= 0;

  bool get canVerify => code.length == otpLength && !busy && !outOfAttempts;

  bool get canSaveName => name.trim().isNotEmpty && !busy;

  Duration get resendIn {
    if (resendAvailableAt == null) return Duration.zero;
    final remaining = resendAvailableAt!.difference(now ?? DateTime.now());
    return remaining.isNegative ? Duration.zero : remaining;
  }

  bool get resendExhausted => resendsUsed >= maxResends;

  bool get canResend => !busy && resendIn == Duration.zero && !resendExhausted;

  /// "0:30"
  String get resendCountdownLabel {
    final seconds = resendIn.inSeconds;
    return '${seconds ~/ 60}:${(seconds % 60).toString().padLeft(2, '0')}';
  }

  OnboardingState copyWith({
    String? phone,
    String? code,
    String? name,
    bool? busy,
    String? error,
    bool clearError = false,
    int? attemptsLeft,
    int? resendsUsed,
    DateTime? resendAvailableAt,
    bool clearResendAt = false,
    DateTime? now,
  }) {
    return OnboardingState(
      phone: phone ?? this.phone,
      code: code ?? this.code,
      name: name ?? this.name,
      busy: busy ?? this.busy,
      error: clearError ? null : (error ?? this.error),
      attemptsLeft: attemptsLeft ?? this.attemptsLeft,
      resendsUsed: resendsUsed ?? this.resendsUsed,
      resendAvailableAt:
          clearResendAt ? null : (resendAvailableAt ?? this.resendAvailableAt),
      now: now ?? this.now,
    );
  }

  /// Everything about the outstanding code, dropped when the number changes.
  OnboardingState clearingOtpSession() => OnboardingState(
        phone: phone,
        name: name,
        busy: busy,
      );
}
