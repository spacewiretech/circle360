import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../data/analytics/analytics.dart';
import '../data/analytics/analytics_events.dart';
import '../data/entitlement.dart';
import '../data/models/app_user.dart';
import '../data/providers.dart';
import 'analytics_observer.dart';
import 'router.dart';

/// Wraps the screens behind the paywall and sends the user back to it when access lapses.
///
/// The splash gate only runs at cold start, which is not enough: the trial is two days long, so
/// it will routinely expire while the app is open in someone's pocket. Without this, a user
/// could keep tracking indefinitely simply by never closing the app.
///
/// Three things can move entitlement, and all three are covered:
///
///  * the clock reaching [AppUser.entitlementExpiresAt] — a timer fires and re-asks the server;
///  * the app coming back to the foreground after a debit succeeded or failed;
///  * a payment confirmed elsewhere, which the resume check also picks up.
///
/// Every one of those re-asks the server rather than deciding locally. The server applies the
/// configured grace window, so a user whose ₹499 is mid-settlement is not thrown out by a
/// client-side clock a few seconds ahead of it.
class EntitlementGate extends ConsumerStatefulWidget {
  const EntitlementGate({super.key, required this.child});

  final Widget child;

  @override
  ConsumerState<EntitlementGate> createState() => _EntitlementGateState();
}

class _EntitlementGateState extends ConsumerState<EntitlementGate>
    with WidgetsBindingObserver {
  Timer? _expiryTimer;

  /// Timers this long are re-armed rather than scheduled outright — a `Timer` set days ahead is
  /// at the mercy of the OS suspending the isolate, and the resume check covers that gap.
  static const _maxTimerHorizon = Duration(hours: 6);

  /// Fire slightly past the expiry instant so the server has already crossed it too.
  static const _expiryBuffer = Duration(seconds: 30);

  bool _checking = false;

  /// Shared across gates, because they are mounted and disposed on every navigation. Without
  /// it, walking home → settings → home would spend three round trips answering a question
  /// nothing could have changed the answer to in between.
  static DateTime? _lastSuccessfulCheck;
  static const _mountCheckInterval = Duration(minutes: 1);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // Deferred: the first frame must not be blocked on the network, and `context.go` cannot run
    // during a build in any case.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final last = _lastSuccessfulCheck;
      if (last != null && DateTime.now().difference(last) < _mountCheckInterval) {
        // Still trust the last answer, but keep the expiry alarm armed for this gate.
        _armExpiryTimer(ref.read(entitlementProvider)?.entitlementExpiresAt);
        return;
      }
      _refresh();
    });
  }

  @override
  void dispose() {
    _expiryTimer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _refresh();
  }

  /// Asks the server who this user is now, and routes them out if they no longer qualify.
  Future<void> _refresh() async {
    if (_checking || !mounted) return;
    _checking = true;

    try {
      final user = await ref.read(authRepositoryProvider).currentUser();
      _lastSuccessfulCheck = DateTime.now();
      if (!mounted) return;

      ref.read(entitlementProvider.notifier).set(user);

      // A null user means the session itself is gone, which is a sign-in problem rather than a
      // payment one — send them to the start of onboarding, not to the paywall.
      if (user == null) {
        _reportEviction(null, 'session_lost');
        context.go(Routes.phone);
        return;
      }
      if (!user.entitled) {
        _reportEviction(user, 'not_entitled');
        context.go(Routes.subscribe);
        return;
      }

      _armExpiryTimer(user.entitlementExpiresAt);
    } catch (_) {
      // An unreachable backend must not evict a paying user. The cached entitlement stands
      // until a call actually succeeds.
    } finally {
      _checking = false;
    }
  }

  /// Someone was inside the paid app and has just been put back outside it.
  ///
  /// Worth its own event rather than being left to look like an ordinary paywall visit: a user
  /// who was evicted mid-session converts very differently from one arriving at the paywall for
  /// the first time, and without this they are the same row in every funnel. The screen they were
  /// thrown out of is the interesting part — a trial expiring while someone is watching the map
  /// is a different product problem from one expiring on the settings screen.
  void _reportEviction(AppUser? user, String reason) {
    analytics.track(Ev.entitlementLapsed, {
      P.reason: reason,
      P.screen: analyticsObserver.currentScreen,
      P.previousPaymentType: user?.paymentType.name,
      P.billingState: user?.billingState?.name,
    });
  }

  void _armExpiryTimer(DateTime? expiresAt) {
    _expiryTimer?.cancel();
    if (expiresAt == null) return;

    final until = expiresAt.add(_expiryBuffer).difference(DateTime.now());
    if (until.isNegative) {
      // Already past it and the server still says entitled — that is the grace window doing its
      // job. Look again when the grace could plausibly have run out.
      _expiryTimer = Timer(_maxTimerHorizon, _refresh);
      return;
    }

    _expiryTimer = Timer(
      until < _maxTimerHorizon ? until : _maxTimerHorizon,
      _refresh,
    );
  }

  @override
  Widget build(BuildContext context) {
    // A payment confirmed on the paywall pushes the new user through this provider, so an
    // entitlement that goes away for any other reason is caught here too.
    ref.listen(entitlementProvider, (_, user) {
      if (user != null && !user.entitled && mounted) {
        _reportEviction(user, 'entitlement_changed');
        context.go(Routes.subscribe);
      }
    });

    return widget.child;
  }
}
