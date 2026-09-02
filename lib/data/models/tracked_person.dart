import 'package:flutter/foundation.dart';
import 'package:latlong2/latlong.dart';

/// How far along the connection with this person is.
///
/// The three states share one row in the list because that is how the screen presents them, but
/// only [sharing] ever carries a position — the other two describe someone who has not agreed
/// to be seen, or does not have an account yet.
enum ShareStatus {
  /// Invited by phone number; no Loc360 account exists yet.
  invited,

  /// They have an account and have been asked, but have not accepted.
  pending,

  /// Connected. Their position is live.
  sharing;

  static ShareStatus parse(Object? raw) => switch (raw) {
        'sharing' => ShareStatus.sharing,
        'invited' => ShareStatus.invited,
        // Anything unrecognised is treated as pending, which shows no location. Failing towards
        // "not visible" is the safe way to be wrong about a permission.
        _ => ShareStatus.pending,
      };
}

/// A fix is considered live for this long after the server recorded it.
///
/// Measured against the server's `updated_at`, never the device's own timestamp — a wrong or
/// tampered device clock must not be able to make a stale position look current.
///
/// Sized against the native uploader's heartbeat, not against the fix interval: a stationary
/// device deliberately stops uploading and only reports every 15 minutes, so a 5-minute window
/// would mark everyone sitting still as offline. Three constants have to agree, and they live
/// in three languages — this one, `HEARTBEAT_MS` in `LocationTrackingService.kt`, and
/// `heartbeat` in `LocationTracker.swift`. Keep this the largest of the three.
const _freshFor = Duration(minutes: 20);

@immutable
class TrackedPerson {
  const TrackedPerson({
    required this.id,
    required this.name,
    required this.avatarAsset,
    required this.status,
    this.position,
    this.distanceKm,
    this.updatedAt,
    this.placeLabel = '',
    this.phone = '',
  });

  /// The other account's user id, or `invite:<mobile>` for someone who has not signed up yet —
  /// an invite has no account to point at, but the list still needs a stable key.
  final String id;
  final String name;
  final String avatarAsset;

  final ShareStatus status;

  /// Null until they have shared a fix. A connected person with no position yet is normal for
  /// the first few seconds after they accept.
  final LatLng? position;

  /// Computed on the device against its own last fix, so it is null until both ends are known.
  final double? distanceKm;

  /// Server clock for the last fix.
  final DateTime? updatedAt;

  /// Reverse-geocoded label shown in the chip over the marker, e.g. "High Street".
  final String placeLabel;
  final String phone;

  bool get hasPosition => position != null;

  /// Only a connected person with an actual fix belongs on the map.
  bool get isMappable => status == ShareStatus.sharing && position != null;

  /// Derived, not reported. A device that loses signal stops uploading rather than announcing
  /// that it went offline, so the absence of recent fixes is the only signal there is.
  bool get isOnline =>
      updatedAt != null && DateTime.now().difference(updatedAt!) < _freshFor;

  /// The second line of the card. Reads differently per state because "2.4 km away" would be a
  /// lie for someone who has not accepted yet.
  String get subtitle => switch (status) {
        ShareStatus.invited => 'Invited • waiting to install',
        ShareStatus.pending => 'Waiting for ${name.isEmpty ? 'them' : name} to accept',
        ShareStatus.sharing when updatedAt == null => 'Location not shared yet',
        ShareStatus.sharing when distanceKm == null => freshness,
        ShareStatus.sharing => '${distanceKm!.toStringAsFixed(1)} km away • $freshness',
      };

  String get freshness {
    if (updatedAt == null) return 'No location yet';
    final seconds = DateTime.now().difference(updatedAt!).inSeconds;
    if (seconds < 60) return 'Updated now';
    final minutes = seconds ~/ 60;
    if (minutes < 60) return 'Updated ${minutes}m ago';
    final hours = minutes ~/ 60;
    if (hours < 24) return 'Updated ${hours}h ago';
    return 'Updated ${hours ~/ 24}d ago';
  }

