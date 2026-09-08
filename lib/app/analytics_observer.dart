import 'package:flutter/widgets.dart';

import '../data/analytics/analytics.dart';
import '../data/analytics/analytics_events.dart';
import 'router.dart';

/// Human names for the route patterns in [Routes].
///
/// Keyed by pattern rather than by resolved path because that is what go_router puts in
/// `RouteSettings.name` — `_buildPlatformAdapterPage` passes `state.name ?? state.path`, and none
/// of these routes are given a `name`. Two consequences worth knowing:
///
///  * `/payment-status/:outcome` arrives with the colon still in it, never with `success`
///    substituted. The resolved value comes through `RouteSettings.arguments` instead, and is
///    reported as a property rather than as three separate screens.
///  * the diagnostics screen is a nested `GoRoute`, so its `path` is the *relative* `'diagnostics'`
///    rather than the full `/settings/diagnostics`.
const _screenNames = <String, String>{
  Routes.splash: 'Splash',
  Routes.invite: 'Invite',
  Routes.phone: 'Phone',
  Routes.otp: 'OTP',
  Routes.name: 'Name',
  Routes.subscribe: 'Paywall',
  Routes.paymentStatus: 'Payment Status',
  Routes.location: 'Location Permission',
  Routes.home: 'Home',
  Routes.emergency: 'Emergency',
  Routes.profile: 'Profile',
  Routes.settings: 'Settings',
  'diagnostics': 'Diagnostics',
};

/// Names for the surfaces that are routes but not screens.
///
/// Modal sheets and dialogs push real routes, so without this they would arrive as anonymous
/// entries and the UPI picker — one of the more interesting things a user can do on the paywall —
/// would be invisible. Each call site passes a matching `RouteSettings(name: ...)`.
const _modalNames = <String, String>{
  'upi-picker': 'UPI App Picker',
  'add-person': 'Add Person Sheet',
  'invite-confirm': 'Invite Confirm Dialog',
  'remove-person': 'Remove Person Dialog',
};

/// The friendly name for a route pattern, or null when it is not one we know.
String? screenNameFor(String? routeName) {
  if (routeName == null) return null;
  return _screenNames[routeName] ?? _modalNames[routeName];
}

/// Emits screen views, screen exits and back presses for every route the app pushes.
///
/// One observer on the router covers all thirteen screens and every modal, which is the whole
/// reason for doing it here rather than in thirteen `initState`s: a screen added next month is
/// instrumented the moment it is routable, with no chance of someone forgetting.
///
/// It also holds [contextProperties], the ambient `screen` every other event in the app is
/// stamped with. That is why button and ViewModel events never have to be told which screen they
/// happened on.
class AnalyticsNavigatorObserver extends NavigatorObserver {
  final List<_Entry> _stack = [];

  /// How many screen views this session has seen, reported when the session ends.
  int screensViewed = 0;

  _Entry? get _current => _stack.isEmpty ? null : _stack.last;

  /// Merged into every event by [MixpanelAnalytics.context].
  Map<String, Object?> contextProperties() {
    final current = _current;
    if (current == null) return const {};
    return {
      P.screen: current.name,
      if (current.isModal) P.isModal: true,
    };
  }

  /// The screen a non-navigation event should be attributed to. Exposed for the few callers that
  /// need it as a value rather than as an ambient property.
  String? get currentScreen => _current?.name;

  _Entry? _entryFor(Route<dynamic>? route) {
    if (route == null) return null;
    final routeName = route.settings.name;
    final known = screenNameFor(routeName);

    // A route with no name we recognise is almost always a `showDialog` or `showModalBottomSheet`
    // that was not given `routeSettings`. Naming it after its type at least keeps it countable
    // instead of silently merging with whatever screen it covered.
    final isModal = known == null || _modalNames.containsKey(routeName);
    return _Entry(
      name: known ?? 'Unnamed ${route.runtimeType}',
      path: routeName,
      isModal: isModal,
      arguments: route.settings.arguments,
    );
  }

