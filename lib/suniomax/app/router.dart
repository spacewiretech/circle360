import 'package:firebase_analytics/firebase_analytics.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:go_router/go_router.dart';

import '../../app/analytics_observer.dart';
import '../../app/entitlement_gate.dart';
import '../../features/payment_status/payment_outcome.dart';
import '../../features/splash/splash_viewmodel.dart' show SplashDestination;
import '../features/home/voice_lock_view.dart';
import '../features/language/language_view.dart';
import '../features/onboarding/sx_name_view.dart';
import '../features/onboarding/sx_otp_view.dart';
import '../features/onboarding/sx_phone_view.dart';
import '../features/payment_status/sx_payment_status_view.dart';
import '../features/settings/sx_settings_view.dart';
import '../features/splash/sunio_splash_view.dart';
import '../features/splash/sunio_splash_viewmodel.dart';
import '../features/subscription/sx_subscription_view.dart';
import 'routes.dart';

/// Re-exported so a screen needs one import for both the paths and the destination mapping.
export 'routes.dart';

/// The route each resolved destination maps to.
extension SunioDestinationRoute on SunioDestination {
  String get route => switch (this) {
    SunioDestination.language => SxRoutes.language,
    SunioDestination.onboarding => SxRoutes.phone,
    SunioDestination.name => SxRoutes.name,
    SunioDestination.subscribe => SxRoutes.subscribe,
    SunioDestination.home => SxRoutes.home,
  };
}

/// Circle360's `SplashDestination`, translated into SunioMax routes.
///
/// Needed because SunioMax's onboarding runs on Circle360's `OnboardingViewModel` — the phone,
/// OTP and name steps talk to the same backend and return the same answer — and that ViewModel
/// speaks in `SplashDestination`. Only the screens differ, so only the mapping does.
///
/// Named `sunioRoute` rather than `route` so it cannot collide with `SplashDestinationRoute` in
/// `lib/app/router.dart`, which extends the same enum.
///
/// Two destinations have no SunioMax equivalent and both resolve to Home: `location`, because
/// SunioMax never asks for a position, and `invite`, because it has no invite flow.
extension SplashDestinationSunioRoute on SplashDestination {
  String get sunioRoute => switch (this) {
    SplashDestination.onboarding => SxRoutes.phone,
    SplashDestination.name => SxRoutes.name,
    SplashDestination.subscribe => SxRoutes.subscribe,
    SplashDestination.invite => SxRoutes.home,
    SplashDestination.location => SxRoutes.home,
    SplashDestination.home => SxRoutes.home,
  };
}

/// Flat, with no global redirect — the same shape as `appRouter`, for the same reason: the splash
/// resolves the session and each step decides where it goes next.
final sunioRouter = GoRouter(
  initialLocation: SxRoutes.splash,
  observers: [
    // The same observer instance Circle360 uses. One stack, one ambient `screen` property, and
    // one place that knows what a screen is called.
    analyticsObserver,
    // Guarded exactly as `lib/app/router.dart:76` is, and for exactly the same reason: this is a
    // top-level final built the moment anything imports the file, and a test that imports it
    // without booting Firebase would otherwise die at import time with `[core/no-app]`.
    if (Firebase.apps.isNotEmpty)
      FirebaseAnalyticsObserver(analytics: FirebaseAnalytics.instance),
  ],
  routes: [
    GoRoute(
      path: SxRoutes.splash,
      builder: (context, state) => const SunioSplashView(),
    ),
    GoRoute(
      path: SxRoutes.language,
      builder: (context, state) => const LanguageView(),
    ),
    GoRoute(
      path: SxRoutes.phone,
      builder: (context, state) => const SxPhoneView(),
    ),
    GoRoute(path: SxRoutes.otp, builder: (context, state) => const SxOtpView()),
    GoRoute(
      path: SxRoutes.name,
      builder: (context, state) => const SxNameView(),
    ),
    GoRoute(
      path: SxRoutes.subscribe,
      builder: (context, state) => const SxSubscriptionView(),
    ),

    // Ungated, for the same reason Circle360's is: a failed or pending payment is precisely the
    // case where the user is not entitled, and gating it would bounce them back to the paywall
    // they just came from without ever showing them what happened.
    GoRoute(
      path: SxRoutes.paymentStatus,
      builder: (context, state) => SxPaymentStatusView(
        outcome: PaymentOutcome.parse(state.pathParameters['outcome']),
      ),
    ),

    // The only screen behind the paywall. `EntitlementGate` is shared with Circle360 and routes
    // by variant, so a lapsed SunioMax user lands on `/sx/subscribe` rather than Circle360's.
    GoRoute(
      path: SxRoutes.settings,
      builder: (context, state) =>
          const EntitlementGate(child: SxSettingsView()),
    ),
    GoRoute(
      path: SxRoutes.home,
      builder: (context, state) =>
          const EntitlementGate(child: VoiceLockView()),
    ),
  ],
);
