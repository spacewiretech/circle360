import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:loc_360/app/analytics_observer.dart';
import 'package:loc_360/app/router.dart';
import 'package:loc_360/data/analytics/analytics.dart';
import 'package:loc_360/data/analytics/analytics_events.dart';
import 'package:loc_360/data/analytics/mixpanel_analytics.dart';
import 'package:loc_360/data/models/app_user.dart';

/// Records what it was asked to send, so the parts of the analytics layer that are pure Dart can
/// be asserted without a platform channel.
class RecordingAnalytics implements Analytics {
  final events = <({String name, Map<String, Object?> properties})>[];
  final supers = <String, Object?>{};
  final identified = <String>[];
  final charges = <double>[];
  int resets = 0;
  int flushes = 0;

  @override
  void track(String event, [Map<String, Object?> properties = const {}]) =>
      events.add((name: event, properties: properties));

  @override
  void timeEvent(String event) {}

  @override
  void identify(AppUser user) => identified.add(user.id);

  @override
  void reset() => resets++;

  @override
  void registerSuper(Map<String, Object?> properties) => supers.addAll(properties);

  @override
  void trackCharge(double amount, [Map<String, Object?> properties = const {}]) =>
      charges.add(amount);

  @override
  void flush() => flushes++;

  List<String> get names => [for (final e in events) e.name];
}

