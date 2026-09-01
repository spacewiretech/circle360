import 'package:go_router/go_router.dart';

import '../features/diagnostics/tracking_diagnostics_screen.dart';
import '../features/emergency/emergency_view.dart';
import '../features/home/home_view.dart';
import '../features/invite/invite_view.dart';
import '../features/location/location_permission_view.dart';
import '../features/onboarding/name_view.dart';
import '../features/onboarding/otp_view.dart';
import '../features/onboarding/phone_view.dart';
import '../features/profile/profile_view.dart';
import '../features/settings/settings_view.dart';
import '../features/splash/splash_view.dart';
import '../features/splash/splash_viewmodel.dart';
import '../features/subscription/subscription_view.dart';
import 'entitlement_gate.dart';

abstract final class Routes {
  static const splash = '/';
  static const invite = '/invite';
  static const phone = '/phone';
  static const otp = '/otp';
  static const name = '/name';
  static const subscribe = '/subscribe';
  static const location = '/location';
  static const home = '/home';
  static const emergency = '/emergency';
  static const profile = '/profile';
  static const settings = '/settings';
  static const diagnostics = '/settings/diagnostics';
}

/// The route each resolved destination maps to. Lives here so both the splash and the invite
/// screen — which resumes the flow after the invite is sent — route identically.
extension SplashDestinationRoute on SplashDestination {
  String get route => switch (this) {
        SplashDestination.invite => Routes.invite,
        SplashDestination.onboarding => Routes.phone,
        SplashDestination.name => Routes.name,
        SplashDestination.subscribe => Routes.subscribe,
        SplashDestination.location => Routes.location,
        SplashDestination.home => Routes.home,
      };
}

/// Flat routes: the splash resolves the session and redirects, and each onboarding step
/// decides where it goes next, so there is no global redirect to keep in sync.
final appRouter = GoRouter(
  initialLocation: Routes.splash,
  routes: [
    GoRoute(path: Routes.splash, builder: (context, state) => const SplashView()),
    GoRoute(path: Routes.invite, builder: (context, state) => const InviteView()),
    GoRoute(path: Routes.phone, builder: (context, state) => const PhoneView()),
    GoRoute(path: Routes.otp, builder: (context, state) => const OtpView()),
    GoRoute(path: Routes.name, builder: (context, state) => const NameView()),
    GoRoute(path: Routes.subscribe, builder: (context, state) => const SubscriptionView()),

    // Gated like the rest of the paid app, but not itself a gate: it always offers a way
    // through to Home, whatever the user answers.
    GoRoute(
      path: Routes.location,
      builder: (context, state) => const EntitlementGate(child: LocationPermissionView()),
    ),

    // Everything past the paywall is wrapped, so a trial that runs out mid-session bounces the
    // user back to /subscribe instead of being noticed only at the next cold start.
    GoRoute(
      path: Routes.home,
      builder: (context, state) => const EntitlementGate(child: HomeView()),
    ),
    GoRoute(
      path: Routes.emergency,
      builder: (context, state) => const EntitlementGate(child: EmergencyView()),
    ),
    GoRoute(
      path: Routes.profile,
      builder: (context, state) => const EntitlementGate(child: ProfileView()),
    ),
    GoRoute(
      path: Routes.settings,
      builder: (context, state) => const EntitlementGate(child: SettingsView()),
      routes: [
        GoRoute(
          path: 'diagnostics',
          builder: (context, state) =>
              const EntitlementGate(child: TrackingDiagnosticsScreen()),
        ),
      ],
    ),
  ],
);
