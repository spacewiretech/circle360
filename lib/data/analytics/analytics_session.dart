import 'dart:math';

import 'package:flutter/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'analytics.dart';
import 'analytics_context.dart';
import 'analytics_events.dart';

/// Sessions, app lifecycle, and the round trip out to a UPI app.
///
/// The app has five `WidgetsBindingObserver`s already, and every one of them only listens for
/// `resumed` — nothing anywhere reacts to the app being backgrounded. That gap is why "the user
/// closed the app on the paywall" is currently unanswerable, and closing it is most of what this
/// class is for.
///
/// The other part is the payment round trip. A UPI mandate is authorised in a different app
/// entirely, so the most important thirty seconds of the funnel happen while this process is in
/// the background. Bracketing that with [UPI App Opened] and [UPI App Returned] is the only way
/// to tell "opened Google Pay and gave up" apart from "never got there at all".
class AnalyticsSession {
  AnalyticsSession({this.idleTimeout = const Duration(minutes: 30)});

  /// A gap longer than this makes the next foreground a new session. Thirty minutes is the
  /// industry-standard default and matches what Mixpanel's own session reports assume.
  final Duration idleTimeout;

  static const _sessionIdKey = 'loc360.analytics_session_id';
  static const _lastSeenKey = 'loc360.analytics_last_seen';
  static const _launchedBeforeKey = 'loc360.analytics_launched_before';

  AppLifecycleListener? _listener;
  SharedPreferences? _prefs;

  String _sessionId = '';
  DateTime _sessionStartedAt = DateTime.now();
  DateTime? _backgroundedAt;

  /// Set while a UPI app is expected to take over the foreground. Holds the app id so the return
  /// event can name it, because by the time control comes back the paywall may have been rebuilt.
  String? _awaitingUpiApp;
  DateTime? _upiHandoffAt;

  /// How long the user has been on the current screen is the observer's business; this is how
  /// long the *session* has run.
  int get _sessionSeconds => DateTime.now().difference(_sessionStartedAt).inSeconds;

  /// Merged into every event alongside the navigator observer's properties.
  Map<String, Object?> contextProperties() =>
      _sessionId.isEmpty ? const {} : {P.sessionId: _sessionId};

  /// Resolves the session, emits `App Launched`, and starts listening for lifecycle changes.
  ///
  /// Failures are swallowed whole: a device where `SharedPreferences` will not open still gets a
  /// working app, just with a session id that does not survive a restart.
  Future<void> attach({int Function()? screensViewed}) async {
    _screensViewed = screensViewed;

    try {
      _prefs = await SharedPreferences.getInstance();
    } catch (error) {
      debugPrint('[analytics] session storage unavailable: $error');
    }

    final lastSeen = _readLastSeen();
    // Two sources, deliberately: the context knows whether a version was ever recorded, and this
    // flag knows whether the session tracker has run. They disagree only for an install that
    // predates analytics, where the context is the one to trust.
    final firstLaunch = analyticsContext.isNewUser ||
        !(_prefs?.getBool(_launchedBeforeKey) ?? false);
    _prefs?.setBool(_launchedBeforeKey, true);

    _resumeOrStartSession(lastSeen);

    analytics.track(Ev.appLaunched, {
      P.isFirstLaunch: firstLaunch,
      P.coldStart: true,
      if (lastSeen != null)
        P.secondsSinceLastOpen: DateTime.now().difference(lastSeen).inSeconds,
    });

    _listener = AppLifecycleListener(
      onResume: _onResume,
      // `onPause` is the last state Android reliably delivers before a process can be killed, so
      // it — not `onDetach` — is where the flush has to happen.
      onPause: _onPause,
      onDetach: _onDetach,
    );
  }

  int Function()? _screensViewed;

  void dispose() {
    _listener?.dispose();
    _listener = null;
  }

  // --- Sessions ------------------------------------------------------------

  void _resumeOrStartSession(DateTime? lastSeen) {
    final stored = _prefs?.getString(_sessionIdKey);
    final fresh = lastSeen != null &&
        DateTime.now().difference(lastSeen) < idleTimeout &&
        stored != null &&
        stored.isNotEmpty;

    if (fresh) {
      // Same session continuing across a process death — a user who was killed out of the UPI
      // app and came straight back has not started a new visit, and counting it as one would
      // split every payment funnel in half at exactly the wrong step.
      _sessionId = stored;
      _sessionStartedAt = lastSeen;
      analytics.registerSuper({P.sessionId: _sessionId});
      return;
    }

    _startSession();
  }

