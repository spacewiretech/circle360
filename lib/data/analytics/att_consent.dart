import 'dart:io' show Platform;

import 'package:app_tracking_transparency/app_tracking_transparency.dart';
import 'package:flutter/foundation.dart';

import 'analytics.dart';
import 'analytics_events.dart';
import 'facebook_analytics.dart';

/// Asks iOS for permission to use the advertising identifier, once per install.
///
/// ## Why this exists
///
/// Without App Tracking Transparency authorisation, iOS hands out no IDFA, and Facebook cannot
/// connect a purchase back to the ad that caused the install. The events still arrive; they
/// simply arrive anonymous, which means the optimiser learns nothing from them and the campaign
/// is flying blind on exactly the conversions that matter most.
///
/// Android needs none of this — the `AD_ID` permission in the manifest is the whole of it.
///
/// ## Why it is asked here and not at launch
///
/// A system permission dialog on the first frame, before the app has shown a single thing worth
/// having, is the lowest-opt-in placement there is — and this app already spends its first
/// screens asking for location, which is the permission it actually needs to work. This is called
/// when the paywall opens instead: onboarding is behind the user, they are looking at the offer,
/// and — the part that actually matters — it is still *before* the purchase, so a granted IDFA is
/// attached to the conversion event rather than arriving a screen too late.
///
/// [ensureTrackingConsent] is also called from Home, for the already-entitled user who never
/// sees a paywall. Both call sites are safe: iOS only ever shows the dialog while the status is
/// `notDetermined`, and every later call returns the standing answer without prompting.
class AttConsent {
  AttConsent._();

  static final AttConsent instance = AttConsent._();

  bool _asked = false;

  /// Requests authorisation if it has not been settled, then mirrors the answer onto Facebook.
  ///
  /// Never throws and never blocks anything the user is doing — a screen that awaited this would
  /// be waiting on a dialog the user may take an arbitrarily long time to read.
  Future<void> ensure() async {
    // Guarded in-process as well as by iOS, so a rebuild cannot queue a second request while the
    // first dialog is still on screen.
    if (_asked || !_isSupported) return;
    _asked = true;

    try {
      final current = await AppTrackingTransparency.trackingAuthorizationStatus;

      // Asking again once the user has answered is a no-op on iOS, but going through the request
      // path anyway would misreport a standing decision as a fresh one in the funnel.
      final status = current == TrackingStatus.notDetermined
          ? await AppTrackingTransparency.requestTrackingAuthorization()
          : current;

      final granted = status == TrackingStatus.authorized;

      // Worth counting: opt-in rate is the ceiling on how much of iOS spend Facebook can
      // attribute at all, and a collapse in it looks exactly like a collapse in conversions.
      analytics.track(Ev.trackingConsentResolved, {
        P.status: status.name,
        P.granted: granted,
        P.prompted: current == TrackingStatus.notDetermined,
      });

      await analyticsSink<FacebookAnalytics>(analytics)
          ?.setAdvertiserIdCollectionEnabled(enabled: granted);
    } catch (error) {
      debugPrint('[att] could not resolve tracking consent: $error');
    }
  }

  /// iOS only, and never in a test: the plugin talks to a platform channel that does not exist
  /// under `flutter test`, and a widget test that reaches a paywall must not hang on it.
  bool get _isSupported {
    if (kIsWeb) return false;
    return Platform.isIOS;
  }
}

/// Convenience for the two call sites that need consent settled before a conversion.
Future<void> ensureTrackingConsent() => AttConsent.instance.ensure();
