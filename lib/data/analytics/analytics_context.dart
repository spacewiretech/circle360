import 'package:flutter/foundation.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'analytics.dart';
import 'analytics_events.dart';

/// Everything the app knows about itself and the device, gathered once and attached to every
/// event as a super property.
///
/// **What is deliberately not here.** Brand, model, manufacturer, carrier, OS version, screen
/// size and DPI, NFC, Bluetooth, Wi-Fi, app version, build number, library version, device id,
/// and the city/region/country Mixpanel derives from the request IP are all attached by the
/// native Mixpanel SDK and its ingestion API without being asked. Collecting them again here
/// would not add a field — it would add a *second* field under a non-standard name, invisible to
/// every built-in Mixpanel report, and the two would drift the first time a device reported one
/// and not the other.
///
/// So this fills the gaps the SDK leaves: the things that are properties of *this* app rather
/// than of the handset.
class AnalyticsContext {
  AnalyticsContext({this.packageInfo});

  /// Injectable so a test can run without the platform channel.
  final PackageInfo? packageInfo;

  static const _lastVersionKey = 'loc360.analytics_last_version';
  static const _installIdKey = 'loc360.analytics_install_id';
  static const _installedAtKey = 'loc360.analytics_installed_at';

  /// Resolved once at boot and reused. Also what the session tracker reads for `is_new_user`.
  Map<String, Object?> properties = const {};

  bool get isNewUser => properties[P.isNewUser] == true;

  /// Gathers the context and registers it, so that from here on there is exactly one place that
  /// decides what rides along with an event.
  ///
  /// Never throws. A device where `SharedPreferences` or the package-info channel will not open
  /// still sends events, just with fewer properties on them.
  Future<void> collect(Analytics analytics) async {
    final resolved = <String, Object?>{};

    // The language the app is actually rendering in. Not the same question as the device's
    // country, which Mixpanel already answers from the request IP — a Hindi speaker in Lucknow
    // and an English speaker in Lucknow are the same row without this, and they are not the
    // same user.
    final locale = PlatformDispatcher.instance.locale;
    resolved[P.appLanguage] = locale.languageCode;
    resolved[P.appLocale] = locale.toLanguageTag();

    // India is UTC+5:30 and the backend stores UTC, so every timestamp comparison anyone makes
    // in Mixpanel needs this to be reconstructible.
    resolved[P.utcOffsetMinutes] = DateTime.now().timeZoneOffset.inMinutes;

    // debug and profile traffic must be excludable from every funnel with one filter.
    resolved[P.buildMode] = kReleaseMode
        ? 'release'
        : kProfileMode
            ? 'profile'
            : 'debug';

    try {
      final info = packageInfo ?? await PackageInfo.fromPlatform();
      final version = '${info.version}+${info.buildNumber}';
      resolved[P.appVersion] = info.version;
      resolved[P.buildNumber] = info.buildNumber;

      final prefs = await SharedPreferences.getInstance();
      final previous = prefs.getString(_lastVersionKey);

      // The one thing package_info is actually here for. A first launch and an upgrade both
      // look identical to the SDK, and they are the two most different sessions a user has.
      resolved[P.isNewUser] = previous == null;
      if (previous != null && previous != version) {
        resolved[P.previousVersion] = previous.split('+').first;
      }
      await prefs.setString(_lastVersionKey, version);

      resolved[P.installId] = await _installId(prefs);
      resolved[P.daysSinceInstall] = await _daysSinceInstall(prefs);
    } catch (error) {
      debugPrint('[analytics] could not read app info: $error');
    }

    resolved.removeWhere((_, value) => value == null);
    properties = Map.unmodifiable(resolved);
    analytics.registerSuper(properties);
  }

  /// A stable id for this installation, minted on first launch.
  ///
  /// Distinct from Mixpanel's `$device_id`, which is reset by `reset()` on sign-out. This one
  /// survives that, which is what makes "two accounts on one handset" answerable at all.
  Future<String> _installId(SharedPreferences prefs) async {
    final existing = prefs.getString(_installIdKey);
    if (existing != null && existing.isNotEmpty) return existing;

    final minted = '${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}'
        '-${identityHashCode(prefs).toRadixString(36)}';
    await prefs.setString(_installIdKey, minted);
    return minted;
  }

  Future<int> _daysSinceInstall(SharedPreferences prefs) async {
    final stored = prefs.getInt(_installedAtKey);
    if (stored == null) {
      await prefs.setInt(_installedAtKey, DateTime.now().millisecondsSinceEpoch);
      return 0;
    }
    return DateTime.now()
        .difference(DateTime.fromMillisecondsSinceEpoch(stored))
        .inDays;
  }
}

/// The one context, resolved in `bootMobileApp`.
final analyticsContext = AnalyticsContext();
