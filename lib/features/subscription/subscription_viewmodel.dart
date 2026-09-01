import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/models/app_user.dart';
import '../../data/models/subscription_offer.dart';
import '../../data/models/upi_app.dart';
import '../../data/providers.dart';
import '../../data/repositories/subscription_repository.dart';

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
  bool get trialAvailable => !(user?.hasEverSubscribed ?? false);

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
  @override
  SubscriptionState build() {
    _load();
    return const SubscriptionState();
  }

  Future<void> _load() async {
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

      state = state.copyWith(
        offer: results[0] as SubscriptionOffer,
        user: results[1] as AppUser?,
        upiApps: apps,
        selectedAppId: _resolveSelection(apps, remembered),
        loading: false,
      );
    } catch (error) {
      debugPrint('[subscription] could not load the offer: $error');
      state = state.copyWith(
        loading: false,
        error: 'Could not load the plan. Please check your connection and try again.',
      );
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
    state = state.copyWith(selectedAppId: appId, clearError: true);
    // Fire and forget: the choice is already applied on screen, and a failed write costs one
    // tap on "Change" next time.
    ref.read(upiAppPreferenceProvider).save(appId);
  }

  /// Runs the whole purchase. Returns true only when the server confirms entitlement.
  ///
  /// The SDK's success callback is deliberately not treated as proof — it says the UPI app
  /// handed control back, not that ₹3 moved. Only `subscription-status`, which reconciles
  /// against Cashfree, can answer that — so every path ends by polling it.
  Future<bool> subscribe() async {
    if (state.busy || state.loading) return false;

    state = state.copyWith(phase: SubscriptionPhase.opening, clearError: true);
    final repository = ref.read(subscriptionRepositoryProvider);

    try {
      final start = await repository.start();
      // The server declined to open a second mandate because this account is already inside a
      // trial or a paid month. Nothing was charged; just let them through.
      if (start.alreadyEntitled) {
        state = state.copyWith(phase: SubscriptionPhase.idle);
        return true;
      }

      final checkout = ref.read(cashfreeCheckoutProvider);
      final app = state.selectedApp;

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
      final entitled = await _pollForEntitlement(result.verified ? 8 : 3);

      if (entitled) {
        state = state.copyWith(phase: SubscriptionPhase.idle);
        return true;
      }

      state = state.copyWith(
        phase: SubscriptionPhase.idle,
        error: result.verified
            ? 'We could not confirm your payment yet. If the amount was deducted your '
                'subscription will activate shortly — try again in a minute.'
            : result.message ?? 'The payment was not completed. Please try again.',
      );
      return false;
    } on SubscriptionException catch (e) {
      state = state.copyWith(phase: SubscriptionPhase.idle, error: e.message);
      return false;
    } catch (error) {
      debugPrint('[subscription] purchase failed: $error');
      state = state.copyWith(
        phase: SubscriptionPhase.idle,
        error: 'Could not complete the purchase. Please try again.',
      );
      return false;
    }
  }

  Future<bool> _pollForEntitlement(int attempts) async {
    final delays = ref.read(subscriptionPollDelaysProvider);

    for (var i = 0; i < attempts; i++) {
      await Future.delayed(delays[i.clamp(0, delays.length - 1)]);
      try {
        final user = await ref.read(subscriptionRepositoryProvider).refreshStatus();
        if (user != null) state = state.copyWith(user: user);
        if (user?.entitled ?? false) return true;
      } catch (error) {
        // A dropped poll is not a failed payment. Keep asking — the webhook may still be in
        // flight, and giving up here would tell a paying user they had not paid.
        debugPrint('[subscription] status poll failed: $error');
      }
    }
    return false;
  }
}

final subscriptionViewModelProvider =
    NotifierProvider<SubscriptionViewModel, SubscriptionState>(SubscriptionViewModel.new);
