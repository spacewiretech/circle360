import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/router.dart';
import '../../widgets/phone_field.dart';
import 'onboarding_viewmodel.dart';
import 'widgets/onboarding_scaffold.dart';

/// Figma `12310:11274` — step 3 of 3, then straight to the paywall.
class NameView extends ConsumerStatefulWidget {
  const NameView({super.key});

  @override
  ConsumerState<NameView> createState() => _NameViewState();
}

class _NameViewState extends ConsumerState<NameView> {
  final _controller = TextEditingController();

  @override
  void initState() {
    super.initState();
    _controller.text = ref.read(onboardingViewModelProvider).name;
    _controller.addListener(
      () => ref.read(onboardingViewModelProvider.notifier).setName(_controller.text),
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final saved = await ref.read(onboardingViewModelProvider.notifier).saveName();
    if (saved && mounted) context.go(Routes.subscribe);
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(onboardingViewModelProvider);

    return OnboardingScaffold(
      prompt: 'Please enter your name',
      field: TextFieldBox(
        controller: _controller,
        hint: 'Enter your name',
        onSubmitted: (_) => state.canSaveName ? _submit() : null,
      ),
      buttonLabel: 'continue',
      busy: state.busy,
      error: state.error,
      onContinue: state.canSaveName ? _submit : null,
    );
  }
}
