import 'package:latlong2/latlong.dart';

import '../../app/assets.dart';
import '../models/app_user.dart';
import '../models/emergency_contact.dart';
import '../models/tracked_person.dart';

/// In-memory stand-in for the Supabase tables, shared by every fake repository so the
/// screens stay consistent with one another for the length of a run.
///
/// Nothing here survives a restart — that is deliberate, it keeps the onboarding flow
/// walkable on every launch.
class FakeSession {
  FakeSession._();

  static final instance = FakeSession._();

  /// Downtown Austin — matches the map artwork in the Figma frames.
  static const home = LatLng(30.2672, -97.7431);

  AppUser? user;

  final List<TrackedPerson> people = [];

  /// People asking this account to share back. Seeded on reset so the accept flow is reachable
  /// on the no-backend path without a second device.
  final List<TrackedPerson> requests = [];

  final List<EmergencyContact> emergencyContacts = [];

  /// The people the fake "invite" flow can pull from, in order.
  static List<TrackedPerson> get seedPeople => <TrackedPerson>[
        TrackedPerson(
          id: 'mom',
          name: 'Mom',
          avatarAsset: Img.avatarMom,
          status: ShareStatus.sharing,
          position: const LatLng(30.2705, -97.7395),
          distanceKm: 2.4,
          updatedAt: DateTime.now(),
          placeLabel: 'High Street',
          phone: '8764597659',
        ),
        TrackedPerson(
          id: 'sister',
          name: 'Sister',
          avatarAsset: Img.avatarSister,
          status: ShareStatus.sharing,
          position: const LatLng(30.2641, -97.7488),
          distanceKm: 1.6,
          updatedAt: DateTime.now(),
          placeLabel: 'Riverside Dr',
          phone: '9931145610',
        ),
      ];

  /// One inbound request, so the Accept / Decline card can be exercised.
  static TrackedPerson get seedRequest => TrackedPerson(
        id: 'dad',
        name: 'Dad',
        avatarAsset: Img.avatarMe,
        status: ShareStatus.pending,
        phone: '9812345670',
      );

  /// Simulated network latency, so loading states are exercised rather than skipped.
  static Future<void> latency([int ms = 400]) =>
      Future<void>.delayed(Duration(milliseconds: ms));

  void reset() {
    user = null;
    people.clear();
    // Left empty so a fresh run still lands on the designed empty-home frame; the fake family
    // repository seeds one request after the first person is added.
    requests.clear();
    emergencyContacts.clear();
  }
}
