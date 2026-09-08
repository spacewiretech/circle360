import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';

/// Everything the app does with Firebase Cloud Messaging.
///
/// Nothing here runs at boot. Requesting notification permission is a one-shot, irreversible ask
/// on both platforms — decline it once and the only route back is the system settings screen —
/// so the prompt belongs at a moment the user can make sense of, not on the first frame of a
/// cold start. [requestPermission] is the hook for whichever screen ends up owning that.
///
/// Every method swallows its own failures and reports the neutral answer, matching the contract
/// the [Analytics] interface sets for optional integrations: push is not load-bearing, and a
/// Firebase that failed to initialise must not be able to throw out of here into a widget build.
abstract final class PushMessaging {
  /// Asks the user for notification permission, returning whether it was granted.
  ///
  /// On iOS this is what shows the system prompt; without it FCM has no APNs token and delivers
  /// nothing at all. On Android 13+ it maps to the POST_NOTIFICATIONS runtime permission, and on
  /// older versions it is granted without a prompt.
  static Future<bool> requestPermission() async {
    try {
      final settings = await FirebaseMessaging.instance.requestPermission();
      final status = settings.authorizationStatus;
      return status == AuthorizationStatus.authorized ||
          status == AuthorizationStatus.provisional;
    } catch (error) {
      debugPrint('[push] permission request failed: $error');
      return false;
    }
  }

  /// Whether the user has already granted notification permission.
  ///
  /// Reads the current setting without prompting, so a screen can tell "not asked yet" from
  /// "asked and declined" before deciding whether to show its own explanation.
  static Future<bool> hasPermission() async {
    try {
      final settings = await FirebaseMessaging.instance.getNotificationSettings();
      return settings.authorizationStatus == AuthorizationStatus.authorized;
    } catch (error) {
      debugPrint('[push] could not read notification settings: $error');
      return false;
    }
  }

  /// This device's FCM registration token, or null if there isn't one.
  ///
  /// Null is the normal answer on iOS before permission is granted, because the token cannot be
  /// minted until APNs has registered the app. Ask for permission first.
  ///
  /// The token is not stable: it rotates on reinstall, on restore to a new device, and
  /// occasionally on its own. Anything that stores it server-side must also listen to
  /// [onTokenRefresh], or it will end up sending to an address that stopped existing.
  static Future<String?> token() async {
    try {
      return await FirebaseMessaging.instance.getToken();
    } catch (error) {
      debugPrint('[push] could not read the token: $error');
      return null;
    }
  }

  /// Fires whenever the registration token is replaced. See [token].
  static Stream<String> get onTokenRefresh =>
      FirebaseMessaging.instance.onTokenRefresh;

  /// Messages that arrive while the app is in the foreground.
  ///
  /// The OS does not display these — a foregrounded app is expected to decide for itself whether
  /// a banner is warranted — so a listener here is the only thing that will surface them.
  /// Background and terminated-state messages go to the handler in `mobile_boot_io.dart`.
  static Stream<RemoteMessage> get onMessage => FirebaseMessaging.onMessage;

  /// Fires when the user taps a notification that opened the app from the background.
  ///
  /// Does *not* fire for a tap that cold-started the process; use [initialMessage] for that.
  static Stream<RemoteMessage> get onMessageOpenedApp =>
      FirebaseMessaging.onMessageOpenedApp;

  /// The notification whose tap launched the app, if that is how this run started.
  ///
  /// Consume it once, early — it is the terminated-state counterpart to [onMessageOpenedApp],
  /// and the two together are what makes a push deep-linkable from any app state.
  static Future<RemoteMessage?> initialMessage() async {
    try {
      return await FirebaseMessaging.instance.getInitialMessage();
    } catch (error) {
      debugPrint('[push] could not read the initial message: $error');
      return null;
    }
  }
}
