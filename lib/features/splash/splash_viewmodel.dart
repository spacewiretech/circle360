import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/entitlement.dart';
import '../../data/pending_invite.dart';
import '../../data/providers.dart';
import '../../location_service.dart';

/// Where the app should land once the splash has resolved the stored session.
enum SplashDestination { invite, onboarding, name, subscribe, location, home }

/// Where onboarding resumes for [user], ignoring any deeplink.
///
/// Shared with the invite screen so that, once an invite is dealt with, the user rejoins the
/// flow at the same step the splash would have sent them to.
SplashDestination destinationForSession({
  required bool signedIn,
  required bool hasName,
  required bool entitled,
  bool locationAnswered = true,
}) {
  if (!signedIn) return SplashDestination.onboarding;
  if (!hasName) return SplashDestination.name;
  // Entitlement is computed by the server from payment_type plus the trial and period dates —
  // a trial that has lapsed lands here exactly like an account that never paid.
  if (!entitled) return SplashDestination.subscribe;
  // Asked once, on the first launch that gets this far. `locationAnswered` is true as soon as
  // the OS has an answer of any kind — including "no" — so a refusal is never re-prompted here;
  // Home's banner is what offers it again.
  if (!locationAnswered) return SplashDestination.location;
  return SplashDestination.home;
}

final splashDestinationProvider = FutureProvider.autoDispose<SplashDestination>((ref) async {
  // The cold-start link has to resolve before the branch, or the splash would fall through to
  // the phone screen while the invite was still arriving.
  await ref.watch(deeplinkListenerProvider.future);
  if (ref.watch(pendingInviteProvider) != null) return SplashDestination.invite;

  final user = await ref.watch(authRepositoryProvider).currentUser();
  // Cached-user fallbacks are re-derived from their stored dates by SessionStore, so an offline
  // launch cannot walk in on an entitlement that expired while the device had no signal.
  ref.read(entitlementProvider.notifier).set(user);

  // Read straight from the OS rather than from a stored flag: the user can revoke permission
  // in Settings between launches, and a "we already asked" flag would then be wrong forever.
  var locationAnswered = true;
  if (user != null && user.entitled) {
    final status = await ref.read(locationServiceProvider).getStatus().catchError(
          // No platform channel (a test, or an unsupported platform) must not strand the
          // splash on a permission screen it cannot resolve.
          (_) => TrackingStatus.unknown,
        );
    locationAnswered = status.permission != LocationPermission.notRequested;
  }

  return destinationForSession(
    signedIn: user != null,
    hasName: user?.hasName ?? false,
    entitled: user?.entitled ?? false,
    locationAnswered: locationAnswered,
  );
});
