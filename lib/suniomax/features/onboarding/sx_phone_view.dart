import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../features/onboarding/onboarding_viewmodel.dart';
import '../../app/assets.dart';
import '../../app/router.dart';
import '../../data/onboarding_audio.dart';
import '../../widgets/sx_otp_field.dart';
import 'widgets/sx_onboarding_scaffold.dart';

/// Figma `13511:14622` — step 1 of 3.
///
/// Drives Circle360's `OnboardingViewModel` unchanged: the two apps verify the same numbers
/// against the same Fast2SMS account through the same Edge Functions, so the rules about
/// attempts, resend cooldowns and valid Indian mobiles are one implementation, not two.
class SxPhoneView extends ConsumerStatefulWidget {
  const SxPhoneView({super.key});

  @override
  ConsumerState<SxPhoneView> createState() => _SxPhoneViewState();
}

class _SxPhoneViewState extends ConsumerState<SxPhoneView> {
  final _controller = TextEditingController();

  @override
  void initState() {
    super.initState();
    _controller.text = ref.read(onboardingViewModelProvider).phone;
    _controller.addListener(
      () => ref
          .read(onboardingViewModelProvider.notifier)
          .setPhone(_controller.text),
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final sent = await ref.read(onboardingViewModelProvider.notifier).sendOtp();
    if (sent && mounted) context.push(SxRoutes.otp);
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(onboardingViewModelProvider);

    return SxOnboardingScaffold(
      backdrop: SxImg.onboardingPhone,
      audioClip: SxAudioClip.phone,
      prompt: 'Please enter your number',
      field: SxPhoneField(
        controller: _controller,
        onSubmitted: (_) => state.canSendOtp ? _submit() : null,
      ),
      buttonLabel: 'continue',
      analyticsId: 'sx_phone_continue',
      busy: state.busy,
      // Only complain once there is a whole number to complain about — the field is invalid for
      // the first nine of the ten digits it takes, and saying so on every keystroke is noise.
      error:
          state.error ??
          (state.phoneComplete && !state.phoneValid
              ? 'Enter a valid 10-digit mobile number'
              : null),
      onContinue: state.canSendOtp ? _submit : null,
    );
  }
}
