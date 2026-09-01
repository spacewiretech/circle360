import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/providers.dart';
import '../../data/repositories/auth_repository.dart';
import 'onboarding_state.dart';

/// Drives phone → OTP → name. Each step returns a bool so the view knows whether to navigate;
/// the ViewModel itself never touches the router.
class OnboardingViewModel extends Notifier<OnboardingState> {
  Timer? _ticker;

  @override
  OnboardingState build() {
    ref.onDispose(() => _ticker?.cancel());
    return const OnboardingState();
  }

  AuthRepository get _auth => ref.read(authRepositoryProvider);

  /// Changing the number invalidates any outstanding code, along with the attempt and resend
  /// budgets that went with it.
  void setPhone(String value) {
    if (value == state.phone) return;
    _ticker?.cancel();
    state = state.copyWith(phone: value, clearError: true).clearingOtpSession();
  }

  void setCode(String value) => state = state.copyWith(code: value, clearError: true);

  void setName(String value) => state = state.copyWith(name: value, clearError: true);

  Future<bool> sendOtp() async {
    if (!state.canSendOtp) return false;
    final sent = await _guard(() => _auth.sendOtp(state.phone));
    if (sent) _startCooldown(resendsUsed: 0);
    return sent;
  }

  /// Asks the provider to redeliver. Resets the attempt budget on success, because a user who
  /// exhausted their tries on a stale code deserves a clean slate with the new one.
  Future<bool> resendOtp() async {
    if (!state.canResend) return false;

    final sent = await _guard(() => _auth.resendOtp(state.phone));
    if (sent) {
      state = state.copyWith(
        code: '',
        attemptsLeft: OnboardingState.maxAttempts,
      );
      _startCooldown(resendsUsed: state.resendsUsed + 1);
    }
    return sent;
  }

  /// Handles its own failures rather than delegating to [_guard], because only a code the
  /// provider actually rejected may burn an attempt — a dropped connection must not.
  Future<bool> verifyOtp() async {
    if (!state.canVerify) return false;

    state = state.copyWith(busy: true, clearError: true);
    try {
      await _auth.verifyOtp(phone: state.phone, code: state.code);
      _ticker?.cancel();
      state = state.copyWith(busy: false);
      return true;
    } on InvalidOtpException catch (e) {
      final left = state.attemptsLeft - 1;
      state = state.copyWith(
        busy: false,
        code: '',
        attemptsLeft: left,
        error: left <= 0
            ? 'Too many incorrect attempts. Tap resend to get a new code.'
            : '${e.message} $left attempt${left == 1 ? '' : 's'} left.',
      );
      return false;
    } on OtpExpiredException catch (e) {
      // The code is gone, so spending an attempt on it would be unfair — unlock resend now.
      _ticker?.cancel();
      state = state.copyWith(
        busy: false,
        code: '',
        error: e.message,
        clearResendAt: true,
      );
      return false;
    } on OtpSendException catch (e) {
      state = state.copyWith(busy: false, error: e.message);
      return false;
    } catch (_) {
      state = state.copyWith(
        busy: false,
        error: 'Something went wrong. Please try again.',
      );
      return false;
    }
  }

  Future<bool> saveName() async {
    if (!state.canSaveName) return false;
    return _guard(() => _auth.saveName(state.name));
  }

  /// Locks resend for the cooldown and ticks once a second so the countdown label moves.
  void _startCooldown({required int resendsUsed}) {
    _ticker?.cancel();
    state = state.copyWith(
      resendsUsed: resendsUsed,
      resendAvailableAt: DateTime.now().add(OnboardingState.resendCooldown),
      now: DateTime.now(),
    );

    _ticker = Timer.periodic(const Duration(seconds: 1), (timer) {
      state = state.copyWith(now: DateTime.now());
      if (state.resendIn == Duration.zero) timer.cancel();
    });
  }

  /// Runs [action] with the busy flag set, turning a throw into [OnboardingState.error].
  Future<bool> _guard(Future<void> Function() action) async {
    state = state.copyWith(busy: true, clearError: true);
    try {
      await action();
      state = state.copyWith(busy: false);
      return true;
    } on InvalidOtpException catch (e) {
      state = state.copyWith(busy: false, error: e.message);
      return false;
    } on OtpExpiredException catch (e) {
      // The code is gone, so spending an attempt on it would be unfair — unlock resend now.
      state = state.copyWith(
        busy: false,
        error: e.message,
        code: '',
        clearResendAt: true,
      );
      _ticker?.cancel();
      return false;
    } on OtpSendException catch (e) {
      state = state.copyWith(busy: false, error: e.message);
      return false;
    } catch (e) {
      state = state.copyWith(busy: false, error: 'Something went wrong. Please try again.');
      return false;
    }
  }
}

final onboardingViewModelProvider =
    NotifierProvider<OnboardingViewModel, OnboardingState>(OnboardingViewModel.new);
