import 'package:facebook_app_events/facebook_app_events.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/app_user.dart';
import '../repositories/app_config_repository.dart';
import 'analytics.dart';
import 'analytics_events.dart';

/// Reports conversions to Facebook Ads.
///
/// The app is bought through Facebook Ads, and an ad optimiser that only ever sees installs will
/// happily buy installs that never pay. This is the feedback loop that lets it buy payers instead.
///
/// ## Why this drops almost everything
///
/// It implements the full [Analytics] interface so it can sit behind [MultiAnalytics] beside
/// Mixpanel without a single call site knowing it exists — but it is emphatically *not* a second
/// Mixpanel. Only the events in [_conversions] cross to Facebook; the other ~70 this app fires,
/// every screen view and every tap, are dropped on the floor here.
///
/// That is deliberate. Facebook's event catalogue is an ad-targeting surface, not an analytics
/// warehouse: custom events dilute the standard ones the optimiser is actually trained on, they
/// are capped, and each one is a network call on a phone that is usually mid-payment. The rule is
/// that Facebook learns what it needs to buy the right users, and nothing else.
///
/// ## Why the credentials are split
///
/// The App ID and Client Token live in the native manifest and plist, because both SDKs read them
/// at process start — before Dart runs, and long before `app_config` resolves. Neither is a
/// secret: both ship inside every installed app by design. What lives in `app_config` is the
/// *switch* ([facebookEnabledKey]) and the prices, so reporting can be turned off, or a price
/// corrected, without shipping a release. The Facebook **app secret** is not used here and must
/// never be: it is a server-side Conversions API credential, and this app has no Conversions API.
class FacebookAnalytics implements Analytics {
  FacebookAnalytics({
    FacebookAppEvents? events,
    SharedPreferencesAsync? preferences,
    this.contentId = 'circle360_subscription',
  })  : _events = events ?? FacebookAppEvents(),
        _preferences = preferences ?? SharedPreferencesAsync();

  final FacebookAppEvents _events;
  final SharedPreferencesAsync _preferences;

  /// What this app calls its subscription to Facebook.
  ///
  /// Both apps in this build report to the **same Facebook app**, and [registerSuper] is a no-op
  /// here because Facebook's parameters are per-event — so unlike Mixpanel there is no ambient
  /// `app` property. This is the only thing distinguishing the two products' conversions on the
  /// Facebook side. Supplied by the caller from `AppVariant.fbContentId`; the default keeps every
  /// existing call site and test reporting exactly what it always did.
  final String contentId;

  /// The one purchase this app can ever report, remembered across launches.
  ///
  /// See [_logPurchase] for why a flag on disk is the only thing that can hold this line.
  static const _purchaseReportedKey = 'loc360.fb_purchase_reported';

  /// The events Facebook is allowed to see. Everything else [track] ignores.
  ///
  /// Four, chosen to give the optimiser a funnel it can train on before there are enough weekly
  /// purchases to optimise for purchases directly — which, on a ₹3 trial, takes a while.
  static const _conversions = {
    Ev.signupCompleted,
    Ev.subscribeTapped,
    Ev.paymentCompleted,
    Ev.paymentConfirmedLate,
  };

  bool _started = false;
  double _trialAmount = 0;
  double _planAmount = 0;
  String _currency = 'INR';

  /// True once [start] has been handed a real App ID and told it is enabled.
  ///
  /// Every method below returns early on false, so an unconfigured build behaves exactly as it
  /// did before Facebook existed.
  bool get isActive => _started;

  /// Brings the sink up, or deliberately leaves it down.
  ///
  /// A blank [appId] or `enabled: false` is not an error — it is the off switch, and it is the
  /// correct state for any checkout that has not been pointed at a Facebook app. Mirrors how
  /// [MixpanelAnalytics] treats a blank token.
  ///
  /// [appId] is only ever compared against blank: the value the SDK actually initialises from is
  /// the one in the native manifest and plist. Passing it here is what lets a cleared
  /// `app_config` row switch reporting off without a release.
  Future<void> start({
    String? appId,
    required bool enabled,
    required double trialAmount,
    required double planAmount,
    required String currency,
  }) async {
    if (_started) return;

    if (!enabled || appId == null || appId.trim().isEmpty) {
      debugPrint('[facebook] not started: no app id or disabled in app_config');
      return;
    }

    _trialAmount = trialAmount;
    _planAmount = planAmount;
    if (currency.trim().isNotEmpty) _currency = currency.trim().toUpperCase();
    _started = true;

    try {
      // Install and session events, which is how Facebook attributes an install to the ad that
      // caused it. Left on: turning it off would leave the conversions below with no install to
      // attach to, which is most of the point of being here.
      await _events.setAutoLogAppEventsEnabled(true);
      if (kDebugMode) await _events.setDebugLoggingEnabled(true);
    } catch (error) {
      debugPrint('[facebook] could not configure the SDK: $error');
    }

    // Logged because the alternative is silence, and silence here is indistinguishable from the
    // sink never having started. The boot pass runs against the disk cache and legitimately does
    // nothing on a first launch, so the only way to know reporting is live is to say so.
    debugPrint(
      '[facebook] reporting conversions to app $appId '
      '(trial $_currency $_trialAmount, plan $_currency $_planAmount)',
    );
  }

