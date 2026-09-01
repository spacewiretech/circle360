import 'dart:convert';

import 'package:flutter/foundation.dart';

/// A UPI app installed on this device, as reported by the Cashfree SDK.
///
/// The SDK answers `getupiapps` with a slightly different map per platform, so the parsing
/// lives here and only here:
///
/// - Android — `CFUPIApp.toMap()` gives `{id, base64Icon, displayName}`, where `id` is the
///   **package name** (`com.google.android.apps.nbu.paisa.user`).
/// - iOS — the plugin builds `{id, base64Icon, icon, displayName}`, where `id` is the app's
///   **URL scheme** (`tez`). It also drops CRED before we ever see it.
///
/// [id] is therefore **opaque**. Never parse it, never compare it against a hardcoded package
/// name or scheme — it exists to be handed straight back to the SDK, and a build that assumed
/// one platform's shape would silently show an empty picker on the other.
@immutable
class UpiApp {
  const UpiApp({required this.id, required this.displayName, this.icon});

  final String id;
  final String displayName;

  /// Decoded PNG bytes, or null when the SDK gave us nothing usable.
  ///
  /// Decoded once, at parse time. Doing it in `build()` would run a base64 decode on every
  /// frame of the bottom sheet's scroll.
  final Uint8List? icon;

  /// Parses one entry from the method channel, or null if it cannot be used.
  ///
  /// Everything here is defensive on purpose: this is data crossing a platform channel from
  /// two different native implementations, and a single malformed entry must cost at most that
  /// one app — never the whole picker, and never an exception on the paywall.
  static UpiApp? fromChannel(Object? raw) {
    if (raw is! Map) return null;

    final id = raw['id'];
    // Without an id there is nothing to launch, so the entry is worthless.
    if (id is! String || id.trim().isEmpty) return null;

    final name = raw['displayName'];
    final displayName = name is String && name.trim().isNotEmpty ? name.trim() : id;

    return UpiApp(
      id: id.trim(),
      displayName: displayName,
      icon: _decodeIcon(raw['base64Icon'] ?? raw['icon']),
    );
  }

  /// A missing or corrupt icon costs the app its logo, not its place in the list.
  static Uint8List? _decodeIcon(Object? raw) {
    if (raw is! String) return null;

    // Strip a `data:image/png;base64,` prefix if one is present, and drop the whitespace and
    // newlines that survive some encoders.
    var cleaned = raw.trim();
    final comma = cleaned.indexOf(',');
    if (cleaned.startsWith('data:') && comma != -1) {
      cleaned = cleaned.substring(comma + 1);
    }
    cleaned = cleaned.replaceAll(RegExp(r'\s'), '');
    if (cleaned.isEmpty) return null;

    try {
      // normalize() repairs the missing '=' padding that some encoders omit, which is the most
      // common reason a perfectly good icon fails to decode.
      return base64Decode(base64.normalize(cleaned));
    } on FormatException {
      return null;
    }
  }

  /// Parses the whole list, dropping entries that cannot be used.
  static List<UpiApp> listFrom(Object? raw) {
    if (raw is! List) return const [];
    return raw
        .map(UpiApp.fromChannel)
        .whereType<UpiApp>()
        .toList(growable: false);
  }

  @override
  bool operator ==(Object other) => other is UpiApp && other.id == id;

  @override
  int get hashCode => id.hashCode;
}
