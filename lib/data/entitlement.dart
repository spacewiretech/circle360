import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'models/app_user.dart';

/// The last entitlement answer the server gave, held where the routing layer can read it
/// synchronously.
///
/// Deliberately *not* recomputed on write. While the app is online the server's answer is the
/// authority, grace window and all; re-deriving it here would let the client disagree with the
/// backend the moment `entitlement_grace_hours` is tuned. Offline re-derivation happens in one
/// place only — [SessionStore], where there is no server to ask.
class EntitlementNotifier extends Notifier<AppUser?> {
  @override
  AppUser? build() => null;

  void set(AppUser? user) => state = user;

  void clear() => state = null;
}

final entitlementProvider =
    NotifierProvider<EntitlementNotifier, AppUser?>(EntitlementNotifier.new);