  /// Routes an allowlisted event to its Facebook standard event, or drops it.
  ///
  /// Never awaits: this sits inside a payment callback, and the SDK batches on its own schedule.
  @override
  void track(String event, [Map<String, Object?> properties = const {}]) {
    if (!_started || !_conversions.contains(event)) return;

    try {
      switch (event) {
        // The account exists and is usable. Facebook's registration event, and the first point
        // in the funnel where a click has become a person.
        case Ev.signupCompleted:
          _events.logCompletedRegistration(registrationMethod: 'phone_otp');

        // Reached the UPI hand-off. Fires whether or not the payment lands, which is what makes
        // it useful: it is the last step the user controls, so the gap between this and a
        // purchase is checkout friction rather than intent.
        case Ev.subscribeTapped:
          _events.logInitiatedCheckout(
            totalPrice: _amountFor(properties[P.offerType]),
            currency: _currency,
            contentId: contentId,
            numItems: 1,
            paymentInfoAvailable: false,
          );

        // The paywall's own poll saw the entitlement flip. `outcome` carries failed and pending
        // attempts through this same event, so the guard is what stops a declined payment being
        // reported as a sale.
        case Ev.paymentCompleted:
          if (properties[P.outcome] != 'success') return;
          _logPurchase(properties);

        // The webhook landed after the paywall gave up and sent the user to the status screen.
        // Real money, just late — and the only success path that does not pass through
        // `Payment Completed`, so omitting it would silently lose those conversions.
        case Ev.paymentConfirmedLate:
          _logPurchase(properties);
      }
    } catch (error) {
      debugPrint('[facebook] could not log $event: $error');
    }
  }

  /// Reports the mandate authorisation as both a purchase and a trial start.
  ///
  /// Both, because they answer different questions for the optimiser: `Purchase` carries the
  /// value it bids against, `StartTrial` is the subscription-specific signal Facebook's own
  /// guidance asks for. Facebook expects to receive both for a trial-led subscription and does
  /// not treat them as duplicates.
  ///
  /// ## The de-duplication is not optional
  ///
  /// Two things can report the same ₹3 twice. `Payment Completed(success)` and
  /// `Payment Confirmed Late` are mutually exclusive within one attempt — but a user whose first
  /// payment was never detected can come back and tap subscribe again, and the server's
  /// `alreadyEntitled` branch answers with a success that has charged nothing. A flag in memory
  /// would not catch it: the app is routinely killed during the UPI hand-off, so the second
  /// attempt is usually a fresh process. Hence a flag on disk.
  ///
  /// Written *before* the SDK call and never cleared. Over-reporting inflates ROAS and teaches
  /// the optimiser to buy the wrong people; a lost conversion after a reinstall costs one row.
  Future<void> _logPurchase(Map<String, Object?> properties) async {
    try {
      if (await _preferences.getBool(_purchaseReportedKey) ?? false) {
        debugPrint('[facebook] purchase already reported, not sending a second');
        return;
      }
      await _preferences.setBool(_purchaseReportedKey, true);
    } catch (error) {
      // A preferences failure must not become a silent double-report, so this gives up on the
      // conversion rather than on the guard.
      debugPrint('[facebook] could not read the purchase guard, skipping: $error');
      return;
    }

    final amount = _amountFor(properties[P.offerType]);
    final orderId = properties[P.paymentAttemptId]?.toString() ??
        '${contentId}_${DateTime.now().millisecondsSinceEpoch}';

    await _events.logPurchase(
      amount: amount,
      currency: _currency,
      parameters: {'fb_content_id': contentId, 'fb_order_id': orderId},
    );
    await _events.logStartTrial(price: amount, currency: _currency, orderId: orderId);
  }

