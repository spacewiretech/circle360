import 'package:flutter/foundation.dart';
import 'package:mixpanel_flutter/mixpanel_flutter.dart';

import '../models/app_user.dart';
import 'analytics.dart';
import 'analytics_events.dart';

/// The real sink: Mixpanel, with a queue in front of it.
///
/// The queue exists because of where the project token lives. It is a row in the Supabase
/// `app_config` table rather than a compiled-in constant, so it can be rotated or removed without
/// shipping a build — but that means the token is not in hand when the app starts. On a warm
/// launch the cached config resolves in milliseconds and nothing is ever queued; on a very first
/// launch it can take as long as the config fetch's eight-second timeout, and `App Launched`,
/// `Session Started` and the first two screen views all happen well inside that.
///
/// Dropping those events would be the wrong trade: they are the denominator of every acquisition
/// funnel, and losing them only for brand-new users biases exactly the cohort the funnels are
/// about. So they wait here instead, and each carries [P.queuedLagMs] when it finally goes out so
/// a delayed event is never mistaken for a slow user.
class MixpanelAnalytics implements Analytics {
  MixpanelAnalytics({this.verbose = kDebugMode});

  /// Mirrors every event to the console. On by default in debug, because the alternative while
  /// instrumenting is watching Mixpanel's live view and guessing.
  final bool verbose;

  Mixpanel? _mixpanel;
  bool _starting = false;

  /// Past this the queue stops growing. Reached only when the token never arrives at all — an
  /// offline first launch — and at that point the events are stale enough to be worth less than
  /// the memory they occupy.
  static const _maxQueued = 300;

  /// And past this, what is already queued is abandoned. Same reasoning: an hour-old "App
  /// Launched" replayed at the top of the next session would corrupt the session it lands in.
  static const _maxQueueAge = Duration(minutes: 5);

  final List<_Queued> _queue = [];

  /// Attached to every event as it is recorded, not as it is sent — so a queued event carries the
  /// screen the user was actually on, not whichever screen they reached by the time the token
  /// arrived. Installed by the navigator observer and the session tracker.
  Map<String, Object?> Function()? context;

  /// Kept locally as well as on the SDK so they can be handed to [Mixpanel.init], which is what
  /// gets them onto the events replayed out of the queue.
  final Map<String, Object?> _supers = {};

  String? _identifiedAs;

  /// The last People profile written, so an unchanged one is not written again.
  Map<String, Object>? _lastProfile;

  /// Compares two profiles ignoring `last_seen`, which changes on every single call and would
  /// otherwise make every comparison unequal and the whole check pointless.
  static bool _mapEquals(Map<String, Object>? a, Map<String, Object> b) {
    if (a == null) return false;
    final keys = {...a.keys, ...b.keys}..remove('last_seen');
    return keys.every((key) => a[key] == b[key]);
  }

  bool get isStarted => _mixpanel != null;

  /// Brings Mixpanel up and drains whatever accumulated while it was down.
  ///
  /// Safe to call more than once and safe to call with a blank token — both are no-ops. The boot
  /// sequence tries the cached config and the first frame tries the fetched one, and exactly one
  /// of those usually wins.
  Future<void> start(String? token) async {
    if (token == null || token.trim().isEmpty) return;
    if (_mixpanel != null || _starting) return;
    _starting = true;

    try {
      final mixpanel = await Mixpanel.init(
        token.trim(),
        // Every screen, tap and lifecycle transition in this app is named explicitly. Letting the
        // SDK also emit its own `$ae_*` events would mean two overlapping vocabularies for the
        // same actions, and a funnel built on the wrong one silently under-counts.
        trackAutomaticEvents: false,
        superProperties: Map<String, dynamic>.from(_supers),
      );
      mixpanel.setLoggingEnabled(verbose);
      _mixpanel = mixpanel;
      _drain();
    } catch (error) {
      // A bad token, a missing platform channel, a native side that failed to link. None of them
      // may stop the app: this is the one subsystem whose whole job is to be optional.
      debugPrint('[analytics] Mixpanel could not start: $error');
    } finally {
      _starting = false;
    }
  }

  void _drain() {
    final mixpanel = _mixpanel;
    if (mixpanel == null) return;

    final now = DateTime.now();
    final pending = List<_Queued>.of(_queue);
    _queue.clear();

    for (final item in pending) {
      final lag = now.difference(item.at);
      if (lag > _maxQueueAge) continue;
      try {
        item.run(mixpanel, lag.inMilliseconds);
      } catch (error) {
        debugPrint('[analytics] queued call failed: $error');
      }
    }
  }

  /// Runs [action] now, or queues it until [start] succeeds.
  ///
  /// [properties] is carried alongside purely so tests can inspect what was queued without a
  /// platform channel; it is never read on the send path.
  void _dispatch(
    void Function(Mixpanel mixpanel, int lagMs) action, {
    Map<String, Object?>? properties,
  }) {
    final mixpanel = _mixpanel;
    if (mixpanel != null) {
      try {
        action(mixpanel, 0);
      } catch (error) {
        debugPrint('[analytics] call failed: $error');
      }
      return;
    }

    if (_queue.length >= _maxQueued) return;
    _queue.add(_Queued(DateTime.now(), action, properties));
  }

  /// How many calls are waiting for a token.
  @visibleForTesting
  int get debugQueueLength => _queue.length;

  /// The properties of each queued `track`, in the order they were recorded.
  @visibleForTesting
  List<Map<String, Object?>> get debugQueuedProperties =>
      [for (final item in _queue) if (item.properties != null) item.properties!];

