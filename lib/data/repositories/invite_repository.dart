/// Sending an invite to someone who is not on Loc360 yet.
///
/// Deliberately separate from `FamilyRepository.addPerson`, which creates a tracked person
/// straight away — an invite stays pending until the other side accepts it.
abstract interface class InviteRepository {
  /// [viaCode] is the code from the deeplink that brought the user here, so the backend can
  /// attribute the invite chain.
  Future<void> sendInvite({required String phone, String? viaCode});
}