void main() {
  group('MixpanelAnalytics buffering', () {
    test('a blank or missing token leaves it unstarted and throws nothing', () async {
      final analytics = MixpanelAnalytics(verbose: false);

      await analytics.start(null);
      await analytics.start('');
      await analytics.start('   ');

      expect(analytics.isStarted, isFalse);
      // The whole point: with no `mixpanel_token` row the app must behave exactly as it did
      // before analytics existed, rather than crash on the first event.
      expect(() => analytics.track(Ev.appLaunched), returnsNormally);
      expect(() => analytics.flush(), returnsNormally);
      expect(() => analytics.reset(), returnsNormally);
    });

    test('events recorded before the token arrives are queued, not dropped', () {
      final analytics = MixpanelAnalytics(verbose: false);

      for (var i = 0; i < 5; i++) {
        analytics.track('Event $i');
      }

      expect(analytics.debugQueueLength, 5);
    });

    test('the queue stops growing rather than eating memory offline', () {
      final analytics = MixpanelAnalytics(verbose: false);

      for (var i = 0; i < 1000; i++) {
        analytics.track('Event $i');
      }

      expect(analytics.debugQueueLength, MixpanelAnalytics.debugMaxQueued);
    });

    test('ambient context is snapshotted when the event happens, not when it is sent', () {
      final analytics = MixpanelAnalytics(verbose: false);
      var screen = 'Splash';
      analytics.context = () => {P.screen: screen};

      analytics.track(Ev.appLaunched);
      // The user has moved on by the time the token lands. The queued event must still say
      // Splash, or every buffered event would be attributed to whichever screen happened to be
      // showing when Mixpanel finally started.
      screen = 'Home';
      analytics.track(Ev.homeViewed);

      expect(analytics.debugQueuedProperties.first[P.screen], 'Splash');
      expect(analytics.debugQueuedProperties.last[P.screen], 'Home');
    });

    test('null properties are dropped rather than sent as nulls', () {
      final analytics = MixpanelAnalytics(verbose: false);

      analytics.track(Ev.paymentCompleted, {
        P.outcome: 'success',
        P.appId: null,
        P.reason: null,
      });

      final properties = analytics.debugQueuedProperties.single;
      expect(properties, contains(P.outcome));
      expect(properties, isNot(contains(P.appId)));
      expect(properties, isNot(contains(P.reason)));
    });
  });

  group('people properties', () {
    final user = AppUser(
      id: 'user-1',
      phone: '9931145610',
      name: 'Asha',
      paymentType: PaymentType.active,
      entitled: true,
      trialEndsAt: DateTime.utc(2026, 1, 2),
      currentPeriodEnd: DateTime.utc(2026, 2, 1),
      billingState: BillingState.dunning,
    );

    test('maps an AppUser onto the Mixpanel reserved and custom fields', () {
      final properties = MixpanelAnalytics.peoplePropertiesFor(user);

      expect(properties[r'$name'], 'Asha');
      // Country code included: the app stores the number without one, and a bare ten digits is
      // not a number anyone can dial from a support desk.
      expect(properties[r'$phone'], '+919931145610');
      expect(properties[P.paymentType], 'active');
      expect(properties[P.entitled], isTrue);
      expect(properties[P.inTrial], isFalse);
      expect(properties[P.hasEverSubscribed], isTrue);
      expect(properties[P.billingState], 'dunning');
      expect(properties['current_period_end'], '2026-02-01T00:00:00.000Z');
    });

    test('a trial converting to paid changes the profile even though the id has not', () {
      // The dedupe in `identify` must not key on the user id. It is exactly the conversion —
      // same account, different payment_type — that has to reach the profile, and keying on the
      // id would pin every user to whatever they looked like when they first signed in.
      final trialling = MixpanelAnalytics.peoplePropertiesFor(
        AppUser(
          id: 'user-1',
          phone: '9931145610',
          name: 'Asha',
          entitled: true,
          trialEndsAt: DateTime.utc(2026, 1, 2),
        ),
      );

      expect(trialling[P.paymentType], 'trial');
      expect(trialling[P.inTrial], isTrue);
      expect(trialling[P.paymentType], isNot(user.paymentType.name));
      expect(
        MixpanelAnalytics.peoplePropertiesFor(user)[P.inTrial],
        isNot(trialling[P.inTrial]),
      );
    });

    test('omits the dates and billing state a fresh account does not have', () {
      final properties = MixpanelAnalytics.peoplePropertiesFor(
        const AppUser(id: 'user-2', phone: '9000000000'),
      );

      expect(properties, isNot(contains('trial_ends_at')));
      expect(properties, isNot(contains('current_period_end')));
      expect(properties, isNot(contains(P.billingState)));
      expect(properties[P.hasEverSubscribed], isFalse);
    });
  });

  group('screen names', () {
    test('every route in the table has a human name', () {
      // Guards the mapping against a route being added without one, which would otherwise show
      // up in Mixpanel as a raw path — or, for a nested route, as a bare relative segment.
      const routes = [
        Routes.splash,
        Routes.invite,
        Routes.phone,
        Routes.otp,
        Routes.name,
        Routes.subscribe,
        Routes.paymentStatus,
        Routes.location,
        Routes.home,
        Routes.emergency,
        Routes.profile,
        Routes.settings,
        'diagnostics',
      ];

      for (final route in routes) {
        expect(screenNameFor(route), isNotNull, reason: '$route has no screen name');
      }
    });

    test('the modal surfaces are named too', () {
      expect(screenNameFor('upi-picker'), 'UPI App Picker');
      expect(screenNameFor('add-person'), 'Add Person Sheet');
      expect(screenNameFor('invite-confirm'), 'Invite Confirm Dialog');
      expect(screenNameFor('remove-person'), 'Remove Person Dialog');
    });

    test('an unknown route is reported as unknown rather than guessed at', () {
      expect(screenNameFor(null), isNull);
      expect(screenNameFor('/not-a-route'), isNull);
    });
  });

  group('navigator observer', () {
    late AnalyticsNavigatorObserver observer;
    late RecordingAnalytics recorder;

    Route<void> routeNamed(String? name) => MaterialPageRoute<void>(
          settings: RouteSettings(name: name),
          builder: (_) => const SizedBox.shrink(),
        );

    setUp(() {
      recorder = RecordingAnalytics();
      installAnalytics(recorder);
      observer = AnalyticsNavigatorObserver();
    });

    tearDown(() => installAnalytics(const NoopAnalytics()));

    test('a push reports the screen and the one it came from', () {
      observer.didPush(routeNamed(Routes.phone), null);
      observer.didPush(routeNamed(Routes.otp), routeNamed(Routes.phone));

      expect(recorder.names, [Ev.screenViewed, Ev.screenViewed]);
      expect(recorder.events.last.properties[P.screen], 'OTP');
      expect(recorder.events.last.properties[P.previousScreen], 'Phone');
      expect(recorder.events.last.properties[P.navType], NavType.push);
      expect(observer.currentScreen, 'OTP');
    });

    test('a pop reports a back press, an exit, and a view of what is underneath', () {
      observer.didPush(routeNamed(Routes.phone), null);
      observer.didPush(routeNamed(Routes.otp), routeNamed(Routes.phone));
      recorder.events.clear();

      observer.didPop(routeNamed(Routes.otp), routeNamed(Routes.phone));

      expect(recorder.names, [Ev.backPressed, Ev.screenExited, Ev.screenViewed]);
      expect(recorder.events[0].properties[P.blocked], isFalse);
      expect(recorder.events[1].properties[P.screen], 'OTP');
      expect(recorder.events[1].properties[P.exitType], ExitType.pop);
      // Returning to Phone is a view of Phone. It must not push a second Phone entry.
      expect(recorder.events[2].properties[P.screen], 'Phone');
      expect(recorder.events[2].properties[P.navType], NavType.pop);
      expect(observer.currentScreen, 'Phone');

      observer.didPop(routeNamed(Routes.phone), null);
      expect(observer.currentScreen, isNull);
    });

    test('a modal becomes the ambient screen and hands it back when dismissed', () {
      observer.didPush(routeNamed(Routes.subscribe), null);
      observer.didPush(routeNamed('upi-picker'), routeNamed(Routes.subscribe));

      expect(observer.currentScreen, 'UPI App Picker');
      expect(observer.contextProperties()[P.isModal], isTrue);

      observer.didPop(routeNamed('upi-picker'), routeNamed(Routes.subscribe));

      // The paywall was never left, so events after the sheet closes are attributed to it again.
      expect(observer.currentScreen, 'Paywall');
      expect(observer.contextProperties()[P.screen], 'Paywall');
      expect(observer.contextProperties(), isNot(contains(P.isModal)));
    });

    test('go_router replacing a screen out of stack order still leaves it exactly once', () {
      // go_router rebuilds its page list declaratively, so the push of the new screen can arrive
      // before the removal of the old one. Popping blindly would drop the wrong entry.
      observer.didPush(routeNamed(Routes.subscribe), null);
      observer.didPush(routeNamed(Routes.paymentStatus), routeNamed(Routes.subscribe));
      observer.didRemove(routeNamed(Routes.subscribe), null);

      expect(observer.currentScreen, 'Payment Status');
      expect(
        recorder.events.where((e) => e.name == Ev.screenExited).single
            .properties[P.screen],
        'Paywall',
      );
    });

    test('the resolved path parameter rides along with the payment status view', () {
      observer.didPush(
        MaterialPageRoute<void>(
          settings: const RouteSettings(
            name: Routes.paymentStatus,
            arguments: {'outcome': 'pending'},
          ),
          builder: (_) => const SizedBox.shrink(),
        ),
        null,
      );

      // `/payment-status/:outcome` arrives with the colon intact, so without this the three
      // result screens would be indistinguishable.
      expect(recorder.events.single.properties['route_outcome'], 'pending');
    });
  });

  group('tap tracking', () {
    setUp(() => installAnalytics(const NoopAnalytics()));
    tearDown(() => installAnalytics(const NoopAnalytics()));

    test('a disabled control produces no handler and therefore no event', () {
      final recorder = RecordingAnalytics();
      installAnalytics(recorder);

      expect(trackedTap(null, id: 'subscribe'), isNull);
      expect(recorder.events, isEmpty);
    });

    test('a tap reports itself and then runs the original handler', () {
      final recorder = RecordingAnalytics();
      installAnalytics(recorder);

      var ran = false;
      trackedTap(() => ran = true, id: 'subscribe', label: 'Subscribe · ₹499/month')!();

      expect(ran, isTrue);
      expect(recorder.names, [Ev.elementTapped]);
      expect(recorder.events.single.properties[P.elementId], 'subscribe');
      expect(recorder.events.single.properties[P.label], 'Subscribe · ₹499/month');
    });

    test('an id is derived from the label when none is given', () {
      expect(slugify('Retry Payment'), 'retry_payment');
      expect(slugify('Check Payment Status'), 'check_payment_status');
      // Digits and symbols are stripped so a price change does not mint a new id for the same
      // button; the raw label still rides along as a property.
      expect(slugify('Start 2-day trial · ₹3'), 'start_day_trial');
      expect(slugify('Subscribe · ₹499/month'), 'subscribe_month');
      expect(slugify(null), isNull);
      expect(slugify('₹499'), isNull);
    });
  });
}
