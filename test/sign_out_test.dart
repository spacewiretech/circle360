import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:loc_360/data/analytics/analytics.dart';
import 'package:loc_360/data/analytics/analytics_events.dart';
import 'package:loc_360/data/entitlement.dart';
import 'package:loc_360/data/location/location_controller.dart';
import 'package:loc_360/data/models/app_user.dart';
import 'package:loc_360/data/providers.dart';
import 'package:loc_360/data/repositories/auth_repository.dart';
import 'package:loc_360/features/auth/sign_out.dart';

/// Sign-out is three side effects whose *order* is the whole point — each one is a real bug when
/// it moves, and the reason the sequence was extracted out of the two screens that trigger it.
/// Every stub below appends to one shared [calls] list so the order can be asserted directly.
void main() {
  late List<String> calls;
  late _RecordingAnalytics analytics;
  late _StubAuth auth;
  late _StubLocationController location;

  ProviderContainer containerWith() {
    final container = ProviderContainer(overrides: [
      analyticsProvider.overrideWithValue(analytics),
      authRepositoryProvider.overrideWithValue(auth),
      locationControllerProvider.overrideWith(() => location),
    ]);
    addTearDown(container.dispose);
    return container;
  }

  setUp(() {
    calls = [];
    analytics = _RecordingAnalytics(calls);
    auth = _StubAuth(calls);
    location = _StubLocationController(calls);
  });

  group('signOutProvider', () {
    test('reports the sign-out before resetting the analytics identity', () async {
      final container = containerWith();

      await container.read(signOutProvider)(source: 'profile');

      // Tracked after the reset, the event would be attributed to the fresh anonymous identity
      // rather than to the user who actually left.
      expect(
        calls.indexOf('track:${Ev.signedOut}'),
        lessThan(calls.indexOf('reset')),
      );
      expect(analytics.resets, 1);
    });

    test('carries the screen it was triggered from', () async {
      final container = containerWith();

      await container.read(signOutProvider)(source: 'settings');

      final event = analytics.events.singleWhere((e) => e.name == Ev.signedOut);
      expect(event.properties[P.source], 'settings');
    });

    test('stops the tracker and drops its credential before clearing the session', () async {
      final container = containerWith();

      await container.read(signOutProvider)(source: 'profile');

      // Signing out first would leave the native service uploading the previous user's position
      // from a handset they have already handed back.
      expect(location.clearedCredential, isTrue);
      expect(calls.indexOf('stopSharing'), lessThan(calls.indexOf('signOut')));
    });

    test('clears the cached entitlement', () async {
      final container = containerWith();
      container.read(entitlementProvider.notifier).set(
            const AppUser(id: 'u1', phone: '9931145610', entitled: true),
          );

      await container.read(signOutProvider)(source: 'profile');

      expect(container.read(entitlementProvider), isNull);
    });
  });
}

class _RecordingAnalytics implements Analytics {
  _RecordingAnalytics(this._calls);

  final List<String> _calls;
  final events = <({String name, Map<String, Object?> properties})>[];
  int resets = 0;

  @override
  void track(String event, [Map<String, Object?> properties = const {}]) {
    _calls.add('track:$event');
    events.add((name: event, properties: properties));
  }

  @override
  void reset() {
    _calls.add('reset');
    resets++;
  }

  /// Not asserted on, but [EntitlementNotifier.set] binds the identity here on the way past.
  @override
  void identify(AppUser user) {}

  @override
  noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _StubAuth implements AuthRepository {
  _StubAuth(this._calls);

  final List<String> _calls;

  @override
  Future<void> signOut() async => _calls.add('signOut');

  @override
  noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// Overriding [build] keeps the real controller's platform channel out of the test — the stream
/// subscription and the `refresh()` microtask both need a native half that is not there.
class _StubLocationController extends LocationController {
  _StubLocationController(this._calls);

  final List<String> _calls;
  bool clearedCredential = false;

  @override
  LocationState build() => const LocationState();

  @override
  Future<void> stopSharing({bool clearCredential = false}) async {
    _calls.add('stopSharing');
    clearedCredential = clearCredential;
  }
}
