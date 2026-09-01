import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/assets.dart';
import '../../app/router.dart';
import '../../widgets/phone_field.dart';
import '../onboarding/widgets/onboarding_scaffold.dart';
import 'invite_viewmodel.dart';

/// Figma `12362:12297` — reached only when a deeplink brought the app up.
///
/// Collects the number of the person to invite, then hands back to the normal flow.
class InviteView extends ConsumerStatefulWidget {
  const InviteView({super.key});

  /// The mockup reads as 266 wide in the 412 frame, but the export carries a transparent
  /// margin — only 95.91% of its 562px width is opaque. The layout box is widened to match so
  /// the *visible* phone lands at the designed width.
  static const _heroWidthRatio = 266 / 0.9591 / 412;

  @override
  ConsumerState<InviteView> createState() => _InviteViewState();
}

class _InviteViewState extends ConsumerState<InviteView> {
  final _controller = TextEditingController();

  @override
  void initState() {
    super.initState();
    _controller.text = ref.read(inviteViewModelProvider).phone;
    _controller.addListener(
      () => ref.read(inviteViewModelProvider.notifier).setPhone(_controller.text),
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final next = await ref.read(inviteViewModelProvider.notifier).submit();
    if (next != null && mounted) context.go(next.route);
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(inviteViewModelProvider);
    final heroWidth = MediaQuery.sizeOf(context).width * InviteView._heroWidthRatio;

    return OnboardingScaffold(
      hero: Image.asset(
        Img.inviteHero,
        width: heroWidth,
        // Height follows the asset's own aspect; the sheet crops whatever hangs below.
        fit: BoxFit.fitWidth,
      ),
      prompt: 'Please enter the phone number of the person you want to invite.',
      field: PhoneField(
        controller: _controller,
        onSubmitted: (_) => state.canSubmit ? _submit() : null,
      ),
      buttonLabel: 'Continue',
      busy: state.busy,
      error: state.error,
      onContinue: state.canSubmit ? _submit : null,
    );
  }
}
