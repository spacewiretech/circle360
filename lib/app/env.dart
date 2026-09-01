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

  static Future<void> load() async {
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
