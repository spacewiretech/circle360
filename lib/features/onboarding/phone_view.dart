import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/router.dart';
import '../../widgets/phone_field.dart';
import 'onboarding_viewmodel.dart';
import 'widgets/onboarding_scaffold.dart';

/// Figma `12310:11223` — step 1 of 3.
class PhoneView extends ConsumerStatefulWidget {
  const PhoneView({super.key});

  @override
  ConsumerState<PhoneView> createState() => _PhoneViewState();
}

class _PhoneViewState extends ConsumerState<PhoneView> {
  final _controller = TextEditingController();

  @override
  void initState() {
    super.initState();
    _controller.text = ref.read(onboardingViewModelProvider).phone;
    _controller.addListener(
      () => ref.read(onboardingViewModelProvider.notifier).setPhone(_controller.text),
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final sent = await ref.read(onboardingViewModelProvider.notifier).sendOtp();
    if (sent && mounted) context.push(Routes.otp);
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(onboardingViewModelProvider);

    // Only nag once the number is long enough to judge — not on every keystroke.
    final invalidNumber = state.phoneComplete && !state.phoneValid
        ? 'Enter a valid Indian mobile number.'
        : null;

    return OnboardingScaffold(
      prompt: 'Please enter your number',
      field: PhoneField(
        controller: _controller,
        onSubmitted: (_) => state.canSendOtp ? _submit() : null,
      ),
      buttonLabel: 'continue',
      busy: state.busy,
      error: state.error ?? invalidNumber,
      onContinue: state.canSendOtp ? _submit : null,
    );
  }
}
