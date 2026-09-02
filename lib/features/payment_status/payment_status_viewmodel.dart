import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/entitlement.dart';
import '../../data/providers.dart';
import '../subscription/subscription_viewmodel.dart';

/// What the pending screen is doing while it waits for a mandate to confirm.
@immutable
class PaymentStatusState {
  const PaymentStatusState({this.checking = false, this.confirmed = false, this.attempts = 0});

  /// A status call is in flight, so the button shows a spinner rather than flapping.
  final bool checking;

  /// The server has said the user is entitled. The view advances on this.
  final bool confirmed;

  /// How many polls have been spent, so the backoff can lengthen and the copy can eventually
  /// admit that this is taking longer than it should.
  final int attempts;

  /// Long enough that a slow settlement is not called a failure, short enough that the user is
  /// not watching a spinner forever.
  bool get exhausted => attempts >= 12;

  PaymentStatusState copyWith({bool? checking, bool? confirmed, int? attempts}) =>
      PaymentStatusState(
        checking: checking ?? this.checking,
        confirmed: confirmed ?? this.confirmed,
        attempts: attempts ?? this.attempts,
      );
}

/// Keeps asking the server whether a pending payment has landed.
///
/// This exists because the checkout poll on the paywall gives up after about half a minute,
/// which is not long enough for every UPI mandate. Before, that timeout was the end of the
/// road: the user was left on the paywall being told we could not confirm the payment, with no
/// route forward even once the webhook arrived a minute later. Here the waiting is the screen's
/// whole job, so it can afford to keep asking.
class PaymentStatusViewModel extends Notifier<PaymentStatusState> {
  Timer? _timer;

  @override
  PaymentStatusState build() {
    ref.onDispose(() => _timer?.cancel());
    return const PaymentStatusState();
  }

  /// Starts the backoff. Safe to call more than once; a second call is ignored while a poll is
  /// already scheduled.
  void start() {
    if (_timer != null || state.confirmed) return;
    _scheduleNext();
  }

  void _scheduleNext() {
    if (state.confirmed || state.exhausted) return;

    // Shared with the paywall's own post-checkout poll so both back off identically, and so a
    // test can collapse either of them the same way.
    final delays = ref.read(subscriptionPollDelaysProvider);
    final delay = delays[state.attempts.clamp(0, delays.length - 1)];

    _timer?.cancel();
    _timer = Timer(delay, () {
      _timer = null;
      check();
    });
  }

  /// Asks the server once, then re-arms unless it has an answer. Also what the button calls.
  Future<void> check() async {
    if (state.checking || state.confirmed) return;
    state = state.copyWith(checking: true, attempts: state.attempts + 1);

    try {
      final user = await ref.read(subscriptionRepositoryProvider).refreshStatus();
      if (user != null) ref.read(entitlementProvider.notifier).set(user);

      if (user?.entitled ?? false) {
        _timer?.cancel();
        _timer = null;
        state = state.copyWith(checking: false, confirmed: true);
        return;
      }
    } catch (error) {
      // A dropped poll is not a failed payment. Keep asking — giving up here would tell a
      // paying user they had not paid.
      debugPrint('[payment-status] poll failed: $error');
    }

    state = state.copyWith(checking: false);
    _scheduleNext();
  }
}

final paymentStatusViewModelProvider =
    NotifierProvider<PaymentStatusViewModel, PaymentStatusState>(PaymentStatusViewModel.new);
