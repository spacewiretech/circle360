import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'models/app_user.dart';
import 'providers.dart';

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

  void set(AppUser? user) {
    state = user;
    // The single analytics identity hook. Every path that ends holding a fresh user comes
    // through here — the splash, OTP verification, saving a name, the invite step, the
    // entitlement gate on mount and on every resume, and the payment poll — so binding the
    // Mixpanel profile here means no caller has to remember to. The implementation ignores a
    // repeat of the same id, which matters because the gate re-resolves on every resume.
    if (user != null) ref.read(analyticsProvider).identify(user);
  }

  void clear() => state = null;
}

final entitlementProvider =
    NotifierProvider<EntitlementNotifier, AppUser?>(EntitlementNotifier.new);
