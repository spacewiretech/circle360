import 'package:flutter/foundation.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';

/// Values read from `.env` at startup.
///
/// Every getter tolerates a missing file: [load] swallows the failure and the getters fall back
/// to empty strings, which flips [isConfigured] to false and puts onboarding on the fake
/// repository. A misconfigured checkout must never crash the app on launch.
abstract final class Env {
  static bool _loaded = false;

  /// Real config, gitignored.
  static const _file = 'assets/env/app.env';

  /// Committed template. Loading it as a fallback means a checkout that never ran the copy
  /// step still boots — every value is blank, so the app lands on the fake repositories.
  static const _templateFile = 'assets/env/app.env.example';

  /// Prefix marking an entry as a fallback for a public `app_config` row.
  ///
  /// `APP_CONFIG_MAX_TRACKED_PEOPLE` here answers for `max_tracked_people` there. Stripping a
  /// prefix rather than listing the keys in Dart means a new public row needs a line in the env
  /// file and nothing else — see [parseAppConfig].
  static const _appConfigPrefix = 'APP_CONFIG_';

  /// Built once from [dotenv], and rebuilt by [load].
  static Map<String, String>? _appConfig;

  static Future<void> load() async {
    // A reload must not serve the previous file's rows.
    _appConfig = null;

    for (final file in [_file, _templateFile]) {
      try {
        await dotenv.load(fileName: file);
        _loaded = true;
        if (file == _templateFile) {
          debugPrint(
            'Env: $_file is missing, fell back to the template. '
            'Copy $_templateFile to $_file and fill it in to send real OTPs.',
          );
        }
        return;
      } catch (_) {
        continue;
      }
    }

    _loaded = false;
    debugPrint('Env: no env file could be read. Falling back to the in-memory repositories.');
  }

  static String _get(String key) => _loaded ? (dotenv.env[key] ?? '') : '';

  /// Fallback values for the public `app_config` rows, keyed exactly as the table keys them.
  ///
  /// These sit *below* Supabase in the ladder: a fetched or cached answer always wins, and this
  /// only decides what the app runs on when Supabase has never answered on this device. Above
  /// `defaultAppConfig` though, so a value can be corrected in a build without editing Dart.
  static Map<String, String> get appConfig =>
      _appConfig ??= _loaded ? parseAppConfig(dotenv.env) : const {};

  /// Keys that must never reach a device, mirroring the `app_config_secrets_stay_private` check
  /// in `20260907010000_mixpanel_token.sql`.
  ///
  /// The env file is bundled as a Flutter asset and is extractable from the APK, so a private row
  /// pasted here would be exactly as exposed as one marked public in the table. `mixpanel_token`
  /// is the same sanctioned exception the SQL constraint makes: it is write-only and ships in
  /// every client by design.
  static final _secretShaped =
      RegExp(r'(^fast2sms|_key$|_secret$|_token$|password|credential)');

  /// Turns the `APP_CONFIG_*` entries of [raw] into `app_config` keys.
  ///
  /// Blank values are skipped rather than kept, so a half-filled env file is harmless — an empty
  /// `APP_CONFIG_TRIAL_PRICE_LABEL=` must not blank out the `₹3` default behind it. The cost is
  /// that this file cannot *deliberately* blank a key; do that in the dashboard, which outranks
  /// this anyway.
  @visibleForTesting
  static Map<String, String> parseAppConfig(Map<String, String> raw) {
    final config = <String, String>{};

    for (final entry in raw.entries) {
      if (!entry.key.startsWith(_appConfigPrefix)) continue;

      final value = entry.value.trim();
      if (value.isEmpty) continue;

      final key = entry.key.substring(_appConfigPrefix.length).toLowerCase();
      if (key != 'mixpanel_token' && _secretShaped.hasMatch(key)) {
        debugPrint(
          'Env: refusing $_appConfigPrefix${key.toUpperCase()} — it looks like a secret, and '
          'everything in this file ships inside the binary. Keep it a private app_config row.',
        );
        continue;
      }

      config[key] = value;
    }

    return config;
  }

  /// Loads [values] as if they had been read from the env file.
  ///
  /// `isOptional` is what lets an empty map through, which is how a test resets the statics —
  /// [load] itself has no asset bundle to read in a unit test.
  @visibleForTesting
  static void loadFromMapForTest(Map<String, String> values) {
    dotenv.loadFromString(isOptional: true, mergeWith: values);
    _loaded = true;
    _appConfig = null;
  }

  static String get fast2smsApiKey => _get('FAST2SMS_API_KEY');

  /// The OTP Template ID from the Fast2SMS dashboard, required by `/dev/otp/send`.
  static String get fast2smsOtpId => _get('FAST2SMS_OTP_ID');

  static String get supabaseUrl => _get('SUPABASE_URL');

  /// Public by design — it ships in every client. Row-level security, not secrecy, is what
  /// protects the data behind it.
  static String get supabaseAnonKey => _get('SUPABASE_ANON_KEY');

  /// When true the app talks to Supabase, which proxies OTP through Edge Functions and keeps
  /// the Fast2SMS key off the device entirely.
  static bool get hasSupabase =>
      supabaseUrl.isNotEmpty && supabaseAnonKey.isNotEmpty;

  /// Where the native uploader posts each fix.
  ///
  /// Built here rather than on the native side because the native side has no access to the
  /// env file — Dart pushes the finished URL down with the session token.
  static String get ingestLocationUrl {
    if (supabaseUrl.isEmpty) return '';
    final base = supabaseUrl.endsWith('/')
        ? supabaseUrl.substring(0, supabaseUrl.length - 1)
        : supabaseUrl;
    return '$base/functions/v1/ingest-location';
  }

  /// Both halves are needed: a key with no template ID cannot send.
  static bool get isConfigured =>
      fast2smsApiKey.isNotEmpty && fast2smsOtpId.isNotEmpty;

  /// Explains, for the debug log, which half is missing.
  static String get configurationSummary {
    if (isConfigured) return 'Fast2SMS configured.';
    if (fast2smsApiKey.isEmpty && fast2smsOtpId.isEmpty) {
      return 'FAST2SMS_API_KEY and FAST2SMS_OTP_ID are both unset.';
    }
    if (fast2smsApiKey.isEmpty) return 'FAST2SMS_API_KEY is unset.';
    return 'FAST2SMS_OTP_ID is unset — create an OTP Template in the Fast2SMS dashboard.';
  }
}