  void _startSession() {
    _sessionId = _mintId();
    _sessionStartedAt = DateTime.now();
    _prefs?.setString(_sessionIdKey, _sessionId);
    analytics.registerSuper({P.sessionId: _sessionId});
    analytics.track(Ev.sessionStarted);
  }

  void _endSession() {
    if (_sessionId.isEmpty) return;
    analytics.track(Ev.sessionEnded, {
      P.durationSeconds: _sessionSeconds,
      P.screensViewed: _screensViewed?.call(),
    });
  }

  static String _mintId() {
    final random = Random();
    return '${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}'
        '-${random.nextInt(1 << 32).toRadixString(36)}';
  }

  DateTime? _readLastSeen() {
    final raw = _prefs?.getInt(_lastSeenKey);
    if (raw == null) return null;
    return DateTime.fromMillisecondsSinceEpoch(raw);
  }

  void _touch() => _prefs?.setInt(_lastSeenKey, DateTime.now().millisecondsSinceEpoch);

  // --- Lifecycle -----------------------------------------------------------

  void _onResume() {
    final away = _backgroundedAt;
    _backgroundedAt = null;

    final gap = away == null ? Duration.zero : DateTime.now().difference(away);
    if (gap >= idleTimeout) {
      _endSession();
      _startSession();
    }

    analytics.track(Ev.appForegrounded, {
      P.secondsBackgrounded: gap.inSeconds,
    });

    _reportUpiReturn(gap);
  }

  void _onPause() {
    _backgroundedAt = DateTime.now();
    _touch();

    // Fired before the backgrounded event so the pair reads in order in the live view: the app
    // did not simply go away, it handed off to a named UPI app.
    final upiApp = _awaitingUpiApp;
    if (upiApp != null && _upiHandoffAt == null) {
      _upiHandoffAt = DateTime.now();
      analytics.track(Ev.upiAppOpened, {P.appId: upiApp});
    }

    analytics.track(Ev.appBackgrounded, {
      P.sessionSeconds: _sessionSeconds,
    });

    // The process may not exist a second from now. Everything queued goes out here or not at all.
    analytics.flush();
  }

  void _onDetach() {
    // Best effort only — Android routinely kills the process without ever delivering this, which
    // is exactly why `onPause` carries the flush rather than relying on it.
    analytics.track(Ev.appTerminated, {P.sessionSeconds: _sessionSeconds});
    _endSession();
    analytics.flush();
  }

  // --- UPI hand-off --------------------------------------------------------

  /// Called the moment the Cashfree SDK is asked to launch [appId], so the next background is
  /// understood as a hand-off rather than the user leaving.
  ///
  /// [appId] is null for the Cashfree checkout-screen fallback, which also leaves the app.
  void upiHandoffStarted(String? appId) {
    _awaitingUpiApp = appId ?? 'cashfree_checkout';
    _upiHandoffAt = null;
  }

  /// Called once the mandate attempt has resolved, so a later unrelated backgrounding is not
  /// reported as a return from a UPI app.
  ///
  /// Deliberately does not clear a hand-off that is still outstanding. The Cashfree callback and
  /// the resume notification race each other — the SDK's result can be delivered before Flutter
  /// reports the app resumed — and clearing here unconditionally would drop `UPI App Returned`
  /// on exactly the successful payments it is most needed for. Once the return has been
  /// reported, [_upiHandoffAt] is already null and this clears normally.
  void upiHandoffFinished() {
    if (_upiHandoffAt != null) return;
    _awaitingUpiApp = null;
  }

  void _reportUpiReturn(Duration gap) {
    final upiApp = _awaitingUpiApp;
    final handoffAt = _upiHandoffAt;
    if (upiApp == null || handoffAt == null) return;

    _upiHandoffAt = null;
    _awaitingUpiApp = null;
    analytics.track(Ev.upiAppReturned, {
      P.appId: upiApp,
      P.secondsInUpiApp: DateTime.now().difference(handoffAt).inSeconds,
    });
  }
}

/// The one session tracker, for the same reason [analyticsObserver] is a singleton: it is created
/// in `bootMobileApp`, before any `ProviderScope` exists.
final analyticsSession = AnalyticsSession();
