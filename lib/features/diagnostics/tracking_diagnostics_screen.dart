import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/material.dart';

import '../../location_service.dart';

/// The pre-Figma tracking UI, kept intact so the native pipeline stays observable.
///
/// Reached from Profile -> Settings -> Tracking diagnostics. It deliberately talks to
/// [LocationService] directly rather than going through a ViewModel: it is a debugging
/// surface for the platform channel, not a product screen.
class TrackingDiagnosticsScreen extends StatefulWidget {
  const TrackingDiagnosticsScreen({super.key});

  @override
  State<TrackingDiagnosticsScreen> createState() => _TrackingDiagnosticsScreenState();
}

class _TrackingDiagnosticsScreenState extends State<TrackingDiagnosticsScreen> with WidgetsBindingObserver {
  final LocationService _service = LocationService();

  TrackingStatus _status = TrackingStatus.unknown;
  StreamSubscription<TrackingStatus>? _subscription;
  Timer? _ticker;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _subscription = _service.statusStream.listen((status) {
      if (mounted) setState(() => _status = status);
    });
    // Keeps the "age" labels honest between pushes.
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
    _refresh();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Native keeps tracking while we're away, so re-read the truth on the way back in.
    if (state == AppLifecycleState.resumed) _refresh();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _subscription?.cancel();
    _ticker?.cancel();
    super.dispose();
  }

  Future<void> _refresh() async {
    final status = await _service.getStatus();
    if (mounted) setState(() => _status = status);
  }

  Future<void> _run(Future<void> Function() action) async {
    setState(() => _busy = true);
    try {
      await action();
      await _refresh();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Tracking diagnostics'),
        actions: [
          IconButton(
            onPressed: _busy ? null : _refresh,
            icon: const Icon(Icons.refresh),
            tooltip: 'Refresh',
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: _refresh,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            _TrackingBanner(isTracking: _status.isTracking),
            const SizedBox(height: 16),
            _PermissionCard(
              status: _status,
              busy: _busy,
              onGrant: () => _run(_service.requestPermissions),
              onUpgrade: () => _run(_service.requestBackgroundPermission),
              onSettings: () => _run(_service.openAppSettings),
            ),
            const SizedBox(height: 12),
            _LastFixCard(status: _status),
            const SizedBox(height: 12),
            _UploadCard(status: _status),
            if (_status.batteryOptimized) ...[
              const SizedBox(height: 12),
              _BatteryCard(
                busy: _busy,
                onFix: () => _run(_service.requestIgnoreBatteryOptimizations),
              ),
            ],
            const SizedBox(height: 20),
            _PrimaryAction(
              status: _status,
              busy: _busy,
              onStart: () => _run(_service.startTracking),
              onStop: () => _run(_service.stopTracking),
            ),
            const SizedBox(height: 24),
            const _PlatformNote(),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------- widgets

class _TrackingBanner extends StatelessWidget {
  const _TrackingBanner({required this.isTracking});

  final bool isTracking;

  @override
  Widget build(BuildContext context) {
    final color = isTracking ? Colors.green : Colors.grey;
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 28, horizontal: 20),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: color.withValues(alpha: 0.4)),
      ),
      child: Column(
        children: [
          Icon(
            isTracking ? Icons.my_location : Icons.location_disabled,
            size: 56,
            color: color.shade700,
          ),
          const SizedBox(height: 12),
          Text(
            isTracking ? 'Tracking active' : 'Not tracking',
            style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                  color: color.shade800,
                  fontWeight: FontWeight.bold,
                ),
          ),
          const SizedBox(height: 4),
          Text(
            isTracking
                ? 'Sending your location every 10 seconds'
                : 'Grant location permission to begin',
            style: Theme.of(context).textTheme.bodyMedium,
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }
}

class _PermissionCard extends StatelessWidget {
  const _PermissionCard({
    required this.status,
    required this.busy,
    required this.onGrant,
    required this.onUpgrade,
    required this.onSettings,
  });

  final TrackingStatus status;
  final bool busy;
  final VoidCallback onGrant;
  final VoidCallback onUpgrade;
  final VoidCallback onSettings;

  @override
  Widget build(BuildContext context) {
    final permission = status.permission;

    final (String? actionLabel, VoidCallback? action, String? hint) = switch (permission) {
      LocationPermission.notRequested || LocationPermission.denied => (
          'Grant permission',
          onGrant,
          null,
        ),
      LocationPermission.deniedForever => (
          'Open Settings',
          onSettings,
          'Permission was permanently denied — it can only be re-enabled in Settings.',
        ),
      LocationPermission.whileInUse => (
          Platform.isIOS ? 'Allow "Always"' : 'Allow all the time',
          onUpgrade,
          Platform.isIOS
              ? 'Without "Always", tracking stops when the app is force-quit and cannot restart.'
              : 'Without background access, tracking will not resume after a reboot.',
        ),
      LocationPermission.always => (null, null, null),
    };

    return _Card(
      title: 'Permission',
      trailing: _Pill(
        text: permission.label,
        color: permission == LocationPermission.always
            ? Colors.green
            : permission.canTrack
                ? Colors.orange
                : Colors.red,
      ),
      children: [
        if (hint != null) ...[
          Text(hint, style: Theme.of(context).textTheme.bodySmall),
          const SizedBox(height: 10),
        ],
        if (actionLabel != null)
          SizedBox(
            width: double.infinity,
            child: FilledButton.tonal(
              onPressed: busy ? null : action,
              child: Text(actionLabel),
            ),
          ),
      ],
    );
  }
}

class _LastFixCard extends StatelessWidget {
  const _LastFixCard({required this.status});

  final TrackingStatus status;

  @override
  Widget build(BuildContext context) {
    if (!status.hasFix) {
      return const _Card(
        title: 'Last location',
        children: [Text('No fix yet')],
      );
    }
    return _Card(
      title: 'Last location',
      trailing: _Pill(text: _age(status.lastFixAt), color: Colors.blueGrey),
      children: [
        _Row('Latitude', status.latitude!.toStringAsFixed(6)),
        _Row('Longitude', status.longitude!.toStringAsFixed(6)),
        if (status.accuracy != null)
          _Row('Accuracy', '±${status.accuracy!.toStringAsFixed(1)} m'),
      ],
    );
  }
}

class _UploadCard extends StatelessWidget {
  const _UploadCard({required this.status});

  final TrackingStatus status;

  @override
  Widget build(BuildContext context) {
    return _Card(
      title: 'Uploads',
      children: [
        _Row('Last success', _age(status.lastSuccessAt)),
        _Row('Delivered', '${status.successCount}'),
        _Row('Failed', '${status.failureCount}'),
        if (status.lastError != null) ...[
          const SizedBox(height: 6),
          Text(
            'Last error: ${status.lastError}',
            style: Theme.of(context)
                .textTheme
                .bodySmall
                ?.copyWith(color: Theme.of(context).colorScheme.error),
          ),
        ],
      ],
    );
  }
}

class _BatteryCard extends StatelessWidget {
  const _BatteryCard({required this.busy, required this.onFix});

  final bool busy;
  final VoidCallback onFix;

  @override
  Widget build(BuildContext context) {
    return _Card(
      title: 'Battery optimisation',
      trailing: const _Pill(text: 'Restricted', color: Colors.orange),
      children: [
        Text(
          'Android may stop tracking to save power. Exempting the app is the single biggest '
          'reliability win on Xiaomi, Oppo, Vivo and Huawei devices.',
          style: Theme.of(context).textTheme.bodySmall,
        ),
        const SizedBox(height: 10),
        SizedBox(
          width: double.infinity,
          child: FilledButton.tonal(
            onPressed: busy ? null : onFix,
            child: const Text('Disable optimisation'),
          ),
        ),
      ],
    );
  }
}

class _PrimaryAction extends StatelessWidget {
  const _PrimaryAction({
    required this.status,
    required this.busy,
    required this.onStart,
    required this.onStop,
  });

  final TrackingStatus status;
  final bool busy;
  final VoidCallback onStart;
  final VoidCallback onStop;

  @override
  Widget build(BuildContext context) {
    if (!status.permission.canTrack) return const SizedBox.shrink();

    return SizedBox(
      width: double.infinity,
      height: 52,
      child: status.isTracking
          ? FilledButton(
              style: FilledButton.styleFrom(
                backgroundColor: Theme.of(context).colorScheme.error,
              ),
              onPressed: busy ? null : onStop,
              child: const Text('Stop tracking'),
            )
          : FilledButton(
              onPressed: busy ? null : onStart,
              child: const Text('Start tracking'),
            ),
    );
  }
}

class _PlatformNote extends StatelessWidget {
  const _PlatformNote();

  @override
  Widget build(BuildContext context) {
    final text = Platform.isIOS
        ? 'iOS cannot resume 10-second tracking immediately after a force-quit. The app is '
            'relaunched by a significant location change (roughly every 500 m), then full '
            'tracking resumes. This is an Apple restriction.'
        : 'Tracking runs in a foreground service, so it continues in the background, with the '
            'screen off, after the app is swiped away, and across reboots.';

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Icon(Icons.info_outline, size: 16, color: Colors.grey),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            text,
            style: Theme.of(context)
                .textTheme
                .bodySmall
                ?.copyWith(color: Colors.grey.shade600),
          ),
        ),
      ],
    );
  }
}