  /// Parses one entry from `people` or `add-person`.
  ///
  /// Returns null rather than throwing on a shape this build does not recognise: one malformed
  /// row must not blank out the whole list.
  static TrackedPerson? fromServer(Object? raw, {required String avatarAsset}) {
    if (raw is! Map) return null;

    final status = ShareStatus.parse(raw['status']);
    final userId = raw['user_id'] as String?;
    final phone = raw['mobile_no'] as String? ?? '';

    // An invite has no account behind it, so the number is the only stable identity available.
    final id = userId ?? (phone.isEmpty ? null : 'invite:$phone');
    if (id == null) return null;

    final latitude = (raw['latitude'] as num?)?.toDouble();
    final longitude = (raw['longitude'] as num?)?.toDouble();

    return TrackedPerson(
      id: id,
      name: (raw['name'] as String?)?.trim().isNotEmpty == true
          ? (raw['name'] as String).trim()
          : phone,
      avatarAsset: avatarAsset,
      status: status,
      position: latitude != null && longitude != null
          ? LatLng(latitude, longitude)
          : null,
      updatedAt: _parseDate(raw['updated_at']),
      phone: phone,
    );
  }

  static DateTime? _parseDate(Object? raw) {
    if (raw is! String || raw.isEmpty) return null;
    return DateTime.tryParse(raw)?.toLocal();
  }

  /// Value equality, because the list is rebuilt from scratch on every 10-second poll.
  ///
  /// Without this, `select((s) => s.expanded)` compares by reference and reports a change on
  /// every poll even when nothing moved — which is what used to re-open the Home sheet and
  /// reset the map's zoom under the user twice a minute.
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is TrackedPerson &&
          other.id == id &&
          other.name == name &&
          other.avatarAsset == avatarAsset &&
          other.status == status &&
          other.position == position &&
          other.distanceKm == distanceKm &&
          other.updatedAt == updatedAt &&
          other.placeLabel == placeLabel &&
          other.phone == phone;

  @override
  int get hashCode => Object.hash(
        id,
        name,
        avatarAsset,
        status,
        position,
        distanceKm,
        updatedAt,
        placeLabel,
        phone,
      );

  TrackedPerson copyWith({
    String? name,
    ShareStatus? status,
    LatLng? position,
    double? distanceKm,
    DateTime? updatedAt,
    String? placeLabel,
  }) {
    return TrackedPerson(
      id: id,
      name: name ?? this.name,
      avatarAsset: avatarAsset,
      status: status ?? this.status,
      position: position ?? this.position,
      distanceKm: distanceKm ?? this.distanceKm,
      updatedAt: updatedAt ?? this.updatedAt,
      placeLabel: placeLabel ?? this.placeLabel,
      phone: phone,
    );
  }
}

/// The four actions offered when a person's card is expanded.
enum PersonAction {
  beep('Beep sound'),
  call('One-Tap Call'),
  shareLive('Share Live Location'),
  shareCurrent('Share Current Location');

  const PersonAction(this.label);

  final String label;

  /// Whether the tile is offered on a card yet.
  ///
  /// Beep has to ring *the other person's* phone, which needs a push channel — there is no
  /// FCM/APNs wiring in the app at all. Rather than show a confirmation for something that
  /// never happened, the tile is hidden until that exists. Everything behind it — the icon,
  /// the labels, the `triggerAction` branch — is deliberately left in place, so turning it
  /// back on is this one line.
  bool get isAvailable => this != PersonAction.beep;

  /// The actions a card actually renders. Use this rather than [values] in the UI.
  static List<PersonAction> get available =>
      values.where((action) => action.isAvailable).toList(growable: false);

  /// The label is split across two lines in the design.
  (String, String) get labelLines => switch (this) {
        PersonAction.beep => ('Beep', 'sound'),
        PersonAction.call => ('One-Tap', 'Call'),
        PersonAction.shareLive => ('Share Live', 'Location'),
        PersonAction.shareCurrent => ('Share Current', 'Location'),
      };
}
