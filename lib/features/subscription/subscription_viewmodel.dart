import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/analytics/analytics.dart';
import '../../data/analytics/analytics_events.dart';
import '../../data/models/app_user.dart';
import '../../data/models/subscription_offer.dart';
import '../../data/models/upi_app.dart';
import '../../data/providers.dart';
import '../../data/repositories/subscription_repository.dart';
import '../payment_status/payment_outcome.dart';

/// What the paywall is currently doing. Only [idle] accepts another tap.
enum SubscriptionPhase {
  idle,

  /// Asking the server for a mandate, then waiting on the UPI app.
  opening,

  /// Control is back and we are asking the server whether the money actually moved.
  confirming,
}

@immutable
class SubscriptionState {
  const SubscriptionState({
    this.offer,
    this.user,
    this.upiApps = const [],
    this.selectedAppId,
    this.loading = true,
    this.phase = SubscriptionPhase.idle,
    this.error,
  });

  final SubscriptionOffer? offer;

  /// Decides which offer to show: the ₹3 trial, or the plain monthly price for someone whose
  /// trial has already been used.
  final AppUser? user;

  /// UPI apps installed on this device. Empty is normal — an iPhone with none, or a discovery
  /// call that failed — and means the paywall falls back to Cashfree's own checkout screen.
  final List<UpiApp> upiApps;

  final String? selectedAppId;

  final bool loading;
  final SubscriptionPhase phase;
  final String? error;

  bool get busy => phase != SubscriptionPhase.idle;
  bool get canSubscribe => !loading && offer != null && !busy;

  /// The app the button will launch, or null when there is nothing to launch and the Cashfree
  /// checkout screen has to stand in.
  UpiApp? get selectedApp {
    for (final app in upiApps) {
      if (app.id == selectedAppId) return app;
    }
    return null;
  }

  /// A returning subscriber — lapsed, cancelled, or a trial already spent — is not offered the
  /// ₹3 again. Only an account that has never authorised a mandate sees the trial price.
  ///
  /// The server's answer wins. This used to be derived here and only here, and it was never sent
  /// anywhere: `subscription-start` built a ₹3 mandate for everybody, so a returning user read
  /// "Subscribe · ₹499/month" on this screen and was then shown ₹3 in their UPI app. Both sides
  /// now apply the same rule, and this is the one that reaches the mandate.
  ///
  /// The date-derived fallback stays for a user restored from a cache written before the field
  /// existed, and for the first frame after a cold start with no network.
  bool get trialAvailable =>
      user?.trialAvailable ?? !(user?.hasEverSubscribed ?? false);

  SubscriptionState copyWith({
    SubscriptionOffer? offer,
    AppUser? user,
    List<UpiApp>? upiApps,
    String? selectedAppId,
    bool? loading,
    SubscriptionPhase? phase,
    String? error,
    bool clearError = false,
  }) {
    return SubscriptionState(
      offer: offer ?? this.offer,
      user: user ?? this.user,
      upiApps: upiApps ?? this.upiApps,
      selectedAppId: selectedAppId ?? this.selectedAppId,
      loading: loading ?? this.loading,
      phase: phase ?? this.phase,
      error: clearError ? null : (error ?? this.error),
    );
  }
}

/// Backoff for the post-checkout poll: quick at first, because most mandates confirm within a
/// couple of seconds, then spaced out to about half a minute in total.
///
/// A provider so tests can collapse it — otherwise every test of the confirm path would have to
/// sit through the real half minute.
final subscriptionPollDelaysProvider = Provider<List<Duration>>((ref) => const [
      Duration(seconds: 1),
      Duration(seconds: 2),
      Duration(seconds: 3),
      Duration(seconds: 4),
      Duration(seconds: 5),
      Duration(seconds: 5),
      Duration(seconds: 5),
      Duration(seconds: 5),
    ]);

class SubscriptionViewModel extends Notifier<SubscriptionState> {
  Analytics get _analytics => ref.read(analyticsProvider);

  /// Ties every event of one purchase together — the tap, the mandate, the hand-off to the UPI
  /// app, the poll, and the outcome screen that may not resolve for another minute.
  ///
  /// Survives navigation to `/payment-status` because this notifier is deliberately not
  /// `autoDispose`, which is also why the result screen can still read [SubscriptionState.error].
  /// Without it, a late confirmation on the status screen could not be joined back to the attempt
  /// that produced it, and every funnel would break at exactly the step worth measuring.
  String? _attemptId;
  DateTime? _attemptStartedAt;
  int _attempts = 0;

