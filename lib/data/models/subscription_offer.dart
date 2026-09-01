import 'package:flutter/foundation.dart';

/// What the paywall offers: ₹3 opens a short trial, then the plan price recurs monthly.
///
/// Every field here is display copy. The amounts that are actually charged live in the Cashfree
/// plan and in private `app_config` rows — nothing the client holds can change what is billed.
@immutable
class SubscriptionOffer {
  const SubscriptionOffer({
    required this.trialPrice,
    required this.planPrice,
    required this.trialDays,
    this.strikePrice,
  });

  /// Formatted with the currency symbol, e.g. `₹3`.
  final String trialPrice;
  final String planPrice;

  /// Shown struck through beside [planPrice] when there is a discount to show.
  final String? strikePrice;

  final int trialDays;

  /// The mandate consent line. UPI Autopay requires the recurring amount and cadence to be
  /// stated before authorisation, so this is a compliance requirement, not marketing copy.
  String get consent =>
      '$trialPrice today. $planPrice/month will be auto-debited from your UPI '
      'after $trialDays days. Cancel anytime.';
}

/// The result of asking the server to open a mandate.
@immutable
class SubscriptionStart {
  const SubscriptionStart.entitled()
      : alreadyEntitled = true,
        subscriptionId = '',
        sessionId = '',
        environment = '';

  const SubscriptionStart.pending({
    required this.subscriptionId,
    required this.sessionId,
    required this.environment,
  }) : alreadyEntitled = false;

  /// True when the server found the caller already inside a trial or a paid month and declined
  /// to open a second mandate. The app should simply move on rather than charging again.
  final bool alreadyEntitled;

  final String subscriptionId;

  /// Cashfree's `subscription_session_id`, handed straight to the SDK.
  final String sessionId;

  /// `production` or `sandbox`, chosen server-side so a build cannot point itself elsewhere.
  final String environment;
}
