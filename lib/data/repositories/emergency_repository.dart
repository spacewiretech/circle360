import '../models/emergency_contact.dart';

abstract interface class EmergencyRepository {
  /// Emergency contacts share the tracked-people cap of 3.
  static const maxContacts = 3;

  Future<List<EmergencyContact>> list();

  Future<EmergencyContact> add({required String name, required String phone});

  Future<void> remove(String id);
}