  @override
  SubscriptionState build() {
    _load();
    return const SubscriptionState();
  }

  /// The id of the purchase currently in flight, for the screens downstream of this one.
  String? get attemptId => _attemptId;

  Future<void> _load() async {
    final started = DateTime.now();
    try {
      final repository = ref.read(subscriptionRepositoryProvider);
      // Fetched together: the offer decides the price on screen, the user decides whether the
      // trial is still on the table, and the app list decides which UPI app the button opens.
      final results = await Future.wait<Object?>([
        repository.offer(),
        ref.read(authRepositoryProvider).currentUser(),
        ref.read(cashfreeCheckoutProvider).installedApps(),
        ref.read(upiAppPreferenceProvider).read(),
      ]);

      final apps = results[2] as List<UpiApp>;
      final remembered = results[3] as String?;
      final offer = results[0] as SubscriptionOffer;
      final user = results[1] as AppUser?;
      final selected = _resolveSelection(apps, remembered);

      state = state.copyWith(
        offer: offer,
        user: user,
        upiApps: apps,
        selectedAppId: selected,
        loading: false,
      );

      _analytics.track(Ev.paywallOfferLoaded, {
        P.trialPrice: offer.trialPrice,
        P.planPrice: offer.planPrice,
        P.trialDays: offer.trialDays,
        P.trialAvailable: state.trialAvailable,
        P.upiAppCount: apps.length,
        P.ms: DateTime.now().difference(started).inMilliseconds,
      });

      // Which app the button is pointing at before the user has touched anything, and why.
      // `remembered` converting better than `first` is the entire argument for keeping the
      // preference, and this is the only place that comparison can be made.
      _analytics.track(Ev.upiAppPreselected, {
        P.appId: selected,
        P.source: switch (selected) {
          null => 'none',
          final id when id == remembered => 'remembered',
          _ => 'first',
        },
      });
      if (selected != null) {
        _analytics.registerSuper({P.preferredUpiApp: selected});
      }
    } catch (error) {
      debugPrint('[subscription] could not load the offer: $error');
      state = state.copyWith(
        loading: false,
        error: 'Could not load the plan. Please check your connection and try again.',
      );
      // A paywall that never renders a price is a silent, total conversion failure — it looks
      // like nobody wanted to subscribe rather than like nobody was asked.
      _analytics.track(Ev.paywallOfferLoadFailed, {
        P.error: error.toString(),
        P.ms: DateTime.now().difference(started).inMilliseconds,
      });
    }
  }

  /// The remembered app, but only while it is still installed.
  ///
  /// Without the containment check, uninstalling the app you last paid with would leave the
  /// button pointing at an id the SDK can no longer launch — a dead button with no explanation.
  static String? _resolveSelection(List<UpiApp> apps, String? remembered) {
    if (apps.isEmpty) return null;
    if (remembered != null && apps.any((app) => app.id == remembered)) return remembered;
    return apps.first.id;
  }

  void selectApp(String appId) {
    if (!state.upiApps.any((app) => app.id == appId)) return;

    final from = state.selectedAppId;
    state = state.copyWith(selectedAppId: appId, clearError: true);

    // Reported from here rather than from the sheet because this is the only place that knows
    // what the choice was before. A switch away from the pre-selected app is a signal in its own
    // right — it usually means the default was wrong, and a wrong default costs conversions.
    if (from != appId) {
      _analytics.track(Ev.upiAppChanged, {
        P.fromAppId: from,
        P.toAppId: appId,
        P.positionInList: state.upiApps.indexWhere((app) => app.id == appId),
        P.availableCount: state.upiApps.length,
      });
      _analytics.registerSuper({P.preferredUpiApp: appId});
    }

    // Fire and forget: the choice is already applied on screen, and a failed write costs one
    // tap on "Change" next time.
    ref.read(upiAppPreferenceProvider).save(appId);
  }

