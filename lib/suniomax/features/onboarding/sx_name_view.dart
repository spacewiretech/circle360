import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../features/onboarding/onboarding_viewmodel.dart';
import '../../app/assets.dart';
import '../../app/router.dart';
import '../../data/onboarding_audio.dart';
import '../../widgets/sx_otp_field.dart';
import 'widgets/sx_onboarding_scaffold.dart';

/// Figma `13511:14645` — step 3, then straight to the paywall.
class SxNameView extends ConsumerStatefulWidget {
  const SxNameView({super.key});

  @override
  ConsumerState<SxNameView> createState() => _SxNameViewState();
}

class _SxNameViewState extends ConsumerState<SxNameView> {
  final _controller = TextEditingController();

  @override
  void initState() {
    super.initState();
    _controller.text = ref.read(onboardingViewModelProvider).name;
    _controller.addListener(
      () => ref
          .read(onboardingViewModelProvider.notifier)
          .setName(_controller.text),
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final next = await ref
        .read(onboardingViewModelProvider.notifier)
        .saveName();
    if (next != null && mounted) context.go(next.sunioRoute);
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(onboardingViewModelProvider);

    return SxOnboardingScaffold(
      backdrop: SxImg.onboardingName,
      audioClip: SxAudioClip.name,
      prompt: 'Please enter your name',
      field: SxTextFieldBox(
        controller: _controller,
        hint: 'Enter your name',
        onSubmitted: (_) => state.canSaveName ? _submit() : null,
      ),
      buttonLabel: 'continue',
      analyticsId: 'sx_name_continue',
      busy: state.busy,
      error: state.error,
      onContinue: state.canSaveName ? _submit : null,
    );
  }
}
