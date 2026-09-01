import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'models/invite_link.dart';
import 'providers.dart';

/// The invite the app was opened with and has not acted on yet.
///
/// Holding it here rather than reading the deeplink inside `splashDestinationProvider` keeps
/// that provider free of side effects: the service writes, the screens read and clear.
class PendingInvite extends Notifier<InviteLink?> {
  @override
  InviteLink? build() => null;

  void set(InviteLink invite) => state = invite;

  void clear() => state = null;
}

final pendingInviteProvider =
    NotifierProvider<PendingInvite, InviteLink?>(PendingInvite.new);

/// Starts listening for deeplinks and feeds [pendingInviteProvider].
///
/// Watched once by the app shell. Resolving the cold-start link before the splash finishes is
/// what lets the splash branch to the invite screen on the first frame.
final deeplinkListenerProvider = FutureProvider<void>((ref) async {
  final service = ref.watch(deeplinkServiceProvider);

  final subscription = service.invites().listen(
        (invite) => ref.read(pendingInviteProvider.notifier).set(invite),
      );
  ref.onDispose(subscription.cancel);

  final initial = await service.initialInvite();
  if (initial != null) ref.read(pendingInviteProvider.notifier).set(initial);
});
