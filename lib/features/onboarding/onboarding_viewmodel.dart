import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/entitlement.dart';
import '../../data/models/app_user.dart';
import '../../data/providers.dart';
import '../../data/repositories/auth_repository.dart';
import '../splash/splash_viewmodel.dart';
import 'onboarding_state.dart';

/// Drives phone → OTP → name.
///
/// The steps that end holding a user return the [SplashDestination] the flow resumes at rather
/// than a bare "it worked", because step order is not the same thing as where the user belongs:
/// someone who signs in again on a wiped device already has a name and a live trial, and must
/// not be walked through the name step and dropped on the paywall. The ViewModel itself still
/// never touches the router.
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
    final sent = await _guard(() async {
      await _auth.sendOtp(state.phone);
      return true;
    });
    if (sent ?? false) _startCooldown(resendsUsed: 0);
    return sent ?? false;
  }

  /// Asks the provider to redeliver. Resets the attempt budget on success, because a user who
  /// exhausted their tries on a stale code deserves a clean slate with the new one.
  Future<bool> resendOtp() async {
    if (!state.canResend) return false;

    final sent = await _guard(() async {
      await _auth.resendOtp(state.phone);
      return true;
    });
    if (sent ?? false) {
      state = state.copyWith(
        code: '',
        attemptsLeft: OnboardingState.maxAttempts,
      );
      _startCooldown(resendsUsed: state.resendsUsed + 1);
    }
    return sent ?? false;
  }

  /// Handles its own failures rather than delegating to [_guard], because only a code the
  /// provider actually rejected may burn an attempt — a dropped connection must not.
  Future<SplashDestination?> verifyOtp() async {
    if (!state.canVerify) return null;

    state = state.copyWith(busy: true, clearError: true);
    try {
      final user = await _auth.verifyOtp(phone: state.phone, code: state.code);
      _ticker?.cancel();
      final destination = await _destinationFor(user);
      state = state.copyWith(busy: false);
      return destination;
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
      return null;
    } on OtpExpiredException catch (e) {
      // The code is gone, so spending an attempt on it would be unfair — unlock resend now.
      _ticker?.cancel();
      state = state.copyWith(
        busy: false,
        code: '',
        error: e.message,
        clearResendAt: true,
      );
      return null;
    } on OtpSendException catch (e) {
      state = state.copyWith(busy: false, error: e.message);
      return null;
    } catch (_) {
      state = state.copyWith(
        busy: false,
        error: 'Something went wrong. Please try again.',
      );
      return null;
    }
  }

  Future<SplashDestination?> saveName() async {
    if (!state.canSaveName) return null;
    return _guard(() async => _destinationFor(await _auth.saveName(state.name)));
  }

  /// Where the flow goes next for [user], asking the OS about location on the way.
  ///
  /// Shares [destinationForUser] with the splash so a user who signs in again lands exactly
  /// where a cold start would have put them.
  Future<SplashDestination> _destinationFor(AppUser user) {
    ref.read(entitlementProvider.notifier).set(user);
    return destinationForUser(
      user: user,
      locationService: ref.read(locationServiceProvider),
    );
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
  ///
  /// Returns null when [action] threw, so a caller that produces a value can use null as its
  /// "did not get there" answer instead of carrying a second flag.
  Future<T?> _guard<T extends Object>(Future<T> Function() action) async {
    state = state.copyWith(busy: true, clearError: true);
    try {
      final result = await action();
      state = state.copyWith(busy: false);
      return result;
    } on InvalidOtpException catch (e) {
      state = state.copyWith(busy: false, error: e.message);
      return null;
    } on OtpExpiredException catch (e) {
      // The code is gone, so spending an attempt on it would be unfair — unlock resend now.
      state = state.copyWith(
        busy: false,
        error: e.message,
        code: '',
        clearResendAt: true,
      );
      _ticker?.cancel();
      return null;
    } on OtpSendException catch (e) {
      state = state.copyWith(busy: false, error: e.message);
      return null;
    } catch (e) {
      state = state.copyWith(busy: false, error: 'Something went wrong. Please try again.');
      return null;
    }
  }
}

final onboardingViewModelProvider =
    NotifierProvider<OnboardingViewModel, OnboardingState>(OnboardingViewModel.new);
