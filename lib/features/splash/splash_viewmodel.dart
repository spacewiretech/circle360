import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/analytics/analytics_events.dart';
import '../../data/entitlement.dart';
import '../../data/models/app_user.dart';
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

/// [destinationForSession] for a resolved [user], asking the OS about location on the way.
///
/// Every step that ends holding a fresh [AppUser] routes through this, so the splash, the OTP
/// step and the name step cannot disagree about where the same user belongs. Routing by step
/// order instead is what used to send a returning trial user to the paywall: they had already
/// paid, and only a cold start — which did come through here — put them right.
Future<SplashDestination> destinationForUser({
  required AppUser? user,
  required LocationService locationService,
}) async {
  // Read straight from the OS rather than from a stored flag: the user can revoke permission
  // in Settings between launches, and a "we already asked" flag would then be wrong forever.
  var locationAnswered = true;
  if (user != null && user.entitled) {
    final status = await locationService.getStatus().catchError(
          // No platform channel (a test, or an unsupported platform) must not strand the
          // caller on a permission screen it cannot resolve.
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
}

final splashDestinationProvider = FutureProvider.autoDispose<SplashDestination>((ref) async {
  final started = DateTime.now();
  final analytics = ref.read(analyticsProvider);

  // The cold-start link has to resolve before the branch, or the splash would fall through to
  // the phone screen while the invite was still arriving.
  await ref.watch(deeplinkListenerProvider.future);

  final invite = ref.watch(pendingInviteProvider);
  if (invite != null) {
    // Acquisition attribution: the inviter's name and the code are the only evidence the app
    // ever gets that a user arrived through someone else rather than on their own.
    analytics.track(Ev.deepLinkOpened, {
      P.linkType: 'invite',
      P.code: invite.code,
      P.inviterName: invite.inviterName,
      P.coldStart: true,
    });
    analytics.track(Ev.splashResolved, {
      P.destination: SplashDestination.invite.name,
      P.ms: DateTime.now().difference(started).inMilliseconds,
    });
    return SplashDestination.invite;
  }

  final user = await ref.watch(authRepositoryProvider).currentUser();
  // Cached-user fallbacks are re-derived from their stored dates by SessionStore, so an offline
  // launch cannot walk in on an entitlement that expired while the device had no signal.
  ref.read(entitlementProvider.notifier).set(user);

  final destination = await destinationForUser(
    user: user,
    locationService: ref.read(locationServiceProvider),
  );

  // Where returning users actually land, and how long they waited to find out. This is the
  // denominator for every other funnel in the app — a session that resolves to `home` never
  // enters the onboarding or paywall funnels at all, and counting it in them understates both.
  analytics.track(Ev.splashResolved, {
    P.destination: destination.name,
    P.isSignedIn: user != null,
    P.entitled: user?.entitled ?? false,
    P.hasName: user?.hasName ?? false,
    P.paymentType: user?.paymentType.name,
    P.ms: DateTime.now().difference(started).inMilliseconds,
  });

  return destination;
});
