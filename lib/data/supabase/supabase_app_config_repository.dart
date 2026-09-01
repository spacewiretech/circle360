import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../repositories/app_config_repository.dart';

/// Reads `app_config` from Supabase, with a disk cache in front of it.
///
/// The splash waits on this, so it must never hang on a bad network: a cached copy is served
/// immediately when it is fresh, a stale copy is served when the fetch fails, and
/// [defaultAppConfig] catches the very first launch offline.
class SupabaseAppConfigRepository implements AppConfigRepository {
  SupabaseAppConfigRepository(this._client, {this.ttl = const Duration(hours: 6)});

  final SupabaseClient _client;
  final Duration ttl;

  static const _cacheKey = 'loc360.app_config';
  static const _cacheAtKey = 'loc360.app_config_at';

  /// Only public rows are readable with the anon key; RLS enforces that server-side, so a
  /// private row simply will not appear here.
  static const _timeout = Duration(seconds: 8);

  @override
  Future<Map<String, String>> load() async {
    final prefs = await SharedPreferences.getInstance();
    final cached = _readCache(prefs);

    if (cached != null && _isFresh(prefs)) return cached;

    try {
      final rows = await _client
          .from('app_config')
          .select('key, value')
          .timeout(_timeout);

      final config = <String, String>{
        for (final row in rows as List<dynamic>)
          (row as Map<String, dynamic>)['key'] as String:
              row['value']?.toString() ?? '',
      };

      await prefs.setString(_cacheKey, jsonEncode(config));
      await prefs.setInt(_cacheAtKey, DateTime.now().millisecondsSinceEpoch);
      return {...defaultAppConfig, ...config};
    } catch (error) {
      debugPrint('app_config fetch failed, using ${cached == null ? 'defaults' : 'stale cache'}: $error');
      // Stale beats nothing, and nothing still beats blocking the splash.
      return cached ?? defaultAppConfig;
    }
  }

  bool _isFresh(SharedPreferences prefs) {
    final at = prefs.getInt(_cacheAtKey);
    if (at == null) return false;
    final age = DateTime.now()
        .difference(DateTime.fromMillisecondsSinceEpoch(at));
    return age < ttl;
  }

  Map<String, String>? _readCache(SharedPreferences prefs) {
    final raw = prefs.getString(_cacheKey);
    if (raw == null) return null;
    try {
      final decoded = jsonDecode(raw) as Map<String, dynamic>;
      return {
        ...defaultAppConfig,
        for (final entry in decoded.entries) entry.key: entry.value.toString(),
      };
    } catch (_) {
      return null;
    }
  }
}

/// Used until Supabase is configured, and by tests.
class FakeAppConfigRepository implements AppConfigRepository {
  const FakeAppConfigRepository([this.overrides = const {}]);

  final Map<String, String> overrides;

  @override
  Future<Map<String, String>> load() async =>
      {...defaultAppConfig, ...overrides};
}
