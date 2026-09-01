import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_cashfree_pg_sdk/api/cferrorresponse/cferrorresponse.dart';
import 'package:flutter_cashfree_pg_sdk/api/cfpayment/cfsubscriptioncheckoutpayment.dart';
import 'package:flutter_cashfree_pg_sdk/api/cfpayment/subs/cfsubsupi.dart';
import 'package:flutter_cashfree_pg_sdk/api/cfpayment/subs/cfsubsupipayment.dart';
import 'package:flutter_cashfree_pg_sdk/api/cfpaymentgateway/cfpaymentgatewayservice.dart';
import 'package:flutter_cashfree_pg_sdk/api/cfsession/cfsubssession.dart';
import 'package:flutter_cashfree_pg_sdk/api/cftheme/cftheme.dart';
import 'package:flutter_cashfree_pg_sdk/api/cfupi/cfupiutils.dart';
import 'package:flutter_cashfree_pg_sdk/utils/cfenums.dart';

import '../models/upi_app.dart';

/// How the mandate flow ended.
///
/// Neither value is proof of anything financial. `verified` says the UPI app handed control
/// back; whether ₹3 actually moved is a question only the server can answer, which is why
/// every outcome here is followed by polling `subscription-status`.
enum CheckoutOutcome { verified, failed }

@immutable
class CheckoutResult {
  const CheckoutResult(this.outcome, [this.message]);

  final CheckoutOutcome outcome;
  final String? message;

  bool get verified => outcome == CheckoutOutcome.verified;
}

abstract interface class CashfreeCheckout {
  /// The UPI apps installed on this device, best-effort.
  ///
  /// An empty list is a normal answer — it means the picker is hidden and [open] is used
  /// instead — so this never throws.
  Future<List<UpiApp>> installedApps();

  /// Launches [upiAppId] straight into the mandate, with no Cashfree screen in between.
  Future<CheckoutResult> openWithApp({
    required String subscriptionId,
    required String sessionId,
    required String environment,
    required String upiAppId,
  });

  /// Cashfree's own checkout screen. The fallback for a device with no UPI app installed,
  /// because it is the only route to the "enter a UPI ID" collect flow.
  Future<CheckoutResult> open({
    required String subscriptionId,
    required String sessionId,
    required String environment,
  });
}

/// Wraps `flutter_cashfree_pg_sdk`'s subscription payments.
///
/// Three things about that SDK shape this class:
///
/// 1. [CFPaymentGatewayService] is a singleton whose callbacks are *static*. Registering them
///    per-attempt would let a late callback from an abandoned one resolve the current one, so
///    they are registered once and routed to whichever request is actually in flight.
/// 2. `setCallback` also drains a response left over by the native side — which is how a
///    payment that survived the app being killed reports back. That arrives with nothing
///    waiting for it, so a callback with no pending request is ignored rather than treated as
///    an error; the status poll picks that case up instead.
/// 3. Both the element (direct-intent) and checkout flows report through the *same*
///    `CFSubscriptionResponseCallback`, so the plumbing below is shared between them.
class SdkCashfreeCheckout implements CashfreeCheckout {
  SdkCashfreeCheckout();

  /// Belt to the SDK's braces. If the native side ever returns through neither callback, the
  /// UI would sit on a spinner forever; this guarantees the future always resolves.
  static const _timeout = Duration(minutes: 5);

  /// App discovery is a nicety, and the paywall blocks on it while it loads. `getUPIApps` is a
  /// bare method-channel call with no timeout of its own, so a native side that never answers
  /// would leave the screen on a spinner with no plan row and no button — strictly worse than
  /// having no picker. Three seconds is far longer than reading the installed-app list takes.
  static const _discoveryTimeout = Duration(seconds: 3);

  final _gateway = CFPaymentGatewayService();

  Completer<CheckoutResult>? _pending;
  bool _callbacksRegistered = false;

