import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../app/env.dart';
import '../location_service.dart';
import '../suniomax/data/app_variant.dart';
import 'analytics/analytics.dart';
import 'analytics/analytics_events.dart';
import 'analytics/facebook_analytics.dart';
import 'analytics/mixpanel_analytics.dart';
import 'cashfree/cashfree_checkout.dart';
import 'cashfree/upi_app_preference.dart';
import 'deeplink_service.dart';
import 'supabase/edge_functions.dart';
import 'supabase/session_store.dart';
import 'supabase/supabase_app_config_repository.dart';
import 'supabase/supabase_auth_repository.dart';
import 'supabase/supabase_family_repository.dart';
import 'supabase/supabase_subscription_repository.dart';
import 'repositories/app_config_repository.dart';
import 'fast2sms/fast2sms_auth_repository.dart';
import 'fast2sms/fast2sms_client.dart';
import 'fake/fake_auth_repository.dart';
import 'fake/fake_emergency_repository.dart';
import 'fake/fake_family_repository.dart';
import 'fake/fake_invite_repository.dart';
import 'fake/fake_profile_repository.dart';
import 'fake/fake_session.dart';
import 'fake/fake_subscription_repository.dart';
import 'repositories/auth_repository.dart';
import 'repositories/emergency_repository.dart';
import 'repositories/family_repository.dart';
import 'repositories/invite_repository.dart';
import 'repositories/profile_repository.dart';
import 'repositories/subscription_repository.dart';

/// The whole data layer is bound here. Moving to Supabase means changing the right-hand side
/// of these five providers and nothing else — no ViewModel or view imports a concrete class.
///
/// e.g. `authRepositoryProvider` becomes
/// `Provider<AuthRepository>((ref) => SupabaseAuthRepository(Supabase.instance.client))`.

/// Which of the two apps in this build this install runs.
///
/// Overridden at boot with the value `AppVariant.resolve()` worked out. The default is here so
/// that a widget test, or anything that never ran `bootMobileApp`, behaves exactly like an
/// ordinary Circle360 install.
///
/// Bound in this file rather than in `lib/suniomax/data/providers.dart` because
/// [authRepositoryProvider] below depends on it: a new account is stamped with the app it was
/// created in, and that has to be injected rather than reached for.
final appVariantProvider = Provider<AppVariant>((ref) => AppVariant.circle360);

final fakeSessionProvider = Provider<FakeSession>((ref) => FakeSession.instance);

final sessionStoreProvider = Provider<SessionStore>((ref) => SessionStore());

/// Runtime config, served from `app_config` and cached on disk.
final appConfigRepositoryProvider = Provider<AppConfigRepository>((ref) {
  if (!Env.hasSupabase) return const FakeAppConfigRepository();
  return SupabaseAppConfigRepository(Supabase.instance.client);
});

/// Resolved once and read wherever a limit or URL is needed.
final appConfigProvider = FutureProvider<Map<String, String>>(
  (ref) => ref.watch(appConfigRepositoryProvider).load(),
);

/// Where events go.
///
/// Defaults to the no-op so tests and any build that never ran `bootMobileApp` behave exactly as
/// they did before analytics existed. Boot overrides it with the same instance installed in the
/// global holder, so the two can never disagree about which sink is live.
final analyticsProvider = Provider<Analytics>((ref) => const NoopAnalytics());

/// Starts the analytics sinks once the fetched config arrives, and stamps the environment onto
/// every event.
///
/// Watched by [Loc360App] so it runs for the life of the app. It is a no-op whenever boot already
/// started them from the cached config — which is every launch after the first — but it is what
/// covers the first launch on a device, and it is also [appConfigProvider]'s first real
/// consumer: nothing read that provider before this.
final analyticsBootstrapProvider = FutureProvider<void>((ref) async {
  final config = await ref.watch(appConfigProvider.future);

  final analytics = ref.read(analyticsProvider);
  analytics.registerSuper({
    P.env: config.configString('env'),
    P.backendMode: backendMode,
  });

  // Resolved through [analyticsSink] rather than a direct `is` test, because the installed sink
  // is a [MultiAnalytics] fan-out and a plain `analytics is MixpanelAnalytics` would now be false
  // — silently leaving Mixpanel unstarted on exactly the first launch this provider exists to
  // cover. The helper looks inside the fan-out, and still copes with a bare sink in tests.
  final mixpanel = analyticsSink<MixpanelAnalytics>(analytics);
  if (mixpanel != null) await mixpanel.start(config[mixpanelTokenKey]);

  // Note the propagation delay the day `facebook_app_id` first appears in `app_config`: an
  // install whose six-hour cache predates the row is served that cache without a fetch, so it
  // reports nothing until the cache ages out. One-time, and only on already-installed devices —
  // a fresh install fetches and starts reporting immediately.
  final facebook = analyticsSink<FacebookAnalytics>(analytics);
  if (facebook != null) await startFacebook(facebook, config);
});

