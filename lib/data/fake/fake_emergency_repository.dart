import '../../app/assets.dart';
import '../models/emergency_contact.dart';
import '../repositories/emergency_repository.dart';
import 'fake_session.dart';

class FakeEmergencyRepository implements EmergencyRepository {
  FakeEmergencyRepository(this._session);

  final FakeSession _session;

  /// Avatars cycle through the bundled placeholders until photos come from the backend.
  static const _avatars = [Img.avatarMom, Img.avatarSister, Img.avatarMe];

  @override
  Future<List<EmergencyContact>> list() async {
    await FakeSession.latency(350);
    return List.unmodifiable(_session.emergencyContacts);
  }

  @override
  Future<EmergencyContact> add({required String name, required String phone}) async {
    await FakeSession.latency(450);
    if (_session.emergencyContacts.length >= EmergencyRepository.maxContacts) {
      throw StateError('You can add up to ${EmergencyRepository.maxContacts} people');
    }
    final contact = EmergencyContact(
      id: 'e${DateTime.now().millisecondsSinceEpoch}',
      name: name,
      phone: phone,
      avatarAsset: _avatars[_session.emergencyContacts.length % _avatars.length],
    );
    _session.emergencyContacts.add(contact);
    return contact;
  }

  @override
  Future<void> remove(String id) async {
    await FakeSession.latency(250);
    _session.emergencyContacts.removeWhere((c) => c.id == id);
  }
}
