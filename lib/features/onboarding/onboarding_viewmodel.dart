import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/analytics/analytics.dart';
import '../../data/analytics/analytics_events.dart';
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
/// not be walked through the  name step and dropped on the paywall. The ViewModel itself still
/// never touches the router.
class OnboardingViewModel extends Notifier<OnboardingState> {
  Timer? _ticker;

  /// When the code screen last got a fresh code, so `OTP Verified` can report how long the user
  /// actually took. That number is what says whether SMS autofill is working.
  DateTime? _codeSentAt;

  /// Field-entry events fire once per field, not once per keystroke. The setters below run on
  /// every character — and `_startCooldown` mutates state once a second on top of that — so
  /// tracking state changes directly would bury the funnel in noise and cost a fortune in events.
  final Set<String> _fieldsStarted = {};

  @override
  OnboardingState build() {
    ref.onDispose(() => _ticker?.cancel());
    return const OnboardingState();
  }

  AuthRepository get _auth => ref.read(authRepositoryProvider);

  Analytics get _analytics => ref.read(analyticsProvider);

  void _fieldStarted(String field, String event) {
    if (!_fieldsStarted.add(field)) return;
    _analytics.track(event);
  }

  /// Changing the number invalidates any outstanding code, along with the attempt and resend
  /// budgets that went with it.
  void setPhone(String value) {
    if (value == state.phone) return;
    _fieldStarted('phone', Ev.phoneEntryStarted);
    _ticker?.cancel();
    state = state.copyWith(phone: value, clearError: true).clearingOtpSession();

    // Once, when the number first becomes a complete one. Sending this per keystroke would be
    // ten events per user and tell us nothing the last one does not.
    if (state.phoneComplete) {
      _fieldStarted('phone_complete', Ev.phoneNumberEntered);
    }
  }

  void setCode(String value) {
    _fieldStarted('code', Ev.otpEntryStarted);
    state = state.copyWith(code: value, clearError: true);
  }

  void setName(String value) {
    _fieldStarted('name', Ev.nameEntryStarted);
    state = state.copyWith(name: value, clearError: true);
  }

  Future<bool> sendOtp() async {
    if (!state.canSendOtp) return false;

    _analytics.track(Ev.otpRequested, {P.valid: state.phoneValid});

    final sent = await _guard(() async {
      await _auth.sendOtp(state.phone);
      return true;
    });
    if (sent ?? false) {
      _codeSentAt = DateTime.now();
      _startCooldown(resendsUsed: 0);
    } else {
      _analytics.track(Ev.otpRequestFailed, {P.message: state.error});
    }
    return sent ?? false;
  }

  /// Asks the provider to redeliver. Resets the attempt budget on success, because a user who
  /// exhausted their tries on a stale code deserves a clean slate with the new one.
  Future<bool> resendOtp() async {
    if (!state.canResend) {
      // A tap that does nothing. Which of the two reasons it was matters: a cooldown is the
      // system working, and an exhausted budget is a user stuck with no way forward.
      _analytics.track(Ev.otpResendBlocked, {
        P.reason: state.resendExhausted ? 'exhausted' : 'cooldown',
        P.secondsRemaining: state.resendIn.inSeconds,
        P.resendsUsed: state.resendsUsed,
      });
      return false;
    }

    _analytics.track(Ev.otpResendRequested, {P.resendsUsed: state.resendsUsed});

    final sent = await _guard(() async {
      await _auth.resendOtp(state.phone);
      return true;
    });
    if (sent ?? false) {
      state = state.copyWith(
        code: '',
        attemptsLeft: OnboardingState.maxAttempts,
      );
      _codeSentAt = DateTime.now();
      _startCooldown(resendsUsed: state.resendsUsed + 1);
    } else {
      _analytics.track(Ev.otpRequestFailed, {
        P.message: state.error,
        P.trigger: 'resend',
      });
    }
    return sent ?? false;
  }

  /// Handles its own failures rather than delegating to [_guard], because only a code the
  /// provider actually rejected may burn an attempt — a dropped connection must not.
  /// [autoSubmitted] separates the code arriving by SMS autofill from one typed out by hand. The
  /// OTP field submits itself the moment six digits land, so both paths end here and would
  /// otherwise be indistinguishable — and autofill working or not is the single biggest lever on
  /// how many people get through this screen.
  Future<SplashDestination?> verifyOtp({bool autoSubmitted = false}) async {
    if (!state.canVerify) return null;

    state = state.copyWith(busy: true, clearError: true);

    final attemptsUsed = OnboardingState.maxAttempts - state.attemptsLeft + 1;
    _analytics.track(Ev.otpSubmitted, {
      P.entryMethod: autoSubmitted ? 'auto_complete' : 'button',
      P.attemptsUsed: attemptsUsed,
      P.resendsUsed: state.resendsUsed,
    });

    try {
      final user = await _auth.verifyOtp(phone: state.phone, code: state.code);
      _ticker?.cancel();
      final destination = await _destinationFor(user);
      state = state.copyWith(busy: false);

      _analytics.track(Ev.otpVerified, {
        P.entryMethod: autoSubmitted ? 'auto_complete' : 'button',
        P.attemptsUsed: attemptsUsed,
        P.resendsUsed: state.resendsUsed,
        P.isNewUser: !user.hasName,
        P.hasName: user.hasName,
        P.destination: destination.name,
        if (_codeSentAt != null)
          P.secondsToVerify: DateTime.now().difference(_codeSentAt!).inSeconds,
      });
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
      _reportVerifyFailure('invalid', attemptsUsed, left);
      if (left <= 0) {
        _analytics.track(Ev.otpAttemptsExhausted, {P.resendsUsed: state.resendsUsed});
      }
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
      _reportVerifyFailure('expired', attemptsUsed, state.attemptsLeft);
      return null;
    } on OtpSendException catch (e) {
      state = state.copyWith(busy: false, error: e.message);
      _reportVerifyFailure('send_failed', attemptsUsed, state.attemptsLeft);
      return null;
    } catch (error) {
      state = state.copyWith(
        busy: false,
        error: 'Something went wrong. Please try again.',
      );
      _reportVerifyFailure('unknown', attemptsUsed, state.attemptsLeft, error);
      return null;
    }
  }

  /// One event, four reasons. The branches above already distinguish them for the user-facing
  /// copy; this keeps that distinction where it can be counted, because "the OTP screen loses
  /// people" and "our codes expire before the SMS lands" call for completely different fixes.
  void _reportVerifyFailure(
    String reason,
    int attemptsUsed,
    int attemptsLeft, [
    Object? error,
  ]) {
    _analytics.track(Ev.otpVerificationFailed, {
      P.reason: reason,
      P.attemptsUsed: attemptsUsed,
      P.attemptsLeft: attemptsLeft,
      P.resendsUsed: state.resendsUsed,
      if (error != null) P.error: error.toString(),
      if (_codeSentAt != null)
        P.secondsToVerify: DateTime.now().difference(_codeSentAt!).inSeconds,
    });
  }

  Future<SplashDestination?> saveName() async {
    if (!state.canSaveName) return null;

    _analytics.track(Ev.nameSubmitted, {P.nameLength: state.name.trim().length});

    final destination =
        await _guard(() async => _destinationFor(await _auth.saveName(state.name)));

    if (destination == null) {
      _analytics.track(Ev.nameSaveFailed, {P.message: state.error});
      return null;
    }

    // The end of onboarding proper. Everything past here is the paywall's funnel, not this one.
    _analytics.track(Ev.signupCompleted, {P.destination: destination.name});
    return destination;
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
