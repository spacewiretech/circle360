import '../models/tracked_person.dart';

/// Everything the Home screen shows, in one value.
///
/// People and requests arrive together because they come from one backend call: split into two
/// streams they could disagree for a tick, and a person would briefly appear in both lists.
typedef FamilySnapshot = ({
  List<TrackedPerson> people,
  /// People asking the signed-in user to share back. Answered with [FamilyRepository.respond].
  List<TrackedPerson> requests,
  /// True when the last refresh failed. The people are then the last known good set, not live.
  bool offline,
});

/// What happened when a number was added.
///
/// A number with no account behind it cannot be connected to, only invited — so `addPerson`
/// has two genuinely different outcomes and the caller has to tell them apart.
typedef AddPersonResult = ({
  /// Set when the number belongs to an existing account and the connection was made.
  TrackedPerson? person,
  /// Set when the number has no account yet: the message to hand to the share sheet.
  String? shareText,
  /// Ready to show as-is.
  String message,
  /// The list as it now stands, so the caller updates on the same frame as the tap instead of
  /// waiting a stream turn — or, on the Supabase path, a whole poll interval.
  FamilySnapshot snapshot,
});

/// The people whose location this account can see, and the ones it has asked.
abstract interface class FamilyRepository {
  /// Fallback cap, used before `app_config.max_tracked_people` has been read.
  static const maxPeople = 3;

  /// Polls the backend while listened to. Emits the current snapshot immediately on subscribe,
  /// so a late subscriber does not wait a full interval for its first frame.
  Stream<FamilySnapshot> watch();

  Future<FamilySnapshot> load();

  /// [phone] is 10 digits, no country code — matching `users.mobile_no`.
  Future<AddPersonResult> addPerson({required String name, required String phone});

  /// Answers a request to share. Declining also ends the inbound share: someone who refuses a
  /// connection should not keep receiving the other person's location.
  Future<void> respond({required String personId, required bool accept});

  /// Ends a connection, or withdraws an invite that was never accepted.
  Future<void> removePerson(TrackedPerson person);

  /// Fires one of the four card actions. Returns the message to confirm it with.
  Future<String> triggerAction(PersonAction action, TrackedPerson person);
}
