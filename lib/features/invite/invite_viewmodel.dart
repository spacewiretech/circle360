import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/entitlement.dart';
import '../../data/pending_invite.dart';
import '../../data/providers.dart';
import '../splash/splash_viewmodel.dart';
import 'invite_state.dart';

/// Drives the deeplink-only invite screen.
///
/// [submit] returns the [SplashDestination] the flow resumes at, so a signed-out user goes on
/// to the phone screen while an already-onboarded one lands on Home — and someone stranded
/// mid-onboarding picks up where they left off.
class InviteViewModel extends Notifier<InviteState> {
  @override
  InviteState build() => const InviteState();

  void setPhone(String value) => state = state.copyWith(phone: value, clearError: true);

  Future<SplashDestination?> submit() async {
    if (!state.canSubmit) return null;

    state = state.copyWith(busy: true, clearError: true);
    try {
      final invite = ref.read(pendingInviteProvider);
      await ref.read(inviteRepositoryProvider).sendInvite(
            phone: '+91 ${state.phone}',
            viaCode: invite?.code,
          );

      // Consumed — a later launch without a deeplink must not land here again.
      ref.read(pendingInviteProvider.notifier).clear();

      final user = await ref.read(authRepositoryProvider).currentUser();
      ref.read(entitlementProvider.notifier).set(user);
      state = state.copyWith(busy: false);
      return destinationForSession(
        signedIn: user != null,
        hasName: user?.hasName ?? false,
        entitled: user?.entitled ?? false,
      );
    } catch (_) {
      state = state.copyWith(
        busy: false,
        error: 'Could not send that invite. Please try again.',
      );
      return null;
    }
  }
}

final inviteViewModelProvider =
    NotifierProvider<InviteViewModel, InviteState>(InviteViewModel.new);
