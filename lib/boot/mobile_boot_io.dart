import 'dart:ui' show PlatformDispatcher;

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_crashlytics/firebase_crashlytics.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
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
import '../data/analytics/facebook_analytics.dart';
import '../data/analytics/mixpanel_analytics.dart';
import '../data/providers.dart';
import '../data/repositories/app_config_repository.dart';
import '../data/supabase/supabase_app_config_repository.dart';
import '../firebase_options.dart';

export '../app/app.dart' show Loc360App;

/// Handles a push that arrives while the app is backgrounded or not running.
///
/// Top-level and `vm:entry-point` because Flutter spins up a *separate* isolate for it: there is
/// no widget tree, no `ProviderScope` and none of the state this file sets up, so anything it
/// needs it has to build for itself. Registering it is what stops FCM warning that a background
/// message was dropped; it does nothing else yet, deliberately — see `PushMessaging`.
@pragma('vm:entry-point')
Future<void> _onBackgroundMessage(RemoteMessage message) async {
  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
  debugPrint('[push] background message ${message.messageId}');
}

/// Boots the phone app: Firebase, environment, Supabase, analytics, then the widget tree.
///
/// Lives here rather than in `main()` so the web build never reaches the app tree — see
/// [mobile_boot.dart] for why that matters.
Future<void> bootMobileApp() async {
  // First, because Crashlytics cannot report anything that happens before it and the analytics
  // startup below is the most interesting part of the boot. Non-fatal on the same principle as
  // Supabase: a project misconfiguration must not be the reason the app fails to open.
  try {
    await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
    FirebaseMessaging.onBackgroundMessage(_onBackgroundMessage);
  } catch (error) {
    debugPrint('Firebase init failed, continuing without it: $error');
  }

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
/// Never throws and never blocks on the network. The Mixpanel token and the Facebook switch both
/// live in the `app_config` table, so the most this can do at boot is read the cache that
/// [SupabaseAppConfigRepository] already keeps on disk; a first launch finds nothing there and
/// both sinks are started later by [analyticsBootstrapProvider], with the launch events buffered
/// in the meantime.
Future<Analytics> _startAnalytics() async {
  final mixpanel = MixpanelAnalytics();
  final facebook = FacebookAnalytics();

  // Two sinks with very different appetites behind one interface: Mixpanel answers product
  // questions and takes everything, Facebook trains an ad optimiser and takes four conversions.
  // The fan-out is what keeps that a property of the sinks rather than of every call site.
  final analytics = MultiAnalytics([mixpanel, facebook]);

  // Installed before anything is tracked, and before the token is known, because the buffer is
  // what makes an unstarted sink useful rather than lossy.
  installAnalytics(analytics);
  mixpanel.context = () => {
        ...analyticsObserver.contextProperties(),
        ...analyticsSession.contextProperties(),
      };
  analytics.registerSuper({P.backendMode: backendMode});

  // The single place device, locale, version and install context is gathered. Awaited before the
  // token so that even the very first buffered event — `App Launched` — already carries it.
  await analyticsContext.collect(analytics);

  try {
    // The env fallbacks stand in when there is no cache, which is the first launch on a device.
    // With APP_CONFIG_MIXPANEL_TOKEN set that is the difference between starting Mixpanel here
    // and buffering every launch event until the first fetch returns.
    final config =
        await SupabaseAppConfigRepository.readCachedConfig() ?? appConfigFallbacks();
    await mixpanel.start(config[mixpanelTokenKey]);
    await startFacebook(facebook, config);
  } catch (error) {
    debugPrint('[analytics] could not read the cached config: $error');
  }

  _reportUncaughtErrors();
  await analyticsSession.attach(screensViewed: () => analyticsObserver.screensViewed);

  return analytics;
}

/// Sends crashes to Crashlytics, and to Mixpanel as events.
///
/// Both, not one: Crashlytics gets the full stack, the device state and the native crashes that
/// Dart never sees, while the Mixpanel `App Crashed` event stays because it is what the existing
/// reports and funnels are built on — it sits in the same event stream as everything else the
/// user did beforehand, which is the one thing a crash reporter cannot show you.
///
/// It deliberately chains to the previous handler rather than replacing it, so the red screen
/// and the console output still happen in debug.
void _reportUncaughtErrors() {
  final previous = FlutterError.onError;
  FlutterError.onError = (details) {
    _recordCrash(() => FirebaseCrashlytics.instance.recordFlutterError(details));
    analytics.track(Ev.appCrashed, {
      P.error: details.exceptionAsString(),
      P.stackHead: _stackHead(details.stack),
      P.fatal: false,
    });
    previous?.call(details);
  };

  PlatformDispatcher.instance.onError = (error, stack) {
    _recordCrash(
      () => FirebaseCrashlytics.instance.recordError(error, stack, fatal: true),
    );
    analytics.track(Ev.appCrashed, {
      P.error: error.toString(),
      P.stackHead: _stackHead(stack),
      P.fatal: true,
    });
    // False: this handler exists to observe, not to swallow. Returning true would suppress the
    // default reporting, and the red screen with it.
    return false;
  };
}

/// Runs a Crashlytics call, swallowing anything it throws.
///
/// This is inside the two error handlers themselves. If `Firebase.initializeApp` failed at boot
/// then `FirebaseCrashlytics.instance` throws `[core/no-app]`, and an exception thrown *from*
/// `FlutterError.onError` is not caught by anything — it would turn every reportable error into
/// a second, worse one and lose the Mixpanel event that follows it.
///
/// Both halves are needed: the `try` catches the instance getter, which throws synchronously
/// before there is any future to fail, and `catchError` catches the recording itself, which
/// fails later and would otherwise surface as an unhandled async error.
void _recordCrash(Future<void> Function() record) {
  try {
    record().catchError((Object error) {
      debugPrint('[crashlytics] could not record: $error');
    });
  } catch (error) {
    debugPrint('[crashlytics] could not record: $error');
  }
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
