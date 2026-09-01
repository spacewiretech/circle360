import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:latlong2/latlong.dart';

import '../../app/env.dart';
import '../../location_service.dart';
import '../providers.dart';

/// What the UI needs to know about this device's own tracking.
@immutable
class LocationState {
  const LocationState({
    this.status = TrackingStatus.unknown,
    this.busy = false,
    this.error,
  });

  final TrackingStatus status;

  /// True while a permission prompt or a start/stop is in flight, so the banner does not flap.
  final bool busy;
  final String? error;

  LocationPermission get permission => status.permission;

  /// Location is actually leaving this device.
  bool get isLive =>
      status.isTracking && status.uploadConfigured && permission.canTrack;

  /// The user has been asked and answered — enough to stop showing the priming screen, whether
  /// they said yes or no. A refusal must not trap them on a screen they cannot pass.
  bool get hasAnswered => permission != LocationPermission.notRequested;

  /// Why sharing is not live, or null when it is. Drives the Home banner's copy.
  String? get problem {
    if (isLive) return null;
    return switch (permission) {
      LocationPermission.notRequested => 'Turn on location sharing',
      LocationPermission.denied => 'Location permission is off',
      LocationPermission.deniedForever => 'Location is blocked in Settings',
      _ when !status.uploadConfigured => 'Sign in again to share your location',
      _ when !status.isTracking => 'Location sharing is paused',
      _ => null,
    };
  }

  /// This device's last known position, used to centre the map and measure distances.
  LatLng? get here => status.hasFix
      ? LatLng(status.latitude!, status.longitude!)
      : null;

  LocationState copyWith({
    TrackingStatus? status,
    bool? busy,
    String? error,
    bool clearError = false,
  }) {
    return LocationState(
      status: status ?? this.status,
      busy: busy ?? this.busy,
      error: clearError ? null : (error ?? this.error),
    );
  }
}

/// Owns this device's side of location sharing.
///
/// The native tracker is the thing that actually runs; this is the only place that decides
/// *when* it should. Three rules, and everything else follows from them:
///
/// 1. Nothing is uploaded without a session token — [LocationService.configureUpload] is the
///    single route a credential takes to native, and without it the uploader stays silent.
/// 2. Tracking starts only after the user has granted permission, never speculatively.
/// 3. Signing out stops tracking *and* clears the token, so a shared handset does not keep
///    broadcasting the previous user's position.
class LocationController extends Notifier<LocationState> {
  StreamSubscription<TrackingStatus>? _subscription;

  @override
  LocationState build() {
    final service = ref.watch(locationServiceProvider);

    // Native pushes a new status on every fix, so the banner and the "Updated now" line stay
    // current without the UI polling for them.
    //
    // Wrapped because attaching to a platform channel throws outright where there is no binding
    // — a unit test, or a platform with no native half. Losing live pushes there is fine;
    // taking the rest of the app down with it is not, and `refresh()` still works on demand.
    try {
      _subscription = service.statusStream.listen(
        (status) => state = state.copyWith(status: status),
        onError: (Object error) => debugPrint('[location] status stream: $error'),
      );
      ref.onDispose(() => _subscription?.cancel());
    } on Object catch (error) {
      debugPrint('[location] status stream unavailable: $error');
    }

    scheduleMicrotask(refresh);
    return const LocationState();
  }

  LocationService get _service => ref.read(locationServiceProvider);

  Future<void> refresh() async {
    try {
      state = state.copyWith(status: await _service.getStatus());
    } on Object catch (error) {
      // No platform channel in a test or on an unsupported platform. Not worth surfacing.
      debugPrint('[location] getStatus failed: $error');
    }
  }

  /// Pushes the current session down to native and starts tracking if permission allows.
  ///
  /// Safe to call repeatedly — on every launch, after sign-in, and on resume. Without the
  /// re-push a token refreshed by `verify-otp` would never reach the uploader.
  Future<void> syncSession() async {
    if (!Env.hasSupabase) return;

    final token = await ref.read(sessionStoreProvider).readToken();
    if (token == null) {
      await stopSharing(clearCredential: true);
      return;
    }

    try {
      await _service.configureUpload(
        endpoint: Env.ingestLocationUrl,
        apiKey: Env.supabaseAnonKey,
        token: token,
      );
      // Only resume on its own if the user has not deliberately switched sharing off. A cold
      // start must not override a Stop the user chose on the settings screen.
      if (state.permission.canTrack && state.status.isTracking) {
        await _service.startTracking();
      }
      await refresh();
    } on Object catch (error) {
      debugPrint('[location] configureUpload failed: $error');
    }
  }

  /// Runs the staged permission flow, then starts tracking. Native starts automatically the
  /// moment foreground location lands, so this mostly exists to refresh state afterwards.
  Future<void> requestPermission() async {
    state = state.copyWith(busy: true, clearError: true);
    try {
      final status = await _service.requestPermissions();
      state = state.copyWith(status: status);
      if (status.permission.canTrack) {
        await syncSession();
        await _service.startTracking();
      }
      await refresh();
    } on Object catch (error) {
      state = state.copyWith(error: 'Could not turn on location. Please try again.');
      debugPrint('[location] requestPermissions failed: $error');
    } finally {
      state = state.copyWith(busy: false);
    }
  }

  /// Android 11+ and iOS both put "always" behind their own flow; native routes to Settings
  /// where a runtime prompt would be silently denied.
  Future<void> requestBackgroundPermission() async {
    state = state.copyWith(busy: true);
    try {
      state = state.copyWith(status: await _service.requestBackgroundPermission());
    } on Object catch (error) {
      debugPrint('[location] requestBackgroundPermission failed: $error');
    } finally {
      state = state.copyWith(busy: false);
    }
  }

  Future<void> startSharing() async {
    state = state.copyWith(busy: true, clearError: true);
    try {
      if (!state.permission.canTrack) {
        await requestPermission();
        return;
      }
      await syncSession();
      await _service.startTracking();
      await refresh();
    } finally {
      state = state.copyWith(busy: false);
    }
  }

  /// Stops the native tracker. [clearCredential] also drops the stored token, which is what
  /// sign-out needs — a paused user keeps theirs so resuming does not require a round trip.
  Future<void> stopSharing({bool clearCredential = false}) async {
    state = state.copyWith(busy: true);
    try {
      await _service.stopTracking();
      if (clearCredential) await _service.clearUpload();
      await refresh();
    } on Object catch (error) {
      debugPrint('[location] stopTracking failed: $error');
    } finally {
      state = state.copyWith(busy: false);
    }
  }

  Future<void> openAppSettings() => _service.openAppSettings();

  Future<void> requestIgnoreBatteryOptimizations() =>
      _service.requestIgnoreBatteryOptimizations();
}

final locationControllerProvider =
    NotifierProvider<LocationController, LocationState>(LocationController.new);
