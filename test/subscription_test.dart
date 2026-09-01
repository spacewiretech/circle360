import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:loc_360/data/cashfree/cashfree_checkout.dart';
import 'package:loc_360/data/cashfree/upi_app_preference.dart';
import 'package:loc_360/data/models/app_user.dart';
import 'package:loc_360/data/models/subscription_offer.dart';
import 'package:loc_360/data/models/upi_app.dart';
import 'package:loc_360/data/providers.dart';
import 'package:loc_360/data/repositories/auth_repository.dart';
import 'package:loc_360/data/repositories/subscription_repository.dart';
import 'package:loc_360/features/splash/splash_viewmodel.dart';
import 'package:loc_360/features/subscription/subscription_viewmodel.dart';

/// Covers the rules that decide whether someone gets into the app, and the purchase flow that
/// changes the answer. These are the paths where a bug either locks out a paying customer or
/// lets a non-paying one in, so they are tested by behaviour rather than by implementation.
void main() {
  const base = AppUser(id: 'u', phone: '9931145610', name: 'Ayush');
  final now = DateTime(2026, 9, 1, 12);

  // The real SDK path, driven through a stubbed method channel. Everything else in this file
  // talks to a fake; this is the only place the actual plugin contract is exercised.
  group('SdkCashfreeCheckout.installedApps', () {
    TestWidgetsFlutterBinding.ensureInitialized();
    const channel = MethodChannel('flutter_cashfree_pg_sdk');

    void stub(Future<Object?>? Function(MethodCall) handler) {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, handler);
      addTearDown(() => TestDefaultBinaryMessengerBinding
          .instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null));
    }

    test('a native side that never answers cannot block the paywall', () async {
      // The paywall holds `loading` until this resolves, so an unanswered channel call would
      // leave the screen on a spinner with no plan row and no button at all — strictly worse
      // than having no app picker.
      stub((_) => Completer<Object?>().future);

      expect(await SdkCashfreeCheckout().installedApps(), isEmpty);
    }, timeout: const Timeout(Duration(seconds: 20)));

    test('a platform exception degrades to the fallback', () async {
      stub((_) async => throw PlatformException(code: 'unavailable'));
      expect(await SdkCashfreeCheckout().installedApps(), isEmpty);
    });

    test('a real response is parsed into apps', () async {
      stub((call) async {
        expect(call.method, 'getupiapps');
        return [
          {'id': 'com.phonepe.app', 'displayName': 'PhonePe', 'base64Icon': ''},
          {'id': 'tez', 'displayName': 'Google Pay'},
        ];
      });

      final apps = await SdkCashfreeCheckout().installedApps();
      expect(apps.map((a) => a.id), ['com.phonepe.app', 'tez']);
      expect(apps.first.displayName, 'PhonePe');
    });
  });

  group('offline entitlement', () {
    test('a trial still running keeps access', () {
      final user = base
          .copyWith(
            paymentType: PaymentType.trial,
            trialEndsAt: now.add(const Duration(hours: 5)),
            entitled: true,
          )
          .recomputeOffline(now);

      expect(user.entitled, isTrue);
    });

    test('a trial that ended overnight loses access once grace runs out', () {
      // The stored flag says true because it was true when it was written. Without the
      // recompute, an offline device would keep opening the app indefinitely.
      final user = base
          .copyWith(
            paymentType: PaymentType.trial,
            trialEndsAt: now.subtract(const Duration(hours: 20)),
            entitled: true,
          )
          .recomputeOffline(now);

      expect(user.entitled, isFalse);
    });

    test('a trial inside the grace window still gets in', () {
      // Money may already have moved; the webhook simply has not landed. Locking out here
      // would be the expensive kind of wrong.
      final user = base
          .copyWith(
            paymentType: PaymentType.trial,
            trialEndsAt: now.subtract(const Duration(hours: 3)),
            entitled: true,
          )
          .recomputeOffline(now);

      expect(user.entitled, isTrue);
    });

    test('a trial that never started is never entitled', () {
      final user = base
          .copyWith(paymentType: PaymentType.trial, entitled: true)
          .recomputeOffline(now);

      expect(user.entitled, isFalse, reason: 'no trial_ends_at means the ₹3 was never paid');
    });

    test('an active plan with no period end yet is entitled', () {
      // The window between authorisation and the first debit.
      final user = base
          .copyWith(paymentType: PaymentType.active, entitled: true)
          .recomputeOffline(now);

      expect(user.entitled, isTrue);
    });

    test('a cancelled plan keeps the month already paid for, with no grace', () {
      final keeping = base
          .copyWith(
            paymentType: PaymentType.cancelled,
            currentPeriodEnd: now.add(const Duration(days: 10)),
            entitled: true,
          )
          .recomputeOffline(now);
      expect(keeping.entitled, isTrue);

      final lapsed = base
          .copyWith(
            paymentType: PaymentType.cancelled,
            currentPeriodEnd: now.subtract(const Duration(hours: 1)),
            entitled: true,
          )
          .recomputeOffline(now);
      expect(lapsed.entitled, isFalse, reason: 'a cancelled mandate has no debit to wait for');
    });

    test('expired is never entitled, whatever the dates say', () {
      final user = base
          .copyWith(
            paymentType: PaymentType.expired,
            currentPeriodEnd: now.add(const Duration(days: 30)),
            entitled: true,
          )
          .recomputeOffline(now);

      expect(user.entitled, isFalse);
    });
  });

  group('trial eligibility', () {
    test('an account that never authorised a mandate is offered the trial', () {
      expect(base.hasEverSubscribed, isFalse);
    });

    test('a lapsed trial is not offered the ₹3 a second time', () {
      final user = base.copyWith(trialEndsAt: now.subtract(const Duration(days: 40)));
      expect(user.hasEverSubscribed, isTrue);
    });
  });

  group('routing', () {
    test('an unentitled signed-in user with a name lands on the paywall', () {
      expect(
        destinationForSession(signedIn: true, hasName: true, entitled: false),
        SplashDestination.subscribe,
      );
    });

    test('the name step still comes before the paywall', () {
      expect(
        destinationForSession(signedIn: true, hasName: false, entitled: false),
        SplashDestination.name,
      );
    });

    test('an entitled user goes straight home', () {
      expect(
        destinationForSession(signedIn: true, hasName: true, entitled: true),
        SplashDestination.home,
      );
    });
  });

  group('UpiApp.fromChannel', () {
    // A 1x1 transparent PNG.
    const png = 'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAAC0lEQVR42mNk'
        'YAAAAAYAAjCB0C8AAAAASUVORK5CYII=';

    test('parses the Android shape, where id is a package name', () {
      final app = UpiApp.fromChannel({
        'id': 'com.google.android.apps.nbu.paisa.user',
        'displayName': 'Google Pay',
        'base64Icon': png,
      });

      expect(app?.id, 'com.google.android.apps.nbu.paisa.user');
      expect(app?.displayName, 'Google Pay');
      expect(app?.icon, isNotNull);
    });

    test('parses the iOS shape, where id is a URL scheme and `icon` is the key', () {
      // The plugin sends both `base64Icon` and `icon` on iOS; either must work, because the
      // two platforms are the same code path on our side.
      final app = UpiApp.fromChannel({
        'id': 'tez',
        'displayName': 'Google Pay',
        'icon': png,
      });

      expect(app?.id, 'tez');
      expect(app?.icon, isNotNull);
    });

    test('an entry with no id is dropped', () {
      // Nothing to hand back to the SDK, so it could only render as a dead row.
      expect(UpiApp.fromChannel({'displayName': 'Mystery'}), isNull);
      expect(UpiApp.fromChannel({'id': '   '}), isNull);
      expect(UpiApp.fromChannel(null), isNull);
      expect(UpiApp.fromChannel('not a map'), isNull);
    });

    test('a blank display name falls back to the id', () {
      expect(UpiApp.fromChannel({'id': 'tez', 'displayName': '  '})?.displayName, 'tez');
      expect(UpiApp.fromChannel({'id': 'tez'})?.displayName, 'tez');
    });

    test('a bad icon costs the logo, not the app', () {
      // Losing an app from the picker because its icon failed to decode would be far worse
      // than showing it with a placeholder.
      for (final bad in ['', '   ', 'not base64 at all!!', 'δεν', 42, null]) {
        final app = UpiApp.fromChannel({'id': 'tez', 'base64Icon': bad});
        expect(app, isNotNull, reason: 'icon input: $bad');
        expect(app?.icon, isNull, reason: 'icon input: $bad');
      }
    });

    test('a data: URI prefix and stray whitespace are tolerated', () {
      expect(UpiApp.fromChannel({'id': 'a', 'base64Icon': 'data:image/png;base64,$png'})?.icon,
          isNotNull);
      expect(UpiApp.fromChannel({'id': 'b', 'base64Icon': '$png\n'})?.icon, isNotNull);
    });

    test('listFrom keeps the good entries and drops the rest', () {
      final apps = UpiApp.listFrom([
        {'id': 'tez', 'displayName': 'Google Pay'},
        {'displayName': 'no id'},
        null,
        {'id': 'paytm', 'displayName': 'Paytm'},
      ]);

      expect(apps.map((a) => a.id), ['tez', 'paytm']);
    });

    test('a non-list response is empty rather than a crash', () {
      expect(UpiApp.listFrom(null), isEmpty);
      expect(UpiApp.listFrom('nope'), isEmpty);
    });
  });

  test('the mandate consent line states the amount and the cadence', () {
    const offer = SubscriptionOffer(trialPrice: '₹3', planPrice: '₹499', trialDays: 2);
    // UPI Autopay requires all three before authorisation.
    expect(offer.consent, contains('₹3'));
    expect(offer.consent, contains('₹499/month'));
    expect(offer.consent, contains('2 days'));
  });

  group('SubscriptionViewModel', () {
    late _FakeSubscriptionRepository repository;
    late _ScriptedCheckout checkout;
    late _MemoryUpiAppPreference preference;
    late ProviderContainer container;

    setUp(() {
      repository = _FakeSubscriptionRepository();
      checkout = _ScriptedCheckout();
      preference = _MemoryUpiAppPreference();
      container = ProviderContainer(overrides: [
        subscriptionRepositoryProvider.overrideWithValue(repository),
        cashfreeCheckoutProvider.overrideWithValue(checkout),
        upiAppPreferenceProvider.overrideWithValue(preference),
        authRepositoryProvider.overrideWithValue(_StubAuth(base)),
        // The real backoff runs for about half a minute; the behaviour under test is how many
        // times it asks and what it concludes, not how long it waits between asks.
        subscriptionPollDelaysProvider.overrideWithValue(const [Duration.zero]),
      ]);
      addTearDown(container.dispose);
    });

    Future<SubscriptionViewModel> ready() async {
      final viewModel = container.read(subscriptionViewModelProvider.notifier);
      // build() kicks off the load; give it a turn to land.
      while (container.read(subscriptionViewModelProvider).loading) {
        await Future<void>.delayed(Duration.zero);
      }
      return viewModel;
    }

    test('a confirmed mandate lets the user through', () async {
      final viewModel = await ready();
      repository.entitledAfterPolls = 1;

      expect(await viewModel.subscribe(), isTrue);
      expect(container.read(subscriptionViewModelProvider).error, isNull);
    });

    group('UPI app selection', () {
      test('the first installed app is preselected on a fresh install', () async {
        await ready();
        expect(container.read(subscriptionViewModelProvider).selectedApp?.id, 'gpay');
      });

      test('the app used last time is preselected', () async {
        preference.saved = 'paytm';
        await ready();
        expect(container.read(subscriptionViewModelProvider).selectedApp?.id, 'paytm');
      });

      test('an app that has since been uninstalled falls back to the first', () async {
        // Otherwise the button would point at an id the SDK can no longer launch — a dead
        // button with nothing on screen to explain it.
        preference.saved = 'phonepe';
        await ready();
        expect(container.read(subscriptionViewModelProvider).selectedApp?.id, 'gpay');
      });

      test('the chosen app is the one handed to the SDK', () async {
        final viewModel = await ready();
        repository.entitledAfterPolls = 1;
        viewModel.selectApp('paytm');

        expect(await viewModel.subscribe(), isTrue);
        expect(checkout.launchedAppId, 'paytm');
        expect(checkout.openCount, 0, reason: 'the Cashfree screen must not appear');
      });

      test('choosing an app remembers it for next time', () async {
        final viewModel = await ready();
        viewModel.selectApp('paytm');
        expect(preference.saved, 'paytm');
      });

      test('an app that is not installed cannot be selected', () async {
        final viewModel = await ready();
        viewModel.selectApp('phonepe');
        expect(container.read(subscriptionViewModelProvider).selectedApp?.id, 'gpay');
      });

      test('with no UPI app installed the Cashfree screen stands in', () async {
        // The element API only does INTENT, so a device with nothing installed can only be
        // served the enter-a-UPI-ID flow through Cashfree's own checkout.
        checkout.apps = const [];
        final viewModel = await ready();
        repository.entitledAfterPolls = 1;

        expect(container.read(subscriptionViewModelProvider).selectedApp, isNull);
        expect(await viewModel.subscribe(), isTrue);
        expect(checkout.openCount, 1);
        expect(checkout.openWithAppCount, 0);
      });
    });

    test('a closed sheet is not treated as payment until the server agrees', () async {
      final viewModel = await ready();
      // The SDK reports success but the server never confirms — exactly what a mandate that
      // failed after the UPI handoff looks like.
      repository.entitledAfterPolls = null;

      expect(await viewModel.subscribe(), isFalse);
      expect(
        container.read(subscriptionViewModelProvider).error,
        contains('could not confirm'),
      );
      expect(repository.pollCount, greaterThan(1), reason: 'it should keep asking');
    });

    test('a cancelled sheet is still polled, in case the mandate went through', () async {
      final viewModel = await ready();
      checkout.result = const CheckoutResult(CheckoutOutcome.failed, 'Cancelled.');
      repository.entitledAfterPolls = 1;

      expect(await viewModel.subscribe(), isTrue,
          reason: 'the UPI app can approve even when the sheet reports failure');
    });

    test('an already-entitled caller is let through without a second charge', () async {
      final viewModel = await ready();
      repository.startResult = const SubscriptionStart.entitled();

      expect(await viewModel.subscribe(), isTrue);
      expect(checkout.opened, isFalse, reason: 'no sheet, so nothing can be charged twice');
    });

    test('a refused start surfaces the reason and charges nothing', () async {
      final viewModel = await ready();
      repository.startError = const SubscriptionException('Payments are unavailable.');

      expect(await viewModel.subscribe(), isFalse);
      expect(
        container.read(subscriptionViewModelProvider).error,
        'Payments are unavailable.',
      );
      expect(checkout.opened, isFalse);
    });

    test('a second tap while busy is ignored', () async {
      final viewModel = await ready();
      repository.entitledAfterPolls = 1;

      final first = viewModel.subscribe();
      final second = await viewModel.subscribe();

      expect(second, isFalse, reason: 'one mandate per tap-through, not one per tap');
      await first;
      // Counted across both routes — which one ran depends on whether a UPI app is installed,
      // and neither may run twice.
      expect(checkout.openCount + checkout.openWithAppCount, 1);
    });
  });
}

