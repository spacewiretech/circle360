import 'package:flutter/widgets.dart' show VoidCallback;

import '../models/app_user.dart';
import 'analytics_events.dart';

/// Everything the app is allowed to ask of an analytics backend.
///
/// Deliberately narrow, and deliberately synchronous where it can be: a `track` call sits in the
/// middle of a button handler and a payment callback, and neither of those may be made to wait on
/// the network. Implementations queue and flush on their own schedule.
///
/// Every method must swallow its own failures. Analytics is the least important thing this app
/// does, and it may never be the reason a payment screen throws.
abstract interface class Analytics {
  /// Records one event. [properties] is merged over the current super properties.
  void track(String event, [Map<String, Object?> properties]);

  /// Starts Mixpanel's own stopwatch for [event]. The next [track] of the same name carries a
  /// `$duration` computed by the SDK, which is more accurate than anything measured in Dart
  /// across an app that may have been backgrounded in between.
  void timeEvent(String event);

  /// Binds every future event to [user], and mirrors the account onto their People profile.
  ///
  /// Safe to call repeatedly with the same user — implementations are expected to no-op when
  /// nothing has changed, because the entitlement gate re-resolves the user on every resume.
  void identify(AppUser user);

  /// Forgets the current identity and mints a new anonymous one. Sign-out only.
  void reset();

  /// Adds to the properties sent with every subsequent event.
  void registerSuper(Map<String, Object?> properties);

  /// Records revenue against the current People profile.
  void trackCharge(double amount, [Map<String, Object?> properties]);

  /// Pushes anything queued to the network now. Called when the app backgrounds, because the
  /// process may not survive to the next natural flush.
  void flush();
}

/// The implementation everything runs on until [installAnalytics] says otherwise.
///
/// This is what makes the whole integration optional: with no `mixpanel_token` in `app_config`,
/// with no network on first launch, in every test, and in the web build — which never calls
/// [installAnalytics] at all — the app runs against this and behaves exactly as it did before
/// analytics existed.
class NoopAnalytics implements Analytics {
  const NoopAnalytics();

  @override
  void track(String event, [Map<String, Object?> properties = const {}]) {}

  @override
  void timeEvent(String event) {}

  @override
  void identify(AppUser user) {}

  @override
  void reset() {}

  @override
  void registerSuper(Map<String, Object?> properties) {}

  @override
  void trackCharge(double amount, [Map<String, Object?> properties = const {}]) {}

  @override
  void flush() {}
}

Analytics _instance = const NoopAnalytics();

/// The app-wide analytics sink.
///
/// A top-level holder rather than a Riverpod provider, which is against the grain of the rest of
/// this codebase and needs justifying. Three of the four callers cannot reach a `ProviderScope`:
///
///  * [appRouter] is a top-level `final` built before `runApp`, so the `NavigatorObserver`
///    attached to it has no `ref` to read from;
///  * the shared widgets in `lib/widgets/` are plain `StatelessWidget`s, and only one test file
///    wraps anything in a `ProviderScope` — making them `ConsumerWidget`s to reach a provider
///    would break the rest;
///  * `bootMobileApp` itself runs before the scope exists, and the first events are launch
///    events.
///
/// ViewModels still read [analyticsProvider], so they stay overridable in tests. The provider and
/// this holder are handed the same instance by the boot sequence.
Analytics get analytics => _instance;

/// Called once, by `bootMobileApp`. Tests may call it to install a recording double, and should
/// restore [NoopAnalytics] afterwards.
void installAnalytics(Analytics implementation) => _instance = implementation;

/// Wraps a tap handler so it reports itself before running.
///
/// Used by the shared widgets in `lib/widgets/`, which is what makes tap tracking a property of
/// the design system rather than a thing each screen has to remember. The screen the tap happened
/// on is filled in by the navigator observer, so no call site has to pass it.
///
/// Returns null when [onTap] is null, so a disabled button stays disabled and — importantly — a
/// disabled button never reports a tap it did not receive.
VoidCallback? trackedTap(
  VoidCallback? onTap, {
  required String? id,
  String? label,
  Map<String, Object?> properties = const {},
}) {
  if (onTap == null) return null;
  return () {
    analytics.track(Ev.elementTapped, {
      P.elementId: id ?? slugify(label),
      P.label: label,
      ...properties,
    });
    onTap();
  };
}

/// A stable id derived from a human label — `'Retry Payment'` becomes `'retry_payment'`.
///
/// The fallback for controls that were not given an explicit id. Labels that interpolate a price
/// or a countdown would otherwise produce a new id per render, so digits are stripped: without
/// that, `Subscribe · ₹499/month` and `Start 2-day trial · ₹3` become unrelated columns in every
/// breakdown, and the raw label is still carried separately in [P.label].
String? slugify(String? label) {
  if (label == null) return null;
  final slug = label
      .toLowerCase()
      .replaceAll(RegExp(r'[^a-z ]'), ' ')
      .trim()
      .replaceAll(RegExp(r'\s+'), '_');
  return slug.isEmpty ? null : slug;
}
