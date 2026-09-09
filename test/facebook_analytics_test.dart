import 'package:facebook_app_events/facebook_app_events.dart' show channelName;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:loc_360/data/analytics/analytics_events.dart';
import 'package:loc_360/data/analytics/facebook_analytics.dart';
import 'package:loc_360/data/models/app_user.dart';
import 'package:loc_360/data/repositories/app_config_repository.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

/// What crosses to Facebook, and — mostly — what does not.
///
/// The Dart side of the Facebook SDK is a thin wrapper over a method channel, so the channel is
/// recorded rather than mocked away: the interesting behaviour is entirely in which calls this
/// app decides to make, and that is exactly what shows up there.

const _user = AppUser(
  id: 'u1',
  phone: '9931145610',
  name: 'Ayush',
  entitled: true,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late List<MethodCall> calls;

  /// A sink already started with the amounts `app_config` would have supplied.
  Future<FacebookAnalytics> started({
    String appId = '1234567890',
    bool enabled = true,
  }) async {
    final facebook = FacebookAnalytics(preferences: SharedPreferencesAsync());
    await facebook.start(
      appId: appId,
      enabled: enabled,
      trialAmount: 3,
      planAmount: 499,
      currency: 'INR',
    );
    calls.clear();
    return facebook;
  }

  List<MethodCall> callsNamed(String name) =>
      calls.where((call) => call.method == name).toList();

  setUp(() {
    calls = [];
    SharedPreferencesAsyncPlatform.instance = InMemorySharedPreferencesAsync.empty();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel(channelName), (call) async {
      calls.add(call);
      return null;
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel(channelName), null);
  });

  group('the off switch', () {
    test('a blank app id leaves the sink dormant', () async {
      final facebook = await started(appId: '');

      facebook.track(Ev.paymentCompleted, {P.outcome: 'success'});
      facebook.identify(_user);
      facebook.flush();
      await Future<void>.delayed(Duration.zero);

      // The state of any checkout not pointed at a Facebook app, and of every other test in this
      // directory. If it reported anything here, the integration would stop being optional.
      expect(facebook.isActive, isFalse);
      expect(calls, isEmpty);
    });

    test('facebook_events_enabled = false silences a fully configured app', () async {
      final facebook = await started(enabled: false);

      facebook.track(Ev.paymentCompleted, {P.outcome: 'success'});
      await Future<void>.delayed(Duration.zero);

      // The point of the flag: reporting can be stopped from `app_config` without clearing the
      // credentials and without shipping a release.
      expect(calls, isEmpty);
    });

    test('startFacebook reads the keys app_config actually ships with', () async {
      final facebook = FacebookAnalytics(preferences: SharedPreferencesAsync());

      // defaultAppConfig carries a blank facebook_app_id on purpose, so the shipped defaults
      // alone must never bring the sink up — only a served row can.
      await startFacebook(facebook, defaultAppConfig);
      expect(facebook.isActive, isFalse);

      await startFacebook(facebook, {...defaultAppConfig, facebookAppIdKey: '1234567890'});
      expect(facebook.isActive, isTrue);
    });
  });

  group('the allowlist', () {
    test('the ~70 events Facebook has no use for are dropped', () async {
      final facebook = await started();

      facebook.track(Ev.screenViewed, {P.screen: 'Home'});
      facebook.track(Ev.elementTapped, {P.elementId: 'retry_payment'});
      facebook.track(Ev.appLaunched);
      facebook.track(Ev.homeViewed);
      facebook.track(Ev.paywallViewed);
      facebook.track(Ev.inviteSent);
      await Future<void>.delayed(Duration.zero);

      // Forwarding these would dilute the standard events the optimiser trains on, and put a
      // network call behind every tap in the app.
      expect(calls, isEmpty);
    });

    test('the four conversions cross', () async {
      final facebook = await started();

      facebook.track(Ev.signupCompleted, {P.destination: 'subscription'});
      facebook.track(Ev.subscribeTapped, {P.offerType: 'trial'});
      await Future<void>.delayed(Duration.zero);

      expect(callsNamed('logEvent'), hasLength(2));
    });
  });

  group('purchases', () {
    test('a failed payment is not a sale', () async {
      final facebook = await started();

      // `Payment Completed` carries failures and pendings through the same event name, so this
      // guard is the only thing standing between a declined UPI mandate and a reported purchase.
      facebook.track(Ev.paymentCompleted, {P.outcome: 'failed'});
      facebook.track(Ev.paymentCompleted, {P.outcome: 'pending'});
      await Future<void>.delayed(Duration.zero);

      expect(callsNamed('logPurchase'), isEmpty);
    });

    test('a successful payment is reported once, with the trial amount', () async {
      final facebook = await started();

      facebook.track(Ev.paymentCompleted, {P.outcome: 'success', P.offerType: 'trial'});
      await Future<void>.delayed(Duration.zero);

      final purchase = callsNamed('logPurchase').single;
      expect(purchase.arguments['amount'], 3.0);
      expect(purchase.arguments['currency'], 'INR');

      // Both, deliberately: Purchase carries the value Facebook bids against, StartTrial is the
      // subscription signal its own guidance asks for.
      expect(callsNamed('logEvent'), hasLength(1));
    });

    test('a direct plan purchase is reported at the plan amount', () async {
      final facebook = await started();

      facebook.track(Ev.paymentCompleted, {P.outcome: 'success', P.offerType: 'plan'});
      await Future<void>.delayed(Duration.zero);

      expect(callsNamed('logPurchase').single.arguments['amount'], 499.0);
    });

    test('an unknown offer type is priced as the trial rather than the plan', () async {
      final facebook = await started();

      facebook.track(Ev.paymentCompleted, {P.outcome: 'success'});
      await Future<void>.delayed(Duration.zero);

      // Under-reporting costs a few rupees of attributed revenue. Over-reporting teaches the
      // optimiser to buy the wrong people, which is far more expensive to undo.
      expect(callsNamed('logPurchase').single.arguments['amount'], 3.0);
    });

    test('a second success on the same device does not double-count', () async {
      final facebook = await started();

      // The real sequence this guards: a payment the paywall never detected, then a retry the
      // server answers with `alreadyEntitled` — a success that charged nothing.
      facebook.track(Ev.paymentCompleted, {P.outcome: 'success', P.offerType: 'trial'});
      await Future<void>.delayed(Duration.zero);
      facebook.track(Ev.paymentCompleted, {P.outcome: 'success', P.offerType: 'trial'});
      await Future<void>.delayed(Duration.zero);

      expect(callsNamed('logPurchase'), hasLength(1));
    });

    test('the late confirmation reports the purchase the paywall gave up on', () async {
      final facebook = await started();

      // The only success path that never passes through `Payment Completed`. Without it these
      // conversions are lost silently — the money arrives, Facebook never hears about it.
      facebook.track(Ev.paymentConfirmedLate, {P.offerType: 'trial'});
      await Future<void>.delayed(Duration.zero);

      expect(callsNamed('logPurchase'), hasLength(1));
    });

    test('the guard survives a restart, because the flag is on disk', () async {
      final first = await started();
      first.track(Ev.paymentCompleted, {P.outcome: 'success', P.offerType: 'trial'});
      await Future<void>.delayed(Duration.zero);
      expect(callsNamed('logPurchase'), hasLength(1));

      // A fresh instance is what a relaunch looks like, and the app is routinely killed during
      // the UPI hand-off — so an in-memory guard would miss exactly the case it exists for.
      calls.clear();
      final second = await started();
      second.track(Ev.paymentCompleted, {P.outcome: 'success', P.offerType: 'trial'});
      await Future<void>.delayed(Duration.zero);

      expect(callsNamed('logPurchase'), isEmpty);
    });
  });

  group('identity', () {
    test('the phone number goes out with its country code', () async {
      final facebook = await started();

      facebook.identify(_user);
      await Future<void>.delayed(Duration.zero);

      // AppUser.phone is the bare ten digits. Facebook hashes what it is given and matches it
      // against profiles that carry a country code, so a bare '99…' matches nobody at all.
      expect(callsNamed('setUserData').single.arguments['phone'], '+919931145610');
    });

    test('sign-out clears the identity but not the purchase guard', () async {
      final facebook = await started();
      facebook.track(Ev.paymentCompleted, {P.outcome: 'success', P.offerType: 'trial'});
      await Future<void>.delayed(Duration.zero);

      facebook.reset();
      await Future<void>.delayed(Duration.zero);
      expect(callsNamed('clearUserData'), hasLength(1));

      calls.clear();
      facebook.track(Ev.paymentCompleted, {P.outcome: 'success', P.offerType: 'trial'});
      await Future<void>.delayed(Duration.zero);

      // Signing out is not a reason to be allowed to report a second purchase.
      expect(callsNamed('logPurchase'), isEmpty);
    });

    test('trackCharge is not a second route to a purchase', () async {
      final facebook = await started();

      facebook.trackCharge(499);
      await Future<void>.delayed(Duration.zero);

      // Revenue reaches Facebook through the de-duplicated path only. An unguarded second route
      // to logPurchase is how a conversion gets counted twice.
      expect(calls, isEmpty);
    });
  });
}
