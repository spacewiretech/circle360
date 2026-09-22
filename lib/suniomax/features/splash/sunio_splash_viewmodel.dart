import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../data/analytics/analytics_events.dart';
import '../../../data/entitlement.dart';
import '../../../data/providers.dart';
import '../../data/providers.dart';

/// Where SunioMax should land once the splash has resolved the stored session.
///
/// Mirrors Circle360's `SplashDestination`, with two differences that are the whole of the
/// product difference at this stage: a language step in front, and no location step — SunioMax
/// never asks for a position.
enum SunioDestination { language, onboarding, name, subscribe, home }

/// Where SunioMax resumes for a given user.
///
/// A free function, like `destinationForSession`, so the order is testable without a container.
/// Language comes first because it is the only step that does not need an account, and asking it
/// before the phone number is what the design does — a user who abandons at the OTP has still
/// told us which language to advertise in.
SunioDestination sunioDestinationForSession({
  required bool languageChosen,
  required bool signedIn,
  required bool hasName,
  required bool entitled,
}) {
  if (!languageChosen) return SunioDestination.language;
  if (!signedIn) return SunioDestination.onboarding;
  if (!hasName) return SunioDestination.name;
  // Same authority as Circle360: entitlement is the server's answer, computed from payment_type
  // and the trial and period dates. A lapsed trial lands here like an account that never paid.
  if (!entitled) return SunioDestination.subscribe;
  return SunioDestination.home;
}

/// The destination for this launch.
///
/// Deliberately does not consult the deeplink: SunioMax has no invite flow, and the `loc360://`
/// links belong to the other app. A SunioMax install that somehow receives one ignores it.
final sunioSplashDestinationProvider = FutureProvider.autoDispose<SunioDestination>((
  ref,
) async {
  final started = DateTime.now();
  final analytics = ref.read(analyticsProvider);

  final language = await ref.watch(selectedLanguageProvider.future);
  final user = await ref.watch(authRepositoryProvider).currentUser();

  // Cached-user fallbacks are re-derived from their stored dates by SessionStore, so an offline
  // launch cannot walk in on an entitlement that expired while the device had no signal.
  ref.read(entitlementProvider.notifier).set(user);

  final destination = sunioDestinationForSession(
    languageChosen: language != null,
    signedIn: user != null,
    hasName: user?.hasName ?? false,
    entitled: user?.entitled ?? false,
  );

  // The denominator for every SunioMax funnel, exactly as `Splash Resolved` is for Circle360 —
  // and separable from it by the `app` super property alone.
  analytics.track(Ev.splashResolved, {
    P.destination: destination.name,
    P.isSignedIn: user != null,
    P.entitled: user?.entitled ?? false,
    P.hasName: user?.hasName ?? false,
    P.paymentType: user?.paymentType.name,
    P.appLocale: language?.code,
    P.ms: DateTime.now().difference(started).inMilliseconds,
  });

  return destination;
});
