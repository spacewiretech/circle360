import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../data/repositories/app_config_repository.dart';
import '../../data/supabase/supabase_app_config_repository.dart';
import 'install_referrer.dart';

/// Which of the two apps in this build a device runs.
///
/// One APK ships two products. Circle360 is what every install gets; SunioMax is shown only to
/// devices that arrived through a paid campaign link, identified by the Play install referrer.
/// This is resolved once in `bootMobileApp()` and decides the root widget, so it is the highest-
/// stakes branch in the app — and every uncertain path in it leans the same way, towards
/// Circle360. A user who should have seen SunioMax and sees Circle360 has a worse campaign; a
/// user who should have seen Circle360 and sees SunioMax has a broken app.
enum AppVariant {
  circle360,
  sunioMax;

  /// The stored and reported spelling. Also the value of the `app` super property on every
  /// analytics event, so it must stay stable — renaming it splits every funnel in Mixpanel.
  String get id => switch (this) {
    AppVariant.circle360 => 'circle360',
    AppVariant.sunioMax => 'suniomax',
  };

  bool get isSunioMax => this == AppVariant.sunioMax;

  /// What this app calls its subscription in Facebook's event catalogue — `fb_content_id` on
  /// `Purchase`, and `contentId` on `InitiatedCheckout`.
  ///
  /// Both apps report to the **same Facebook app**, and `FacebookAnalytics.registerSuper` is a
  /// no-op because Facebook's parameters are per-event with a fixed catalogue — so there is no
  /// super property carrying `app` the way Mixpanel has one. This is the only field that tells
  /// Facebook which of the two products a conversion came from. Without it both funnels arrive
  /// as one content id and nothing on the Facebook side can separate them: not an Events Manager
  /// breakdown, not a Custom Audience, not a value-based lookalike.
  ///
  /// Per-campaign attribution is unaffected either way — Facebook attributes a conversion to the
  /// ad that drove the install, so ROAS per campaign was always correct. What this buys is the
  /// account-level view.
  ///
  /// Circle360's spelling is unchanged on purpose: it is already in live campaigns, and renaming
  /// a content id mid-flight is how an existing audience quietly stops matching.
  String get fbContentId => switch (this) {
    AppVariant.circle360 => 'circle360_subscription',
    AppVariant.sunioMax => 'suniomax_subscription',
  };

  static AppVariant? _parse(String? raw) => switch (raw) {
    'circle360' => AppVariant.circle360,
    'suniomax' => AppVariant.sunioMax,
    _ => null,
  };

  /// The raw referrer, kept for the life of the install.
  ///
  /// The *string* is stored rather than the verdict, so that the matching rule stays a server-side
  /// decision: a campaign the dashboard has not been told about yet is re-evaluated on the next
  /// launch instead of being frozen into an answer the day the app was first opened.
  static const _referrerKey = 'loc360.install_referrer';

  /// The pinned verdict, written once a user has committed to one of the two apps.
  ///
  /// After this exists the rule is never consulted again. Without it, widening or narrowing the
  /// allowlist would move a signed-in user — mid-funnel, or mid-subscription — into an app that
  /// is not the one they paid in.
  static const _variantKey = 'loc360.app_variant';

  /// Set the first time [resolve] runs on a device, whatever it concludes.
  ///
  /// Distinguishes "this install has never been judged" from "it was judged and Play had nothing
  /// to say". Without it, a fresh campaign install whose first Play call times out would be
  /// mistaken on its second launch for an upgrade — see [_installIdKey] — and pinned to
  /// Circle360 for good.
  static const _gateSeenKey = 'loc360.gate_seen';

  /// Minted by `AnalyticsContext.collect()` on the first launch that reaches analytics.
  ///
  /// Read here as an age check, and it is the most important line in this file. **Circle360 is
  /// itself bought through Facebook Ads**, so its own installs carry `utm_source=facebook` — the
  /// same referrer a SunioMax campaign carries. Judged on the referrer alone, every existing
  /// Circle360 user who arrived through an ad would be moved into SunioMax by the update that
  /// introduced this gate, losing the app they are paying for.
  ///
  /// [resolve] runs before `_startAnalytics`, so this key is present only when some *earlier*
  /// launch wrote it. Present, with no verdict yet recorded, means the device was running
  /// Circle360 before the gate existed, and its referrer describes how it found Circle360.
  static const _installIdKey = 'loc360.analytics_install_id';

  /// How long to wait for Play on the one launch that has to ask it.
  ///
  /// Short because this sits in front of `runApp`, behind nothing but the native launch theme.
  /// A timeout is not a verdict: nothing is persisted, so the next launch simply asks again.
  static const _referrerTimeout = Duration(seconds: 3);