class _FakeSubscriptionRepository implements SubscriptionRepository {
  SubscriptionStart startResult = const SubscriptionStart.pending(
    subscriptionId: 'sub_1',
    sessionId: 'sess_1',
    environment: 'sandbox',
  );
  SubscriptionException? startError;

  /// Poll number on which the server starts reporting entitlement. Null means it never does.
  int? entitledAfterPolls;
  int pollCount = 0;

  @override
  Future<SubscriptionOffer> offer() async =>
      const SubscriptionOffer(trialPrice: '₹3', planPrice: '₹499', trialDays: 2);

  @override
  Future<SubscriptionStart> start() async {
    if (startError != null) throw startError!;
    return startResult;
  }

  @override
  Future<AppUser?> refreshStatus() async {
    pollCount++;
    final threshold = entitledAfterPolls;
    return const AppUser(id: 'u', phone: '9931145610').copyWith(
      entitled: threshold != null && pollCount >= threshold,
    );
  }

  @override
  Future<AppUser?> cancel() async => null;
}

class _ScriptedCheckout implements CashfreeCheckout {
  CheckoutResult result = const CheckoutResult(CheckoutOutcome.verified);

  /// What `getUPIApps` reports. Empty models a device with no UPI app installed.
  List<UpiApp> apps = const [
    UpiApp(id: 'gpay', displayName: 'Google Pay'),
    UpiApp(id: 'paytm', displayName: 'Paytm'),
  ];

  int openCount = 0;
  int openWithAppCount = 0;

  /// The app id actually handed to the SDK — the thing that decides which app opens.
  String? launchedAppId;

  bool get opened => openCount + openWithAppCount > 0;

  @override
  Future<List<UpiApp>> installedApps() async => apps;

  @override
  Future<CheckoutResult> openWithApp({
    required String subscriptionId,
    required String sessionId,
    required String environment,
    required String upiAppId,
  }) async {
    openWithAppCount++;
    launchedAppId = upiAppId;
    return result;
  }

  @override
  Future<CheckoutResult> open({
    required String subscriptionId,
    required String sessionId,
    required String environment,
  }) async {
    openCount++;
    return result;
  }
}

/// [UpiAppPreference] talks to SharedPreferences, which has no plugin under `flutter test`.
class _MemoryUpiAppPreference implements UpiAppPreference {
  String? saved;

  @override
  Future<String?> read() async => saved;

  @override
  Future<void> save(String appId) async => saved = appId;
}

class _StubAuth implements AuthRepository {
  _StubAuth(this._user);

  final AppUser _user;

  @override
  Future<AppUser?> currentUser() async => _user;

  @override
  noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