/// Which rung of the repository ladder below is live.
///
/// Sent with every event because without it a developer running on the fakes and a real user in
/// production are indistinguishable in Mixpanel, and a handful of QA runs is enough to visibly
/// move a conversion rate on a young project.
String get backendMode {
  if (Env.hasSupabase) return BackendMode.supabase;
  if (Env.isConfigured) return BackendMode.fast2sms;
  return BackendMode.fake;
}

/// Three rungs, best first, so the app is walkable at every level of configuration:
///
/// 1. Supabase — OTP proxied through Edge Functions, users persisted, Fast2SMS key off-device.
/// 2. Fast2SMS direct — real SMS, but nothing is stored and the key ships in the app.
/// 3. Fake — in-memory, any 6-digit code.
final authRepositoryProvider = Provider<AuthRepository>((ref) {
  final session = ref.watch(fakeSessionProvider);

  if (Env.hasSupabase) {
    return SupabaseAuthRepository(
      SupabaseEdgeFunctions(Supabase.instance.client),
      ref.watch(sessionStoreProvider),
      // Stamped onto a brand new account so the two products' funnels are separable in SQL, the
      // way `app` already separates them in Mixpanel. Attribution only — it decides nothing
      // about entitlement or pricing.
      appId: ref.watch(appVariantProvider).id,
    );
  }

  if (!Env.isConfigured) {
    debugPrint(
      '[auth] Using FakeAuthRepository — ${Env.configurationSummary} '
      'Any ${Fast2SmsClient.otpLength}-digit code will be accepted.',
    );
    return FakeAuthRepository(session);
  }

  debugPrint(
    '[auth] Supabase is not configured; calling Fast2SMS directly. '
    'The API key is shipping inside the app on this path.',
  );
  final client = Fast2SmsClient(
    apiKey: Env.fast2smsApiKey,
    otpId: Env.fast2smsOtpId,
  );
  ref.onDispose(client.dispose);
  return Fast2SmsAuthRepository(client, session);
});

/// The real people-and-positions path whenever Supabase is configured, mirroring
/// [authRepositoryProvider].
final familyRepositoryProvider = Provider<FamilyRepository>((ref) {
  if (Env.hasSupabase) {
    final repository = SupabaseFamilyRepository(
      SupabaseEdgeFunctions(Supabase.instance.client),
      ref.watch(sessionStoreProvider),
    );
    ref.onDispose(repository.dispose);
    return repository;
  }

  debugPrint('[family] Supabase is not configured; showing in-memory people.');
  final repository = FakeFamilyRepository(ref.watch(fakeSessionProvider));
  ref.onDispose(repository.dispose);
  return repository;
});

/// The platform channel to the native tracker.
///
/// Bound here rather than constructed at each call site so tests can override the whole
/// location layer in one place.
final locationServiceProvider = Provider<LocationService>((ref) => LocationService());

final emergencyRepositoryProvider = Provider<EmergencyRepository>(
  (ref) => FakeEmergencyRepository(ref.watch(fakeSessionProvider)),
);

/// The real payment path whenever Supabase is configured — mirroring [authRepositoryProvider].
///
/// This binding is the whole difference between a paywall that charges and one that only looks
/// like it does, so it deliberately follows the same `Env.hasSupabase` rule as auth rather than
/// having a flag of its own that could be left pointing at the fake.
final subscriptionRepositoryProvider = Provider<SubscriptionRepository>((ref) {
  if (Env.hasSupabase) {
    return SupabaseSubscriptionRepository(
      SupabaseEdgeFunctions(Supabase.instance.client),
      ref.watch(sessionStoreProvider),
      ref.watch(appConfigRepositoryProvider),
    );
  }

  debugPrint('[subscription] Supabase is not configured; the paywall will not charge anything.');
  return FakeSubscriptionRepository(ref.watch(fakeSessionProvider));
});

/// The Cashfree SDK, or a stand-in that reports success without opening a UPI app.
final cashfreeCheckoutProvider = Provider<CashfreeCheckout>((ref) {
  if (Env.hasSupabase) return SdkCashfreeCheckout();
  return const FakeCashfreeCheckout();
});

/// Which UPI app the paywall opens on. Cosmetic, so it is not in the secure store.
final upiAppPreferenceProvider = Provider<UpiAppPreference>(
  (ref) => const UpiAppPreference(),
);

final profileRepositoryProvider = Provider<ProfileRepository>(
  (ref) => FakeProfileRepository(ref.watch(fakeSessionProvider)),
);

final inviteRepositoryProvider = Provider<InviteRepository>(
  (ref) => FakeInviteRepository(),
);

/// Not a repository — it reads the OS, not a backend — but it belongs with the rest of the
/// wiring so tests can override it in one place.
final deeplinkServiceProvider = Provider<DeeplinkService>((ref) => DeeplinkService());
