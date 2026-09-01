import '../models/app_user.dart';

abstract interface class ProfileRepository {
  Future<AppUser> me();

  Future<AppUser> updateName(String name);

  /// [path] is a local file path from the image picker; the real implementation uploads it
  /// to storage and stores the resulting public URL.
  Future<AppUser> updatePhoto(String path);
}
