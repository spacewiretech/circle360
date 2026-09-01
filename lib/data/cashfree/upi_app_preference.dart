import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Remembers which UPI app the user last paid with, so the paywall opens on it next time.
///
/// SharedPreferences rather than [SessionStore]: that one is `flutter_secure_storage`, for the
/// bearer token. A cosmetic preference does not belong in the Keychain, and putting it there
/// would mean it survived a sign-out that is supposed to clear everything.
///
/// Every method swallows its failures. Losing this preference costs the user one tap on
/// "Change"; letting it throw would take down the paywall.
class UpiAppPreference {
  const UpiAppPreference();

  static const _key = 'loc360.upi_app';

  Future<String?> read() async {
    try {
      return (await SharedPreferences.getInstance()).getString(_key);
    } catch (error) {
      debugPrint('[cashfree] could not read the saved UPI app: $error');
      return null;
    }
  }

  Future<void> save(String appId) async {
    try {
      await (await SharedPreferences.getInstance()).setString(_key, appId);
    } catch (error) {
      debugPrint('[cashfree] could not save the UPI app choice: $error');
    }
  }
}
