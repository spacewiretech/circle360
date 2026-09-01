import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:loc_360/app/assets.dart';

import '../../app/router.dart';
import '../../app/theme/app_colors.dart';
import '../../app/theme/app_typography.dart';
import '../../widgets/otp_field.dart';
import 'onboarding_state.dart';
import 'onboarding_viewmodel.dart';
import 'widgets/onboarding_scaffold.dart';

/// Figma `12310:11248` — step 2 of 3.
///
/// Adds a resend control the frame does not show: without it, a user whose SMS never arrives
/// has no way forward.
class OtpView extends ConsumerStatefulWidget {
  const OtpView({super.key});

  static const _heroWidthRatio = 266 / 0.9591 / 412;

  @override
  ConsumerState<OtpView> createState() => _OtpViewState();
}

class _OtpViewState extends ConsumerState<OtpView> {
  final _otpController = OtpFieldController();

  Future<void> _submit() async {
    final next = await ref.read(onboardingViewModelProvider.notifier).verifyOtp();
    if (!mounted) return;
    if (next == null) {
      // The ViewModel has already dropped the code; clear the boxes to match and refocus.
      _otpController.clear();
      return;
    }
    // Where the *user* belongs, not the next step in the form. Someone signing in again on a
    // wiped device already has a name and a live trial, and belongs on Home — walking them
    // through the name step would end at the paywall asking them to pay a second time.
    context.go(next.route);
  }

  Future<void> _resend() async {
    await ref.read(onboardingViewModelProvider.notifier).resendOtp();
    if (mounted) _otpController.clear();
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(onboardingViewModelProvider);
    final viewModel = ref.read(onboardingViewModelProvider.notifier);
    final heroWidth = MediaQuery.sizeOf(context).width * OtpView._heroWidthRatio;

    return OnboardingScaffold(
      hero: Image.asset(
        Img.inviteHero,
        width: heroWidth,
        // Height follows the asset's own aspect; the sheet crops whatever hangs below.
        fit: BoxFit.fitWidth,
      ),
      prompt: state.phone.isEmpty
          ? 'Please enter verification code'
          : 'Enter the code sent to +91 ${state.phone}',
      field: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          OtpField(
            length: OnboardingState.otpLength,
            controller: _otpController,
            onChanged: viewModel.setCode,
            onCompleted: (_) => _submit(),
          ),
          const SizedBox(height: 12),
          _ResendRow(state: state, onResend: _resend),
        ],
      ),
      buttonLabel: 'continue',
      busy: state.busy,
      error: state.error,
      onContinue: state.canVerify ? _submit : null,
    );
  }
}

/// "Resend code in 0:30" while locked, a tappable "Resend code" once the cooldown clears.
class _ResendRow extends StatelessWidget {
  const _ResendRow({required this.state, required this.onResend});

  final OnboardingState state;
  final VoidCallback onResend;

  @override
  Widget build(BuildContext context) {
    if (state.resendExhausted) {
      return Text(
        'No more codes can be sent right now. Please try again later.',
        style: AppText.meta,
      );
    }

    // Only a running cooldown gets a countdown. While a request is in flight the label stays
    // put and simply greys out — a "0:00" countdown would be nonsense.
    if (state.resendIn > Duration.zero) {
      return Text(
        'Resend code in ${state.resendCountdownLabel}',
        style: AppText.meta,
      );
    }

    return Align(
      alignment: Alignment.centerLeft,
      child: GestureDetector(
        onTap: state.canResend ? onResend : null,
        behavior: HitTestBehavior.opaque,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Text(
            'Resend code',
            style: AppText.meta.copyWith(
              color: state.canResend ? AppColors.brand : AppColors.muted,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ),
    );
  }
}
