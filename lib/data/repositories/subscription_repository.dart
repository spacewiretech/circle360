import '../models/app_user.dart';
import '../models/subscription_offer.dart';

/// Raised when the payment backend refuses. [message] is already safe to show.
class SubscriptionException implements Exception {
  const SubscriptionException(this.message);

  final String message;

  @override
  String toString() => 'SubscriptionException: $message';
}

abstract interface class SubscriptionRepository {
  /// Display copy for the paywall. Never the source of any amount that gets charged.
  Future<SubscriptionOffer> offer();

  /// Opens a Cashfree mandate and returns the checkout session to hand to the SDK.
  ///
  /// Takes no arguments on purpose: the plan and both amounts are read server-side from
  /// `app_config`, so there is no parameter a modified client could use to pay less.
  Future<SubscriptionStart> start();

  /// Re-reads entitlement from the server, reconciling against Cashfree on the way.
  ///
  /// This is what the app polls after checkout — the SDK's success callback proves only that
  /// the sheet closed, not that the money moved.
  Future<AppUser?> refreshStatus();

  /// Stops future debits. Access continues until the paid period ends.
  Future<AppUser?> cancel();
}
