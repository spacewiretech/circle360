import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../features/onboarding/onboarding_state.dart';
import '../../../features/onboarding/onboarding_viewmodel.dart';
import '../../../widgets/otp_field.dart';
import '../../app/assets.dart';
import '../../app/router.dart';
import '../../app/theme/sx_colors.dart';
import '../../app/theme/sx_typography.dart';
import '../../data/app_variant.dart';
import '../../data/onboarding_audio.dart';
import '../../widgets/sx_otp_field.dart';
import 'widgets/sx_onboarding_scaffold.dart';

/// Figma `13511:14662` — step 2.
///
/// **The frame draws four circles; this renders [OnboardingState.otpLength], which is six.** The
/// Fast2SMS template issues six-digit codes, so four boxes would be a screen the user cannot
/// finish. The circular styling is the design's; the count is the backend's.
///
/// Adds a resend control the frame does not show, for the same reason Circle360's step does:
/// without it, a user whose SMS never arrives has no way forward.
class SxOtpView extends ConsumerStatefulWidget {
  const SxOtpView({super.key});

  @override
  ConsumerState<SxOtpView> createState() => _SxOtpViewState();
}

class _SxOtpViewState extends ConsumerState<SxOtpView> {
  final _otpController = OtpFieldController();

  Future<void> _submit({bool autoSubmitted = false}) async {
    final next = await ref
        .read(onboardingViewModelProvider.notifier)
        .verifyOtp(autoSubmitted: autoSubmitted);

    if (next == null) {
      // Rejected. Empty the circles so the next attempt starts clean.
      _otpController.clear();
      return;
    }

    // The commitment point. Until now the device was only browsing and could safely be re-judged
    // against a changed rule; from here it has an account in this app, and a later change to the
    // campaign allowlist must not move it into the other one.
    await AppVariant.pin(AppVariant.sunioMax);

    if (mounted) context.go(next.sunioRoute);
  }

  Future<void> _resend() async {
    await ref.read(onboardingViewModelProvider.notifier).resendOtp();
    _otpController.clear();
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(onboardingViewModelProvider);

    return SxOnboardingScaffold(
      backdrop: SxImg.onboardingOtp,
      audioClip: SxAudioClip.otp,
      prompt: 'Please enter verification code',
      field: SxOtpField(
        length: OnboardingState.otpLength,
        controller: _otpController,
        onChanged: ref.read(onboardingViewModelProvider.notifier).setCode,
        onCompleted: (_) => _submit(autoSubmitted: true),
      ),
      footer: Padding(
        padding: const EdgeInsets.only(top: 14),
        child: _Resend(state: state, onResend: _resend),
      ),
      buttonLabel: 'continue',
      analyticsId: 'sx_otp_continue',
      busy: state.busy,
      error: state.error,
      onContinue: state.canVerify ? _submit : null,
    );
  }
}

/// "Resend code", or the countdown until it unlocks.
class _Resend extends StatelessWidget {
  const _Resend({required this.state, required this.onResend});

  final OnboardingState state;
  final VoidCallback onResend;

  @override
  Widget build(BuildContext context) {
    if (state.resendExhausted) {
      return Text(
        'You have used all your resends. Try again later.',
        style: SxText.rowSubtitle,
        textAlign: TextAlign.center,
      );
    }

    if (!state.canResend) {
      return Text(
        'Resend code in ${state.resendCountdownLabel}',
        style: SxText.rowSubtitle,
        textAlign: TextAlign.center,
      );
    }

    return GestureDetector(
      onTap: onResend,
      child: Text(
        'Resend code',
        style: SxText.rowAction.copyWith(color: SxColors.brand),
        textAlign: TextAlign.center,
      ),
    );
  }
}