  void _enter(Route<dynamic>? route, String navType) {
    final entry = _entryFor(route);
    if (entry == null) return;

    final previous = _current?.name;
    _stack.add(entry);
    screensViewed++;

    analytics.track(Ev.screenViewed, {
      P.screen: entry.name,
      P.previousScreen: previous,
      P.routePath: entry.path,
      P.navType: navType,
      P.isModal: entry.isModal,
      ...entry.argumentProperties,
    });
  }

  /// Reports a screen becoming visible again after what was above it went away.
  ///
  /// Not the same as [_enter]: the screen is already on the stack, so pushing it a second time
  /// would leave a phantom entry behind and corrupt every `screen` property after it. This
  /// re-emits the view and restarts its dwell timer in place.
  void _resurface(Route<dynamic>? route) {
    final entry = _entryFor(route);
    if (entry == null) return;

    final index = _stack.lastIndexWhere((e) => e.name == entry.name);
    if (index == -1) {
      _enter(route, NavType.pop);
      return;
    }

    final existing = _stack[index];
    existing.restartDwell();
    screensViewed++;

    analytics.track(Ev.screenViewed, {
      P.screen: existing.name,
      P.routePath: existing.path,
      P.navType: NavType.pop,
      P.isModal: existing.isModal,
    });
  }

  void _leave(Route<dynamic>? route, String exitType) {
    final entry = _entryFor(route);
    if (entry == null) return;

    // Matched by name rather than popped blindly: go_router rebuilds its page list declaratively,
    // so removals do not always arrive in stack order.
    final index = _stack.lastIndexWhere((e) => e.name == entry.name);
    if (index == -1) return;
    final leaving = _stack.removeAt(index);

    analytics.track(Ev.screenExited, {
      P.screen: leaving.name,
      P.routePath: leaving.path,
      P.exitType: exitType,
      P.secondsOnScreen: leaving.secondsOnScreen,
    });
  }

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _enter(route, NavType.push);
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    // Every `context.go` in this app replaces the stack rather than popping it, and the sole
    // `context.push` is phone → OTP. So a pop here really is the user going back: the system
    // gesture, a `CircleBackButton`, or a dismissed sheet — which is what makes this a usable
    // stand-in for a back press.
    final entry = _entryFor(route);
    if (entry != null) {
      analytics.track(Ev.backPressed, {
        P.screen: entry.name,
        P.blocked: false,
        P.isModal: entry.isModal,
      });
    }
    _leave(route, ExitType.pop);
    // Going back to a screen is a view of it. Without this, a user who reaches OTP, backs out to
    // Phone and tries a different number would show one Phone view and two OTP views, which
    // reads as the opposite of what happened.
    if (previousRoute != null) _resurface(previousRoute);
  }

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    _leave(oldRoute, ExitType.replaced);
    _enter(newRoute, NavType.replace);
  }

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _leave(route, ExitType.removed);
  }
}

/// The one observer instance, referenced by [appRouter].
///
/// Top-level for the same reason the router is: the router is built before any `ProviderScope`
/// exists, so its observers cannot come from one.
final analyticsObserver = AnalyticsNavigatorObserver();

class _Entry {
  _Entry({
    required this.name,
    required this.path,
    required this.isModal,
    this.arguments,
  }) : _since = DateTime.now();

  final String name;
  final String? path;
  final bool isModal;
  final Object? arguments;
  DateTime _since;

  int get secondsOnScreen => DateTime.now().difference(_since).inSeconds;

  /// Called when the screen resurfaces, so its dwell time measures this visit rather than the
  /// whole span since it was first pushed — most of which the user spent on top of it.
  void restartDwell() => _since = DateTime.now();

  /// go_router puts the resolved path and query parameters in `RouteSettings.arguments`, which is
  /// the only place `/payment-status/:outcome` reveals which outcome it actually is.
  Map<String, Object?> get argumentProperties {
    final args = arguments;
    if (args is! Map) return const {};
    return {
      for (final entry in args.entries)
        if (entry.key is String && entry.value != null)
          'route_${entry.key}': entry.value,
    };
  }
}