  @visibleForTesting
  static int get debugMaxQueued => _maxQueued;

  @override
  void track(String event, [Map<String, Object?> properties = const {}]) {
    // Snapshotted here rather than at send time. See [context].
    final resolved = <String, Object?>{
      ...?context?.call(),
      ...properties,
    }..removeWhere((_, value) => value == null);

    if (verbose) debugPrint('[analytics] $event $resolved');

    _dispatch(
      (mixpanel, lagMs) {
        mixpanel.track(event, properties: {
          ...resolved,
          if (lagMs > 0) P.queuedLagMs: lagMs,
        });
      },
      properties: resolved,
    );
  }

  @override
  void timeEvent(String event) {
    // Not queued: the SDK's stopwatch cannot be started retroactively, and a `$duration` measured
    // from the moment Mixpanel happened to come up would be a fabrication. Events timed before
    // startup simply arrive without one.
    _mixpanel?.timeEvent(event);
  }

  @override
  void identify(AppUser user) {
    final properties = peoplePropertiesFor(user);

    // The entitlement gate re-resolves the user on every resume and on a six-hourly timer, so
    // this is called far more often than anything about the account actually changes. Both the
    // identify call and the profile write are skipped when nothing moved.
    //
    // The comparison is on the properties rather than on the id, because the id is exactly what
    // does *not* change when a trial converts to a paid month — deduping on it would pin the
    // profile to whatever the account looked like at sign-in.
    final isSameUser = _identifiedAs == user.id;
    final unchanged = isSameUser && _mapEquals(_lastProfile, properties);
    _identifiedAs = user.id;
    _lastProfile = properties;

    _dispatch((mixpanel, _) {
      if (!isSameUser) mixpanel.identify(user.id);

      final people = mixpanel.getPeople();
      if (unchanged) {
        // Still worth one write: `last_seen` is the whole point of running on every resume.
        people.set('last_seen', properties['last_seen']);
        return;
      }

      properties.forEach(people.set);
      people.setOnce(r'$created', DateTime.now().toUtc().toIso8601String());
    });

    registerSuper({
      P.isSignedIn: true,
      P.paymentType: user.paymentType.name,
      P.entitled: user.entitled,
      P.inTrial: user.inTrial,
      P.hasEverSubscribed: user.hasEverSubscribed,
      P.billingState: user.billingState?.name,
    });
  }

  /// The account, as Mixpanel's People profile sees it.
  ///
  /// Pulled out of [identify] so a test can assert the mapping without a platform channel.
  /// `$phone` is the real number: support needs to find an account from a call, and the number is
  /// already the login identifier rather than an extra piece of data collected for analytics.
  @visibleForTesting
  static Map<String, Object> peoplePropertiesFor(AppUser user) {
    return <String, Object>{
      r'$name': user.name,
      r'$phone': '+91${user.phone}',
      P.paymentType: user.paymentType.name,
      P.entitled: user.entitled,
      P.inTrial: user.inTrial,
      P.hasEverSubscribed: user.hasEverSubscribed,
      if (user.trialEndsAt != null)
        'trial_ends_at': user.trialEndsAt!.toUtc().toIso8601String(),
      if (user.currentPeriodEnd != null)
        'current_period_end': user.currentPeriodEnd!.toUtc().toIso8601String(),
      if (user.billingState != null) P.billingState: user.billingState!.name,
      'last_seen': DateTime.now().toUtc().toIso8601String(),
    };
  }

  @override
  void reset() {
    _identifiedAs = null;
    _lastProfile = null;
    _supers.removeWhere((key, _) => _identitySupers.contains(key));
    _dispatch((mixpanel, _) => mixpanel.reset());
    // `reset` clears super properties too, so the environment-level ones have to be put back or
    // every event after a sign-out would be missing them.
    if (_supers.isNotEmpty) {
      _dispatch((mixpanel, _) =>
          mixpanel.registerSuperProperties(Map<String, dynamic>.from(_supers)));
    }
  }

  /// Super properties that describe the signed-in account rather than the install, and so must
  /// not survive a sign-out onto the next user of the same device.
  static const _identitySupers = {
    P.isSignedIn,
    P.paymentType,
    P.entitled,
    P.inTrial,
    P.hasEverSubscribed,
    P.billingState,
  };

  @override
  void registerSuper(Map<String, Object?> properties) {
    final cleaned = Map<String, Object?>.from(properties)
      ..removeWhere((_, value) => value == null);
    if (cleaned.isEmpty) return;

    _supers.addAll(cleaned);
    _dispatch((mixpanel, _) =>
        mixpanel.registerSuperProperties(Map<String, dynamic>.from(cleaned)));
  }

  @override
  void trackCharge(double amount, [Map<String, Object?> properties = const {}]) {
    _dispatch((mixpanel, _) => mixpanel.getPeople().trackCharge(
          amount,
          properties: Map<String, dynamic>.from(properties)
            ..removeWhere((_, value) => value == null),
        ));
  }

  @override
  void flush() {
    // Never queued: flushing a queue that has not been sent anywhere is meaningless.
    _mixpanel?.flush();
  }
}

class _Queued {
  const _Queued(this.at, this.run, [this.properties]);

  final DateTime at;
  final void Function(Mixpanel mixpanel, int lagMs) run;

  /// Set for `track` only, and read only by tests.
  final Map<String, Object?>? properties;
}
