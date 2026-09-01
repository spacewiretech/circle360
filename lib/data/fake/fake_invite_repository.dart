import '../repositories/invite_repository.dart';
import 'fake_session.dart';

class FakeInviteRepository implements InviteRepository {
  /// Every invite sent this run, so a later screen can list them once that design exists.
  final List<({String phone, String? viaCode})> sent = [];

  @override
  Future<void> sendInvite({required String phone, String? viaCode}) async {
    await FakeSession.latency(500);
    sent.add((phone: phone, viaCode: viaCode));
  }
}
