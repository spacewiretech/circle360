import 'package:flutter/foundation.dart';

/// An invite carried into the app by a deeplink.
@immutable
class InviteLink {
  const InviteLink({required this.code, this.inviterName});

  /// Opaque token the backend will resolve to the inviting account.
  final String code;

  /// Optional display name of whoever sent the link. The design does not surface it, but it
  /// rides along so a later revision can.
  final String? inviterName;

  @override
  bool operator ==(Object other) =>
      other is InviteLink && other.code == code && other.inviterName == inviterName;

  @override
  int get hashCode => Object.hash(code, inviterName);

  @override
  String toString() => 'InviteLink($code, from: $inviterName)';
}