  /// Runs SunioMax regardless of referrer or config — `--dart-define=SUNIOMAX_FORCE=true`.
  ///
  /// `adb install` and `flutter run` carry no Play referrer, and Play will not attribute one
  /// after the fact, so without this the SunioMax screens are simply unreachable on a development
  /// device. This is for working on those screens; it deliberately says nothing about whether the
  /// gate works, which is what `test/app_variant_test.dart` is for.
  static const _forceSunioMax = bool.fromEnvironment('SUNIOMAX_FORCE');

  /// Stands in for the Play referrer — `--dart-define=SUNIOMAX_REFERRER='utm_source=facebook&…'`.
  ///
  /// Unlike [_forceSunioMax] this exercises the **real** rule: the string is stored exactly as
  /// Play would have handed it over, and the `app_config` allowlist then judges it. Use it to
  /// check a live campaign's referrer actually matches before spending money on it.
  static const _debugReferrer = String.fromEnvironment('SUNIOMAX_REFERRER');

  /// Both overrides are compile-time constants behind [kDebugMode], which is `false` in release —
  /// so the branches below are tree-shaken out of a store build and no `--dart-define` can talk a
  /// shipped app into the wrong product.
  static bool get _debugOverridesAllowed => kDebugMode;

  /// The variant this device runs.
  ///
  /// Costs one `SharedPreferences` read on every launch after the first. The Play round trip
  /// happens once per install, and never at all on iOS, on the web, or in a test — there is no
  /// channel registered there, [readInstallReferrer] returns null, and null means Circle360.
  ///
  /// The parameters exist for tests. Production calls this with no arguments.
  static Future<AppVariant> resolve({
    SharedPreferences? preferences,
    Future<String?> Function()? readReferrer,
    Map<String, String>? config,
  }) async {
    try {
      // Before everything, including a pinned verdict: the point of the override is to make a
      // screen reachable, and a pin left behind by an earlier run would otherwise defeat it.
      if (_debugOverridesAllowed && _forceSunioMax) {
        return _decided(AppVariant.sunioMax, 'forced by SUNIOMAX_FORCE');
      }

      final prefs = preferences ?? await SharedPreferences.getInstance();

      if (_debugOverridesAllowed && _debugReferrer.isNotEmpty) {
        // Seeded exactly as Play would have handed it over, then judged by the real rule below.
        // The pin is cleared so a re-run with a different referrer is actually re-evaluated.
        await prefs.setString(_referrerKey, _debugReferrer);
        await prefs.setBool(_gateSeenKey, true);
        await prefs.remove(_variantKey);
      }

      final pinned = _parse(prefs.getString(_variantKey));
      if (pinned != null) {
        return _decided(
          pinned,
          'pinned by an earlier launch; the rule is no longer consulted',
        );
      }

      // The upgrade guard. Runs once per device, before the referrer is ever consulted.
      if (!(prefs.getBool(_gateSeenKey) ?? false)) {
        await prefs.setBool(_gateSeenKey, true);

        if (prefs.containsKey(_installIdKey)) {
          // This app has launched here before, which means before this gate existed — so the
          // stored referrer is how the device found *Circle360*. Pinned rather than merely
          // returned, because the answer can never legitimately change afterwards.
          await prefs.setString(_variantKey, AppVariant.circle360.id);
          return _decided(
            AppVariant.circle360,
            'this install predates the gate, so its referrer describes how it found Circle360',
          );
        }
      }

      var raw = prefs.getString(_referrerKey);
      if (raw == null) {
        // Re-wrapped rather than timed out directly: a caller whose closure happens to be typed
        // `Future<String>` — which any `() async => 'literal'` is — makes `onTimeout` fail its
        // runtime type check, and the original future is then abandoned mid-flight with whatever
        // it was about to throw. `Future<String?>.value` pins both types to the nullable one.
        raw = await Future<String?>.value(
          (readReferrer ?? readInstallReferrer)(),
        ).timeout(_referrerTimeout, onTimeout: () => null);
        // Only a real answer is kept. An organic install answers
        // `utm_source=google-play&utm_medium=organic`, which is an answer and is stored as one;
        // a timeout or a device with no Play Store answers nothing, and storing that would turn
        // one slow launch into a permanent verdict.
        if (raw != null) await prefs.setString(_referrerKey, raw);
      }
      if (raw == null) {
        return _decided(
          AppVariant.circle360,
          'no install referrer — Play had no answer, or there is no Play Store here. '
          'On a development device use --dart-define=SUNIOMAX_FORCE=true',
        );
      }

      // Deliberately the cache or the bundled fallbacks, never a fetch: this runs before the
      // first frame, and `bootMobileApp` already reads the config the same way for the same
      // reason. The consequence is that a device's *first* launch is judged by the rule shipped
      // in `assets/env/app.env`; dashboard changes reach it from the second launch onward.
      final rules =
          config ??
          await SupabaseAppConfigRepository.readCachedConfig() ??
          appConfigFallbacks();

      final referrer = parseReferrer(raw);
      if (matchesSunioMax(referrer, rules)) {
        return _decided(AppVariant.sunioMax, 'referrer matched the rule');
      }
      return _decided(
        AppVariant.circle360,
        'referrer did not match the rule — ${_whyRefused(referrer, rules)}',
      );
    } catch (error) {
      // Nothing about choosing an app is worth failing a boot over.
      debugPrint('[variant] could not resolve the app variant: $error');
      return AppVariant.circle360;
    }
  }