  /// Runs the whole purchase and reports how it ended.
  ///
  /// The SDK's success callback is deliberately not treated as proof — it says the UPI app
  /// handed control back, not that ₹3 moved. Only `subscription-status`, which reconciles
  /// against Cashfree, can answer that — so every path ends by polling it.
  ///
  /// Three outcomes, not two. The poll running out after the SDK reported success is not a
  /// failure: the money may well have moved and the webhook simply has not landed yet. That
  /// case is [PaymentOutcome.pending], and it gets a screen that keeps asking.
  /// Null means the tap was ignored — a second press while the first is still in flight. That
  /// is not an outcome, and reporting it as one would throw up a failure screen over a payment
  /// that is still running.
  Future<PaymentOutcome?> subscribe() async {
    if (state.busy || state.loading) {
      // Without this the tap simply vanishes: no navigation, no state change, nothing to see in
      // the funnel but a user who apparently looked at the button and did not press it. It is
      // also the cheapest available signal that the paywall feels unresponsive.
      _analytics.track(Ev.subscribeTapIgnored, {
        P.reason: state.loading ? 'loading' : 'busy',
        P.attemptNumber: _attempts,
      });
      return null;
    }

    _attempts++;
    _attemptId = _mintAttemptId();
    _attemptStartedAt = DateTime.now();

    final app = state.selectedApp;
    final offerType = state.trialAvailable ? 'trial' : 'plan';
    final price = state.trialAvailable
        ? state.offer?.trialPrice
        : state.offer?.planPrice;

    // Mixpanel's own stopwatch, rather than one measured here: the user is about to leave the
    // process entirely, and the SDK's `$duration` survives that where a Dart `Stopwatch` in a
    // suspended isolate does not.
    _analytics.timeEvent(Ev.paymentCompleted);
    _analytics.track(Ev.subscribeTapped, {
      P.paymentAttemptId: _attemptId,
      P.attemptNumber: _attempts,
      P.appId: app?.id,
      P.offerType: offerType,
      P.amount: price,
      P.flow: app != null ? 'intent' : 'cashfree_checkout',
    });

    state = state.copyWith(phase: SubscriptionPhase.opening, clearError: true);
    final repository = ref.read(subscriptionRepositoryProvider);

    try {
      _analytics.track(Ev.mandateStartRequested, _attemptProperties());
      final mandateStartedAt = DateTime.now();
      final start = await repository.start();

      // The server declined to open a second mandate because this account is already inside a
      // trial or a paid month. Nothing was charged; just let them through.
      if (start.alreadyEntitled) {
        state = state.copyWith(phase: SubscriptionPhase.idle);
        _analytics.track(Ev.mandateAlreadyEntitled, _attemptProperties());
        return _finish(PaymentOutcome.success, sdkVerified: null, pollAttempts: 0);
      }

      _analytics.track(Ev.mandateStartSucceeded, {
        ..._attemptProperties(),
        P.subscriptionId: start.subscriptionId,
        P.environment: start.environment,
        P.ms: DateTime.now().difference(mandateStartedAt).inMilliseconds,
      });

      final checkout = ref.read(cashfreeCheckoutProvider);

      // The last event before control leaves this process. Everything between here and
      // `UPI App Returned` happens in someone else's app.
      _analytics.track(Ev.upiIntentLaunched, {
        ..._attemptProperties(),
        P.appId: app?.id,
        P.appName: app?.displayName,
        P.flow: app != null ? 'intent' : 'cashfree_checkout',
        P.subscriptionId: start.subscriptionId,
      });

      // With an app chosen this launches it straight into the mandate — no Cashfree screen.
      // Without one, Cashfree's own checkout stands in, because it is the only route to the
      // "enter a UPI ID" collect flow that a device with no UPI app needs.
      final result = app != null
          ? await checkout.openWithApp(
              subscriptionId: start.subscriptionId,
              sessionId: start.sessionId,
              environment: start.environment,
              upiAppId: app.id,
            )
          : await checkout.open(
              subscriptionId: start.subscriptionId,
              sessionId: start.sessionId,
              environment: start.environment,
            );

      state = state.copyWith(phase: SubscriptionPhase.confirming);

      // Polled even when the SDK reported failure, and that matters more in the intent flow
      // than it did with the checkout screen: approving in Google Pay and then swiping back
      // instead of waiting for the redirect is ordinary user behaviour, and it surfaces here as
      // a failure on a mandate that actually succeeded. Fewer attempts, because the common case
      // really is a cancellation and nobody wants to watch a spinner for it.
      final maxAttempts = result.verified ? 8 : 3;
      _analytics.track(Ev.entitlementPollStarted, {
        ..._attemptProperties(),
        P.maxAttempts: maxAttempts,
        P.sdkVerified: result.verified,
      });

      final polled = await _pollForEntitlement(maxAttempts);

      state = state.copyWith(phase: SubscriptionPhase.idle);
      if (polled.entitled) {
        return _finish(
          PaymentOutcome.success,
          sdkVerified: result.verified,
          pollAttempts: polled.attempts,
          amount: state.trialAvailable ? null : price,
        );
      }

      // The SDK said the UPI app handed control back, so a debit is plausible and the poll
      // simply ran out first. That is not a failure, and telling the user it was is how a
      // paying customer gets asked to pay twice.
      if (result.verified) {
        return _finish(
          PaymentOutcome.pending,
          sdkVerified: true,
          pollAttempts: polled.attempts,
        );
      }

      state = state.copyWith(
        error: result.message ?? 'The payment was not completed. Please try again.',
      );
      return _finish(
        PaymentOutcome.failed,
        sdkVerified: false,
        pollAttempts: polled.attempts,
        reason: result.message,
      );
    } on SubscriptionException catch (e) {
      // Distinguishable in the log from an SDK failure: this one never reached Cashfree's
      // checkout at all, so no UPI app was ever going to open.
      debugPrint('[subscription] server refused to start the mandate: ${e.message}');
      state = state.copyWith(phase: SubscriptionPhase.idle, error: e.message);
      _analytics.track(Ev.mandateStartRefused, {
        ..._attemptProperties(),
        P.code: e.code,
        P.message: e.message,
      });
      return _finish(PaymentOutcome.failed, sdkVerified: null, pollAttempts: 0, reason: e.code);
    } catch (error) {
      debugPrint('[subscription] purchase failed: $error');
      state = state.copyWith(
        phase: SubscriptionPhase.idle,
        error: 'Could not complete the purchase. Please try again.',
      );
      return _finish(
        PaymentOutcome.failed,
        sdkVerified: null,
        pollAttempts: 0,
        reason: 'unexpected_error',
      );
    }
  }

