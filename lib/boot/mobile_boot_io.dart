import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../app/app.dart';
import '../app/env.dart';

export '../app/app.dart' show Loc360App;

/// Boots the phone app: environment, Supabase, then the widget tree.
///
/// Lives here rather than in `main()` so the web build never reaches the app tree — see
/// [mobile_boot.dart] for why that matters.
Future<void> bootMobileApp() async {
  await Env.load();

  if (Env.hasSupabase) {
    try {
      await Supabase.initialize(
        url: Env.supabaseUrl,
        // Same value as the legacy `anonKey`; that parameter is deprecated.
        publishableKey: Env.supabaseAnonKey,
        // Supabase Auth is unused — phone verification runs through Fast2SMS and the Edge
        // Functions issue their own session tokens.
        authOptions: const FlutterAuthClientOptions(autoRefreshToken: false),
      );
    } catch (error) {
      // A bad URL or an unreachable project must not stop the app from starting; the
      // repositories fall back on their own.
      debugPrint('Supabase init failed, continuing without it: $error');
    }
  }

  runApp(const ProviderScope(child: Loc360App()));
}