  @override
  Future<List<UpiApp>> installedApps() async {
    try {
      final raw = await CFUPIUtils().getUPIApps().timeout(_discoveryTimeout);
      final apps = UpiApp.listFrom(raw);
      // Logged because an empty list and a failed lookup look identical on screen — both hide
      // the picker and fall back to the Cashfree checkout — but mean very different things
      // when someone is asking why the picker did not appear on their phone.
      debugPrint('[cashfree] ${apps.length} UPI app(s) found: '
          '${apps.map((a) => a.id).join(', ')}');
      return apps;
    } catch (error) {
      // Discovery is a convenience, not a requirement — a throw, a timeout or a platform that
      // has no such channel all mean the same thing here. Degrade to the checkout-screen
      // fallback; never let this break the paywall.
      debugPrint('[cashfree] could not list UPI apps: $error');
      return const [];
    }
  }

  void _registerCallbacks() {
    if (_callbacksRegistered) return;
    _callbacksRegistered = true;
    _gateway.setCallback(_onVerify, _onError);
  }

  void _onVerify(String subscriptionId) {
    _complete(const CheckoutResult(CheckoutOutcome.verified));
  }

  void _onError(CFErrorResponse error, String _) {
    _complete(CheckoutResult(CheckoutOutcome.failed, error.getMessage()));
  }

  void _complete(CheckoutResult result) {
    final pending = _pending;
    _pending = null;
    if (pending == null || pending.isCompleted) {
      // A result for an attempt nobody is waiting on — usually one that outlived the app being
      // killed. Harmless: the entitlement poll on the next screen covers it.
      debugPrint('[cashfree] payment result arrived with no pending request');
      return;
    }
    pending.complete(result);
  }

  CFSubscriptionSession _session({
    required String subscriptionId,
    required String sessionId,
    required String environment,
  }) {
    return CFSubscriptionSessionBuilder()
        .setEnvironment(
          environment.toLowerCase() == 'sandbox'
              ? CFEnvironment.SANDBOX
              : CFEnvironment.PRODUCTION,
        )
        .setSubscriptionId(subscriptionId)
        .setSubscriptionSessionId(sessionId)
        .build();
  }

  /// Shared start/finish handling for both flows. [launch] builds and dispatches the payment.
  Future<CheckoutResult> _run(void Function() launch) {
    // A second attempt cannot run over the first. Fail the old one rather than leaving its
    // future dangling forever.
    _complete(const CheckoutResult(CheckoutOutcome.failed, 'Payment restarted.'));

    _registerCallbacks();
    final completer = Completer<CheckoutResult>();
    _pending = completer;

    try {
      launch();
    } catch (error) {
      debugPrint('[cashfree] could not start the payment: $error');
      _complete(const CheckoutResult(
        CheckoutOutcome.failed,
        'Could not open the payment screen. Please try again.',
      ));
      return completer.future;
    }

    return completer.future.timeout(
      _timeout,
      onTimeout: () {
        _pending = null;
        return const CheckoutResult(CheckoutOutcome.failed, 'The payment timed out.');
      },
    );
  }

  @override
  Future<CheckoutResult> openWithApp({
    required String subscriptionId,
    required String sessionId,
    required String environment,
    required String upiAppId,
  }) {
    return _run(() {
      // `setUPIID` is named for the collect flow, but under INTENT the SDK reads it as the id
      // of the app to launch — the package name on Android, the URL scheme on iOS. It is
      // passed through exactly as `getUPIApps` gave it to us.
      final upi = CFSubsUPIBuilder()
          .setChannel(CFSubsUPIChannel.INTENT)
          .setUPIID(upiAppId)
          .build();

      _gateway.doPayment(
        CFSubsUPIPaymentBuilder()
            .setSession(_session(
              subscriptionId: subscriptionId,
              sessionId: sessionId,
              environment: environment,
            ))
            .setUPI(upi)
            .build(),
      );
    });
  }

  @override
  Future<CheckoutResult> open({
    required String subscriptionId,
    required String sessionId,
    required String environment,
  }) {
    return _run(() {
      final theme = CFThemeBuilder()
          .setNavigationBarBackgroundColorColor('#026BFE')
          .setNavigationBarTextColor('#FFFFFF')
          .setPrimaryTextColor('#0A1544')
          .build();

      _gateway.doPayment(
        CFSubscriptionPaymentBuilder()
            .setSession(_session(
              subscriptionId: subscriptionId,
              sessionId: sessionId,
              environment: environment,
            ))
            .setTheme(theme)
            .build(),
      );
    });
  }
}
