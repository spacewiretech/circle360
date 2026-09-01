import 'dart:async';

import 'package:flutter/services.dart';

/// Permission states reported by both platforms.
///
/// On Android `always` means ACCESS_BACKGROUND_LOCATION is granted; on iOS it means
/// Always authorization. `whileInUse` still allows tracking, but it will not survive a
/// reboot (Android) or a force-quit relaunch (iOS).
enum LocationPermission {
  notRequested,
  denied,
  deniedForever,
  whileInUse,
  always;

  static LocationPermission parse(String? value) => switch (value) {
        'denied' => LocationPermission.denied,
        'deniedForever' => LocationPermission.deniedForever,
        'whileInUse' => LocationPermission.whileInUse,
        'always' => LocationPermission.always,
        _ => LocationPermission.notRequested,
      };

  bool get canTrack =>
      this == LocationPermission.whileInUse || this == LocationPermission.always;

  String get label => switch (this) {
        LocationPermission.notRequested => 'Not requested',
        LocationPermission.denied => 'Denied',
        LocationPermission.deniedForever => 'Denied — needs Settings',
        LocationPermission.whileInUse => 'While using the app',
        LocationPermission.always => 'Always',
      };
}

/// Immutable snapshot of what the native side is doing.
class TrackingStatus {
  const TrackingStatus({
    required this.permission,
    required this.isTracking,
    this.latitude,
    this.longitude,
    this.accuracy,
    this.lastFixAt,
    this.lastSuccessAt,
    this.successCount = 0,
    this.failureCount = 0,
    this.lastError,
    this.batteryOptimized = false,
    this.uploadConfigured = false,
  });

  final LocationPermission permission;
  final bool isTracking;
  final double? latitude;
  final double? longitude;
  final double? accuracy;
  final DateTime? lastFixAt;
  final DateTime? lastSuccessAt;
  final int successCount;
  final int failureCount;
  final String? lastError;

  /// Android only: true when the app is still subject to battery optimisation, which is the
  /// most common reason tracking dies silently on OEM ROMs.
  final bool batteryOptimized;

  /// True once a session token has been pushed down to native.
  ///
  /// Without it "tracking is on but every fix is being dropped" is indistinguishable from
  /// healthy tracking, because the native side never even attempts a request.
  final bool uploadConfigured;

  static const unknown = TrackingStatus(
    permission: LocationPermission.notRequested,
    isTracking: false,
  );

  bool get hasFix => latitude != null && longitude != null;

  static DateTime? _millis(Object? value) => value == null
      ? null
      : DateTime.fromMillisecondsSinceEpoch((value as num).toInt());

  factory TrackingStatus.fromMap(Map<Object?, Object?> map) => TrackingStatus(
        permission: LocationPermission.parse(map['permission'] as String?),
        isTracking: map['isTracking'] as bool? ?? false,
        latitude: (map['latitude'] as num?)?.toDouble(),
        longitude: (map['longitude'] as num?)?.toDouble(),
        accuracy: (map['accuracy'] as num?)?.toDouble(),
        lastFixAt: _millis(map['lastFixAt']),
        lastSuccessAt: _millis(map['lastSuccessAt']),
        successCount: (map['successCount'] as num?)?.toInt() ?? 0,
        failureCount: (map['failureCount'] as num?)?.toInt() ?? 0,
        lastError: map['lastError'] as String?,
        batteryOptimized: map['batteryOptimized'] as bool? ?? false,
        uploadConfigured: map['uploadConfigured'] as bool? ?? false,
      );
}

/// Thin wrapper over the platform channels.
///
/// Deliberately has no logic of its own: the 10-second loop, the uploads and the counters all
/// live in Kotlin/Swift so they keep running when this isolate is gone.
class LocationService {
  static const MethodChannel _methods = MethodChannel('loc360/location');
  static const EventChannel _events = EventChannel('loc360/events');

  Stream<TrackingStatus>? _statusStream;

  /// Live pushes from native. Only delivers while the Flutter UI is attached — after a kill the
  /// UI re-reads [getStatus] instead.
  Stream<TrackingStatus> get statusStream => _statusStream ??= _events
      .receiveBroadcastStream()
      .map((event) => TrackingStatus.fromMap(event as Map<Object?, Object?>))
      .asBroadcastStream();

  Future<TrackingStatus> getStatus() => _invokeStatus('getStatus');

  /// Runs the staged permission flow. Native starts tracking automatically the moment
  /// foreground location is granted.
  Future<TrackingStatus> requestPermissions() => _invokeStatus('requestPermissions');

  /// Android: routes to Settings on API 30+ where "Allow all the time" is Settings-only.
  /// iOS: requests the When-In-Use → Always upgrade.
  Future<TrackingStatus> requestBackgroundPermission() =>
      _invokeStatus('requestBackgroundPermission');

  /// Hands the session credential down to native.
  ///
  /// The native uploader outlives this isolate — it keeps running after a force-quit, and on iOS
  /// the process can be relaunched with no Flutter engine at all — so it cannot call back for a
  /// token when it needs one. This push is the only route the credential has.
  Future<bool> configureUpload({
    required String endpoint,
    required String apiKey,
    required String token,
  }) async =>
      await _methods.invokeMethod<bool>('configureUpload', {
        'endpoint': endpoint,
        'apiKey': apiKey,
        'token': token,
      }) ??
      false;

  /// Drops the stored credential, so a signed-out device uploads nothing.
  Future<bool> clearUpload() async =>
      await _methods.invokeMethod<bool>('clearUpload') ?? false;

  Future<bool> startTracking() async =>
      await _methods.invokeMethod<bool>('startTracking') ?? false;

  Future<bool> stopTracking() async =>
      await _methods.invokeMethod<bool>('stopTracking') ?? false;

  Future<void> openAppSettings() => _methods.invokeMethod<void>('openAppSettings');

  Future<void> requestIgnoreBatteryOptimizations() =>
      _methods.invokeMethod<void>('requestIgnoreBatteryOptimizations');

  Future<TrackingStatus> _invokeStatus(String method) async {
    final result = await _methods.invokeMethod<Map<Object?, Object?>>(method);
    return result == null ? TrackingStatus.unknown : TrackingStatus.fromMap(result);
  }
}