// ------------------------------------------------------------- primitives

class _Card extends StatelessWidget {
  const _Card({required this.title, required this.children, this.trailing});

  final String title;
  final List<Widget> children;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    title,
                    style: Theme.of(context)
                        .textTheme
                        .titleMedium
                        ?.copyWith(fontWeight: FontWeight.w600),
                  ),
                ),
                ?trailing,
              ],
            ),
            const SizedBox(height: 12),
            ...children,
          ],
        ),
      ),
    );
  }
}

class _Row extends StatelessWidget {
  const _Row(this.label, this.value);

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label, style: Theme.of(context).textTheme.bodyMedium),
          Text(
            value,
            style: Theme.of(context)
                .textTheme
                .bodyMedium
                ?.copyWith(fontFeatures: const [FontFeature.tabularFigures()]),
          ),
        ],
      ),
    );
  }
}

class _Pill extends StatelessWidget {
  const _Pill({required this.text, required this.color});

  final String text;
  final MaterialColor color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w600,
          color: color.shade800,
        ),
      ),
    );
  }
}

String _age(DateTime? time) {
  if (time == null) return 'never';
  final seconds = DateTime.now().difference(time).inSeconds;
  if (seconds < 2) return 'just now';
  if (seconds < 60) return '${seconds}s ago';
  final minutes = seconds ~/ 60;
  if (minutes < 60) return '${minutes}m ago';
  return '${minutes ~/ 60}h ago';
}