  /// The charge for an offer type, from the amounts `app_config` supplied at [start].
  ///
  /// Anything that is not explicitly `'plan'` is priced as the trial, including a missing value.
  /// The trial is both the overwhelmingly common case and the smaller number, so an event that
  /// somehow arrives without an `offer_type` under-reports rather than inflating ROAS — and an
  /// optimiser fed an inflated value learns to buy the wrong people, which is far more expensive
  /// to undo than a conversion booked a few rupees light.
  double _amountFor(Object? offerType) => offerType == 'plan' ? _planAmount : _trialAmount;

  /// Hands Facebook what it needs to match this user to the person who saw the ad.
  ///
  /// Only the phone number and the account id, both hashed by the SDK before they leave the
  /// device. Deliberately not the name: it raises no match rate worth having and is the kind of
  /// data that should not be sent to an ad network for no return.
  ///
  /// The number goes out in E.164 form, as it does to Mixpanel. [AppUser.phone] is the bare
  /// ten-digit Indian number the user signed in with, and Facebook matches hashed phone numbers
  /// against profiles that carry a country code — a bare `98…` matches nothing at all.
  @override
  void identify(AppUser user) {
    if (!_started) return;
    try {
      _events.setUserID(user.id);
      _events.setUserData(phone: '+91${user.phone}', externalId: user.id);
    } catch (error) {
      debugPrint('[facebook] could not identify: $error');
    }
  }

  /// Sign-out only. Leaves [_purchaseReportedKey] alone — the guard is a property of the device,
  /// and signing out is not a reason to be allowed to report a second purchase.
  @override
  void reset() {
    if (!_started) return;
    try {
      _events.clearUserData();
      _events.clearUserID();
    } catch (error) {
      debugPrint('[facebook] could not reset: $error');
    }
  }

  @override
  void flush() {
    if (!_started) return;
    try {
      _events.flush();
    } catch (error) {
      debugPrint('[facebook] could not flush: $error');
    }
  }

  /// Aligns advertiser-ID collection with the user's tracking consent.
  ///
  /// Without an advertising identifier the SDK still delivers events, but Facebook cannot tie
  /// them back to the ad that caused the install — the conversions arrive unattributed and the
  /// optimiser learns nothing from them.
  ///
  /// Note what this is *not*: the older `setAdvertiserTracking` is deprecated and ignored by the
  /// iOS SDK from v17, because consent on iOS is no longer something an app asserts — the SDK
  /// reads `ATTrackingManager` itself. So on iOS the thing that actually grants access is the ATT
  /// prompt in `att_consent.dart`, and this call only mirrors that answer onto the collection
  /// flag. On Android there is no tracking gate at all and this is the whole of it.
  Future<void> setAdvertiserIdCollectionEnabled({required bool enabled}) async {
    if (!_started) return;
    try {
      await _events.setAdvertiserIdCollectionEnabled(enabled);
    } catch (error) {
      debugPrint('[facebook] could not set advertiser id collection: $error');
    }
  }

  /// No Facebook equivalent. Event timing is a product-analytics question and stays with Mixpanel.
  @override
  void timeEvent(String event) {}

  /// No Facebook equivalent. Facebook's parameters are per-event and its catalogue is fixed, so
  /// there is nothing for a super property to attach to.
  @override
  void registerSuper(Map<String, Object?> properties) {}

  /// Revenue reaches Facebook through `logPurchase` in [_logPurchase], which is de-duplicated.
  /// Routing a second, unguarded path to the same place is how a purchase gets counted twice.
  @override
  void trackCharge(double amount, [Map<String, Object?> properties = const {}]) {}
}

/// Starts [facebook] from a resolved `app_config` map.
///
/// Shared by the boot sequence and `analyticsBootstrapProvider`, which start the sink from the
/// disk cache and from the fetched config respectively. Keeping the key names in one place is
/// what stops those two disagreeing about which config means "on" — a disagreement that would
/// show up as reporting that works on the second launch and not the first.
Future<void> startFacebook(FacebookAnalytics facebook, Map<String, String> config) =>
    facebook.start(
      appId: config.configString(facebookAppIdKey),
      enabled: config.configFlag(facebookEnabledKey),
      trialAmount: config.configDouble('trial_price_amount'),
      planAmount: config.configDouble('plan_price_amount'),
      currency: config.configString('currency_code'),
    );