  /// The funnel-closing event, emitted on every one of the four ways out of [subscribe].
  ///
  /// Centralised so an outcome cannot be returned without being counted — the previous shape had
  /// five separate `return`s and adding a sixth without an event would have been invisible.
  PaymentOutcome _finish(
    PaymentOutcome outcome, {
    required bool? sdkVerified,
    required int pollAttempts,
    String? reason,
    String? amount,
  }) {
    _analytics.track(Ev.paymentCompleted, {
      ..._attemptProperties(),
      P.outcome: outcome.name,
      P.sdkVerified: sdkVerified,
      P.pollAttempts: pollAttempts,
      P.reason: reason,
      P.totalSeconds: _attemptStartedAt == null
          ? null
          : DateTime.now().difference(_attemptStartedAt!).inSeconds,
    });

    // Revenue is only recorded for a debit this client actually saw confirmed. The trial's ₹3 is
    // an authorisation rather than a subscription payment, so it is deliberately not counted as
    // revenue here — it would overstate LTV on every account that trials and churns.
    final charged = double.tryParse((amount ?? '').replaceAll(RegExp(r'[^0-9.]'), ''));
    if (outcome == PaymentOutcome.success && charged != null && charged > 0) {
      _analytics.trackCharge(charged, {P.paymentAttemptId: _attemptId});
    }

    return outcome;
  }

  Map<String, Object?> _attemptProperties() => {
        P.paymentAttemptId: _attemptId,
        P.attemptNumber: _attempts,
      };

  static String _mintAttemptId() =>
      '${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}'
      '-${Random().nextInt(1 << 20).toRadixString(36)}';

  Future<({bool entitled, int attempts})> _pollForEntitlement(int attempts) async {
    final delays = ref.read(subscriptionPollDelaysProvider);

    for (var i = 0; i < attempts; i++) {
      await Future.delayed(delays[i.clamp(0, delays.length - 1)]);
      try {
        final user = await ref.read(subscriptionRepositoryProvider).refreshStatus();
        if (user != null) state = state.copyWith(user: user);
        if (user?.entitled ?? false) return (entitled: true, attempts: i + 1);
      } catch (error) {
        // A dropped poll is not a failed payment. Keep asking — the webhook may still be in
        // flight, and giving up here would tell a paying user they had not paid.
        debugPrint('[subscription] status poll failed: $error');
        _analytics.track(Ev.entitlementPollFailed, {
          ..._attemptProperties(),
          P.attempt: i + 1,
          P.error: error.toString(),
        });
      }
    }
    return (entitled: false, attempts: attempts);
  }
}

final subscriptionViewModelProvider =
    NotifierProvider<SubscriptionViewModel, SubscriptionState>(SubscriptionViewModel.new);