  /// Says which app won and why, in debug only.
  ///
  /// This is the highest-stakes branch in the app and it used to be entirely silent, which made
  /// "I ran the command and got the other app" impossible to diagnose without a debugger. Every
  /// `return` in [resolve] goes through here so no path can be added later without a reason.
  static AppVariant _decided(AppVariant variant, String why) {
    if (kDebugMode) debugPrint('[variant] ${variant.id} — $why');
    return variant;
  }

  /// Which clause of the rule refused this referrer.
  ///
  /// Named rather than described generically because there are three ways to be refused and they
  /// have completely different fixes: a config row to flip, an allowlist to widen, or a referrer
  /// that genuinely is not from the campaign.
  static String _whyRefused(
    Map<String, String> referrer,
    Map<String, String> config,
  ) {
    if (!config.configFlag(sunioMaxEnabledKey)) {
      return 'suniomax_enabled is false. Set APP_CONFIG_SUNIOMAX_ENABLED=true in '
          'assets/env/app.env, or flip the app_config row';
    }

    final sources = config.configString(sunioMaxUtmSourcesKey);
    if (_allowlist(sources).isEmpty) {
      return 'suniomax_utm_sources is empty, which matches nothing';
    }

    final source = referrer['utm_source'];
    if (source == null) return 'the referrer carries no utm_source';
    if (!_allowlist(sources).contains(source.toLowerCase())) {
      return 'utm_source=$source is not in the allowlist ($sources)';
    }

    final campaign = referrer['utm_campaign'];
    return 'utm_campaign=$campaign is not in '
        '${config.configString(sunioMaxUtmCampaignsKey)}';
  }

  /// Whether [referrer] satisfies the SunioMax rule in [config].
  ///
  /// Pure, so the whole of the gate's behaviour is testable without a channel, a store or a
  /// device. Every ambiguous case answers false.
  static bool matchesSunioMax(
    Map<String, String> referrer,
    Map<String, String> config,
  ) {
    if (!config.configFlag(sunioMaxEnabledKey)) return false;

    // An empty allowlist matches nothing rather than everything. The opposite reading would make
    // a blanked-out config row hand SunioMax to every organic install in the store.
    final sources = _allowlist(config.configString(sunioMaxUtmSourcesKey));
    if (sources.isEmpty) return false;

    final source = referrer['utm_source']?.toLowerCase();
    if (source == null || !sources.contains(source)) return false;

    // Campaigns are the optional second filter: blank means any campaign from an allowed source,
    // which is the common case while a single channel is being tested.
    final campaigns = _allowlist(config.configString(sunioMaxUtmCampaignsKey));
    if (campaigns.isEmpty) return true;

    final campaign = referrer['utm_campaign']?.toLowerCase();
    return campaign != null && campaigns.contains(campaign);
  }

  /// Fixes [variant] for this install, so no later rule change can move the user.
  ///
  /// Called the moment a user commits to an app — on a verified OTP. Before that point a device
  /// is only browsing and may safely be re-judged.
  static Future<void> pin(
    AppVariant variant, {
    SharedPreferences? preferences,
  }) async {
    try {
      final prefs = preferences ?? await SharedPreferences.getInstance();
      await prefs.setString(_variantKey, variant.id);
    } catch (error) {
      // A failed pin costs a re-evaluation next launch, which almost always lands the same way.
      debugPrint('[variant] could not pin $variant: $error');
    }
  }

  /// Seeds the stored referrer, standing in for a Play install.
  ///
  /// The only way to reach the SunioMax flow on a development device: a debug build is installed
  /// by adb, adb installs carry no referrer, and Play will not attribute one after the fact.
  @visibleForTesting
  static Future<void> seedReferrer(
    String raw, {
    SharedPreferences? preferences,
  }) async {
    final prefs = preferences ?? await SharedPreferences.getInstance();
    await prefs.setString(_referrerKey, raw);
    await prefs.remove(_variantKey);
  }

  /// Forgets both the stored referrer and any pinned verdict.
  @visibleForTesting
  static Future<void> clearStoredVariant({
    SharedPreferences? preferences,
  }) async {
    final prefs = preferences ?? await SharedPreferences.getInstance();
    await prefs.remove(_referrerKey);
    await prefs.remove(_variantKey);
  }

  /// A comma-separated config value as a set of lowercase entries, blanks dropped.
  static Set<String> _allowlist(String raw) => raw
      .split(',')
      .map((value) => value.trim().toLowerCase())
      .where((value) => value.isNotEmpty)
      .toSet();
}
