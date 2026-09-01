import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:loc_360/features/diagnostics/tracking_diagnostics_screen.dart';
import 'package:loc_360/location_service.dart';

/// The 10s loop and uploads live natively, so what's testable from Dart is the channel
/// contract: that native snapshots decode correctly and drive the right UI state.
void main() {
  const methodChannel = MethodChannel('loc360/location');

  late Map<String, Object?> nativeStatus;
  late List<String> calls;
  late List<MethodCall> invocations;

  setUp(() {
    calls = [];
    invocations = [];
    nativeStatus = <String, Object?>{
      'permission': 'notRequested',
      'isTracking': false,
      'successCount': 0,
      'failureCount': 0,
    };

    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(methodChannel, (call) async {
      calls.add(call.method);
      invocations.add(call);
      // The channel is not uniform: the status methods answer with a snapshot map and the
      // rest with a bool, so a mock that returned one shape for everything would pass while
      // the real app threw on the cast.
      return switch (call.method) {
        'getStatus' ||
        'requestPermissions' ||
        'requestBackgroundPermission' =>
          nativeStatus,
        'openAppSettings' => null,
        _ => true,
      };
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(methodChannel, null);
  });

  group('TrackingStatus.fromMap', () {
    test('decodes a full native snapshot', () {
      final status = TrackingStatus.fromMap(<Object?, Object?>{
        'permission': 'always',
        'isTracking': true,
        'latitude': 12.971599,
        'longitude': 77.594566,
        'accuracy': 8.4,
        'lastFixAt': 1756633200000,
        'lastSuccessAt': 1756633200000,
        'successCount': 42,
        'failureCount': 3,
        'lastError': null,
        'batteryOptimized': true,
      });

      expect(status.permission, LocationPermission.always);
      expect(status.isTracking, isTrue);
      expect(status.hasFix, isTrue);
      // Coordinates must survive the channel without precision loss.
      expect(status.latitude, closeTo(12.971599, 1e-9));
      expect(status.successCount, 42);
      expect(status.failureCount, 3);
      expect(status.batteryOptimized, isTrue);
      expect(status.lastFixAt, isNotNull);
    });

    test('tolerates a sparse snapshot from a device with no fix yet', () {
      final status = TrackingStatus.fromMap(<Object?, Object?>{
        'permission': 'whileInUse',
        'isTracking': false,
      });

      expect(status.hasFix, isFalse);
      expect(status.lastFixAt, isNull);
      expect(status.lastSuccessAt, isNull);
      expect(status.successCount, 0);
      expect(status.batteryOptimized, isFalse);
    });

    test('unknown permission strings degrade to notRequested', () {
      final status = TrackingStatus.fromMap(<Object?, Object?>{'permission': 'bogus'});
      expect(status.permission, LocationPermission.notRequested);
    });
  });

  group('upload credentials', () {
    test('configureUpload carries the endpoint, api key and session token', () async {
      await LocationService().configureUpload(
        endpoint: 'https://example.supabase.co/functions/v1/ingest-location',
        apiKey: 'anon-key',
        token: 'session-token',
      );

      final call = invocations.single;
      expect(call.method, 'configureUpload');
      final args = call.arguments as Map;
      expect(args['endpoint'], contains('ingest-location'));
      expect(args['apiKey'], 'anon-key');
      expect(args['token'], 'session-token');
    });

    test('clearUpload is what sign-out uses to stop a handset broadcasting', () async {
      expect(await LocationService().clearUpload(), isTrue);
      expect(calls, ['clearUpload']);
    });

    test('uploadConfigured decodes, and defaults false on an older native build', () {
      expect(
        TrackingStatus.fromMap(<Object?, Object?>{'uploadConfigured': true})
            .uploadConfigured,
        isTrue,
      );
      // A native half that predates the field must read as "no credential", not as configured.
      expect(TrackingStatus.fromMap(const <Object?, Object?>{}).uploadConfigured, isFalse);
    });
  });

  group('LocationPermission', () {
    test('only whileInUse and always can track', () {
      expect(LocationPermission.whileInUse.canTrack, isTrue);
      expect(LocationPermission.always.canTrack, isTrue);
      expect(LocationPermission.denied.canTrack, isFalse);
      expect(LocationPermission.deniedForever.canTrack, isFalse);
      expect(LocationPermission.notRequested.canTrack, isFalse);
    });
  });

  group('TrackingDiagnosticsScreen', () {
    // The screen is a scrolling list; a tall surface keeps every card built so finders don't
    // miss widgets that are merely below the fold.
    Future<void> pumpScreen(WidgetTester tester) async {
      await tester.binding.setSurfaceSize(const Size(1000, 2000));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        const MaterialApp(home: TrackingDiagnosticsScreen()),
      );
      await tester.pump();
    }

    testWidgets('pulls status on launch and shows the idle state', (tester) async {
      await pumpScreen(tester);

      expect(calls, contains('getStatus'));
      expect(find.text('Not tracking'), findsOneWidget);
      expect(find.text('Grant permission'), findsOneWidget);
      // No start button until permission allows tracking.
      expect(find.text('Start tracking'), findsNothing);
    });

    testWidgets('shows the active state when native reports tracking', (tester) async {
      nativeStatus = <String, Object?>{
        'permission': 'always',
        'isTracking': true,
        'latitude': 12.971599,
        'longitude': 77.594566,
        'accuracy': 8.4,
        'successCount': 7,
        'failureCount': 0,
      };

      await pumpScreen(tester);

      expect(find.text('Tracking active'), findsOneWidget);
      expect(find.text('Stop tracking'), findsOneWidget);
      expect(find.text('12.971599'), findsOneWidget);
      expect(find.text('7'), findsOneWidget);
    });

    testWidgets('offers the Settings route when denied forever', (tester) async {
      nativeStatus = <String, Object?>{
        'permission': 'deniedForever',
        'isTracking': false,
        'successCount': 0,
        'failureCount': 0,
      };

      await pumpScreen(tester);

      expect(find.text('Open Settings'), findsOneWidget);
      expect(find.textContaining('permanently denied'), findsOneWidget);
    });

    testWidgets('prompts for the background upgrade when only while-in-use', (tester) async {
      nativeStatus = <String, Object?>{
        'permission': 'whileInUse',
        'isTracking': true,
        'successCount': 0,
        'failureCount': 0,
      };

      await pumpScreen(tester);

      // Label differs per platform; both routes call requestBackgroundPermission.
      final upgrade = find.textContaining(RegExp('Always|all the time'));
      expect(upgrade, findsOneWidget);

      await tester.tap(upgrade);
      await tester.pump();
      expect(calls, contains('requestBackgroundPermission'));
    });
  });
}
