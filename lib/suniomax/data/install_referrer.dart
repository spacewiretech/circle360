import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// The Play Store install referrer — the campaign payload attached to the store link.
///
/// Android only. The native half is `InstallReferrer.kt`; everything here treats an absent
/// channel the same as an absent Play Store, which is what makes the file safe to import from
/// tests, from iOS and from the web build.

const _channel = MethodChannel('circle360/referrer');

/// The raw referrer string, or null when Play could not answer.
///
/// Null is not "organic" — an organic install answers `utm_source=google-play&utm_medium=organic`,
/// which is a real answer. Null means *ask again next launch*, and callers must not persist it.
///
/// Every failure collapses to null on purpose: a `MissingPluginException` (iOS, a widget test, the
/// web build), a device with no Play Store, and a Play Services that timed out are all the same
/// answer as far as the gate is concerned, and none of them should ever surface as an error the
/// user could see.
Future<String?> readInstallReferrer() async {
  if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return null;
  try {
    return await _channel.invokeMethod<String>('getInstallReferrer');
  } on MissingPluginException {
    return null;
  } catch (error) {
    debugPrint('[referrer] could not read the install referrer: $error');
    return null;
  }
}

/// Splits a referrer payload into its parameters.
///
/// A free function rather than a method so the gate's matching rules can be tested without a
/// platform channel — which is most of what there is to get wrong here.
///
/// The string arrives already URL-decoded once by Play: the store link carries
/// `referrer=utm_source%3Dfacebook%26utm_medium%3Dpaid`, and what reaches us is
/// `utm_source=facebook&utm_medium=paid`. Values are decoded again because a campaign name may
/// legitimately contain an escaped space or `&`.
///
/// Keys are lowercased so `UTM_Source` and `utm_source` cannot become two different campaigns.
/// Anything unparseable yields an empty map, never a throw — a malformed referrer must fall
/// through to Circle360 rather than take the boot down with it.
Map<String, String> parseReferrer(String? raw) {
  if (raw == null || raw.trim().isEmpty) return const {};

  final result = <String, String>{};
  for (final pair in raw.split('&')) {
    if (pair.isEmpty) continue;
    final separator = pair.indexOf('=');
    // A bare flag with no `=` carries no value worth matching on, so it is skipped rather than
    // stored as an empty string that an allowlist might then match against.
    if (separator <= 0) continue;

    final key = pair.substring(0, separator).trim().toLowerCase();
    if (key.isEmpty) continue;

    final value = pair.substring(separator + 1);
    result[key] = _decode(value).trim();
  }
  return result;
}

/// `Uri.decodeComponent` refuses a stray `%` or a truncated escape. A campaign name is not worth
/// losing the referrer over, so a value that will not decode is kept exactly as it arrived.
String _decode(String value) {
  try {
    return Uri.decodeComponent(value);
  } catch (_) {
    return value;
  }
}
