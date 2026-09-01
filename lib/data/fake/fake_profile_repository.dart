import '../../app/assets.dart';
import '../models/app_user.dart';
import '../repositories/profile_repository.dart';
import 'fake_session.dart';

class FakeProfileRepository implements ProfileRepository {
  FakeProfileRepository(this._session);

  final FakeSession _session;

  @override
  Future<AppUser> me() async {
    await FakeSession.latency(250);
    return _session.user ??
        const AppUser(id: 'local-user', phone: '', avatarAsset: Img.avatarMeLarge);
  }

  @override
  Future<AppUser> updateName(String name) async {
    await FakeSession.latency();
    final user = (await me()).copyWith(name: name.trim());
    _session.user = user;
    return user;
  }

  @override
  Future<AppUser> updatePhoto(String path) async {
    await FakeSession.latency(600);
    // No storage bucket yet — keep the bundled placeholder and pretend the upload worked.
    final user = await me();
    _session.user = user;
    return user;
  }
}
