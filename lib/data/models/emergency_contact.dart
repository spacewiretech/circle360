import 'package:flutter/foundation.dart';

@immutable
class EmergencyContact {
  const EmergencyContact({
    required this.id,
    required this.name,
    required this.phone,
    this.avatarAsset,
  });

  final String id;
  final String name;

  /// Displayed as typed by the user, e.g. "+91 8764597659".
  final String phone;
  final String? avatarAsset;
}
