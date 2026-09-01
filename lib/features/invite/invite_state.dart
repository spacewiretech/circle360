import 'package:flutter/foundation.dart';

@immutable
class InviteState {
  const InviteState({this.phone = '', this.busy = false, this.error});

  /// The number of the person being invited — not the user's own.
  final String phone;
  final bool busy;
  final String? error;

  /// Same rule as the onboarding phone step.
  static const phoneLength = 10;

  bool get canSubmit => phone.length == phoneLength && !busy;

  InviteState copyWith({
    String? phone,
    bool? busy,
    String? error,
    bool clearError = false,
  }) {
    return InviteState(
      phone: phone ?? this.phone,
      busy: busy ?? this.busy,
      error: clearError ? null : (error ?? this.error),
    );
  }
}
