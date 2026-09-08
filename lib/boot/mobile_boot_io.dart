import 'dart:ui' show PlatformDispatcher;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../app/analytics_observer.dart';
import '../app/app.dart';
import '../app/env.dart';
import '../data/analytics/analytics.dart';
import '../data/analytics/analytics_context.dart';
import '../data/analytics/analytics_events.dart';
import '../data/analytics/analytics_session.dart';
import '../data/analytics/mixpanel_analytics.dart';
import '../data/providers.dart';
import '../data/repositories/app_config_repository.dart';
import '../data/supabase/supabase_app_config_repository.dart';

export '../app/app.dart' show Loc360App;

/// Boots the phone app: environment, Supabase, analytics, then the widget tree.
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

  final analytics = await _startAnalytics();

  runApp(
    ProviderScope(
      // The same instance the global holder has, so the router observer, the shared widgets and
      // the ViewModels can never end up talking to two different sinks.
      overrides: [analyticsProvider.overrideWithValue(analytics)],
      child: const Loc360App(),
    ),
  );
}

/// Brings analytics up as far as it can get before the first frame.
///
/// Never throws and never blocks on the network. The token lives in the `app_config` table, so
/// the most this can do at boot is read the cache that [SupabaseAppConfigRepository] already
/// keeps on disk; a first launch finds nothing there and Mixpanel is started later by
/// [analyticsBootstrapProvider], with the launch events buffered in the meantime.
Future<Analytics> _startAnalytics() async {
  final analytics = MixpanelAnalytics();

  // Installed before anything is tracked, and before the token is known, because the buffer is
  // what makes an unstarted sink useful rather than lossy.
  installAnalytics(analytics);
  analytics.context = () => {
        ...analyticsObserver.contextProperties(),
        ...analyticsSession.contextProperties(),
      };
  analytics.registerSuper({P.backendMode: backendMode});

  // The single place device, locale, version and install context is gathered. Awaited before the
  // token so that even the very first buffered event — `App Launched` — already carries it.
  await analyticsContext.collect(analytics);

  try {
    final cached = await SupabaseAppConfigRepository.readCachedConfig();
    await analytics.start(cached?[mixpanelTokenKey]);
  } catch (error) {
    debugPrint('[analytics] could not read the cached token: $error');
  }

  _reportUncaughtErrors();
  await analyticsSession.attach(screensViewed: () => analyticsObserver.screensViewed);

  return analytics;
}

/// Sends crashes to Mixpanel as events.
///
/// There is no crash reporter in this app at all, so this is the only thing that will ever notice
/// a framework exception in the field. It deliberately chains to the previous handler rather than
/// replacing it, so the red screen and the console output still happen in debug.
void _reportUncaughtErrors() {
  final previous = FlutterError.onError;
  FlutterError.onError = (details) {
    analytics.track(Ev.appCrashed, {
      P.error: details.exceptionAsString(),
      P.stackHead: _stackHead(details.stack),
      P.fatal: false,
    });
    previous?.call(details);
  };

  PlatformDispatcher.instance.onError = (error, stack) {
    analytics.track(Ev.appCrashed, {
      P.error: error.toString(),
      P.stackHead: _stackHead(stack),
      P.fatal: true,
    });
    // False: this handler exists to observe, not to swallow. Returning true would suppress the
    // default reporting that is currently the only other signal anyone has.
    return false;
  };
}

/// The first few frames of a stack trace.
///
/// Whole traces are long, mostly framework, and Mixpanel charges by the property value it stores.
/// Three frames is enough to tell two crashes apart in the events list.
String? _stackHead(StackTrace? stack) {
  if (stack == null) return null;
  final lines = stack.toString().split('\n').where((l) => l.trim().isNotEmpty);
  return lines.take(3).join(' | ');
}
