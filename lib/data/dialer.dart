import 'package:flutter/foundation.dart';
import 'package:url_launcher/url_launcher.dart';

/// Opens the phone's dialer with [raw] already typed in.
///
/// The dialer, not a direct call: `tel:` hands the number over and leaves the green button to
/// the user. Placing the call outright would need `CALL_PHONE` on Android and the Play Store
/// declaration that comes with it, to buy nothing the user wants — they are one tap from the
/// call either way, and one tap from backing out of a misdial.
///
/// Returns null when the dialer opened, or a message to show the user when it did not.
Future<String?> dialNumber(String raw) async {
  final number = sanitiseForDialling(raw);
  if (number.isEmpty) return 'No phone number on file for them.';

  try {
    // Deliberately not guarded by `canLaunchUrl`. It answers on package/scheme visibility, and
    // returns false on Android 11+ without a matching `<queries>` entry and on iOS without one
    // in LSApplicationQueriesSchemes — turning a working dialer into a silent no-op. Both
    // manifests declare `tel` now; this still just tries, and reports it if it fails.
    final opened = await launchUrl(
      Uri(scheme: 'tel', path: number),
      mode: LaunchMode.externalApplication,
    );
    return opened ? null : 'Could not open the dialer.';
  } on Object catch (error) {
    debugPrint('[dialer] tel:$number failed: $error');
    return 'Could not open the dialer.';
  }
}

/// Strips a number down to what `tel:` accepts.
///
/// Numbers reach us in two shapes: an emergency contact is stored as the user typed it
/// ("+91 8764597659"), while a tracked person carries the bare 10-digit `mobile_no`. Both dial
/// correctly once the punctuation is gone, so no country code is assumed — prefixing a bare
/// 10-digit number with +91 would be a guess, and a wrong one outside India.
@visibleForTesting
String sanitiseForDialling(String raw) {
  final trimmed = raw.trim();
  final digits = trimmed.replaceAll(RegExp(r'[^0-9]'), '');
  if (digits.isEmpty) return '';
  // Only a leading plus survives; one appearing mid-number is punctuation, not a country code.
  return trimmed.startsWith('+') ? '+$digits' : digits;
}
