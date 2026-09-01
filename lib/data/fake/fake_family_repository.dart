import 'dart:async';
import 'dart:math';

import 'package:latlong2/latlong.dart';

import '../../app/assets.dart';
import '../models/tracked_person.dart';
import '../repositories/family_repository.dart';
import 'fake_session.dart';

/// Keeps a list in memory and nudges every position every few seconds, so the map markers
/// drift and "Updated now" stays honest — the same shape the Supabase poll has.
///
/// It also walks the real state machine: a person added here starts as [ShareStatus.pending]
/// and only becomes [ShareStatus.sharing] a few seconds later, so the accept flow is
/// exercised on the no-backend path instead of being skipped.
class FakeFamilyRepository implements FamilyRepository {
  FakeFamilyRepository(this._session);

  final FakeSession _session;
  final _random = Random(360);
  final _controller = StreamController<FamilySnapshot>.broadcast();
  Timer? _drift;

  @override
  Stream<FamilySnapshot> watch() {
    _drift ??= Timer.periodic(const Duration(seconds: 5), (_) => _tick());
    // Late subscribers need the current value, not just the next change.
    scheduleMicrotask(_emit);
    return _controller.stream;
  }

  @override
  Future<FamilySnapshot> load() async {
    await FakeSession.latency(350);
    return _snapshot();
  }

  @override
  Future<AddPersonResult> addPerson({
    required String name,
    required String phone,
  }) async {
    await FakeSession.latency(500);
    if (_session.people.length >= FamilyRepository.maxPeople) {
      throw StateError('You can add up to ${FamilyRepository.maxPeople} people');
    }

    // A number ending in 0 is treated as not-yet-installed, so the invite branch is reachable
    // without a second device. Deliberately a fixed rule rather than a random one: a flow that
    // only sometimes happens is a flow nobody tests.
    final digits = phone.replaceAll(RegExp(r'\D'), '');
    final needsInvite = digits.endsWith('0');
    final label = name.trim().isEmpty ? 'They' : name.trim();

    if (needsInvite) {
      _session.people.add(
        TrackedPerson(
          id: 'invite:$digits',
          name: name.trim(),
          avatarAsset: Img.avatarFor(digits),
          status: ShareStatus.invited,
          phone: digits,
        ),
      );
      _emit();
      return (
        person: null,
        shareText:
            '$label wants to stay connected with you on Loc360: https://loc360.app/invite/demo',
        message: '$label isn\'t on Loc360 yet',
        snapshot: _snapshot(),
      );
    }

    // Reuse the seeded designs first so the screen matches Figma, then synthesise.
    final seed = FakeSession.seedPeople
        .where((p) => _session.people.every((existing) => existing.id != p.id))
        .firstOrNull;

    // Added straight into the connected state. There is no second device here to tap Accept,
    // and a person stuck on "waiting" forever would be worse than skipping the step — the
    // pending and invited cards are still reachable, via the seeded request and the invite
    // branch above.
    final person = seed ??
        TrackedPerson(
          id: 'p${DateTime.now().millisecondsSinceEpoch}',
          name: name.trim().isEmpty ? 'New Person' : name.trim(),
          avatarAsset: Img.avatarFor(digits),
          status: ShareStatus.sharing,
          position: _jitter(FakeSession.home, 0.01),
          distanceKm: 0.5 + _random.nextDouble() * 4,
          updatedAt: DateTime.now(),
          placeLabel: 'Congress Ave',
          phone: digits,
        );

    _session.people.add(person);

    // One inbound request, once, so the Accept / Decline card is exercised on this path too.
    if (!_seededRequest) {
      _seededRequest = true;
      _session.requests.add(FakeSession.seedRequest);
    }

    _emit();

    return (
      person: person,
      shareText: null,
      message: 'Your location is now shared with ${person.name}',
      snapshot: _snapshot(),
    );
  }

  /// The demo request is offered once per run, not once per person added.
  bool _seededRequest = false;

  @override
  Future<void> respond({required String personId, required bool accept}) async {
    await FakeSession.latency(250);
    _session.requests.removeWhere((p) => p.id == personId);
    _emit();
  }

  @override
  Future<void> removePerson(TrackedPerson person) async {
    await FakeSession.latency(250);
    _session.people.removeWhere((p) => p.id == person.id);
    _emit();
  }

  @override
  Future<String> triggerAction(PersonAction action, TrackedPerson person) async {
    await FakeSession.latency(300);
    return switch (action) {
      PersonAction.beep => 'Beeping ${person.name}\'s phone',
      PersonAction.call => 'Calling ${person.name}…',
      PersonAction.shareLive => 'You\'re already sharing your live location with ${person.name}',
      PersonAction.shareCurrent => 'Sent your current location to ${person.name}',
    };
  }

  void _tick() {
    if (_session.people.isEmpty) return;
    for (var i = 0; i < _session.people.length; i++) {
      final person = _session.people[i];
      // Only a connected person has a position to drift.
      if (person.status != ShareStatus.sharing || person.position == null) continue;
      _session.people[i] = person.copyWith(
        position: _jitter(person.position!, 0.0006),
        distanceKm: ((person.distanceKm ?? 2) + (_random.nextDouble() - 0.5) * 0.2)
            .clamp(0.2, 9.9),
        updatedAt: DateTime.now(),
      );
    }
    _emit();
  }

  LatLng _jitter(LatLng from, double spread) => LatLng(
        from.latitude + (_random.nextDouble() - 0.5) * spread,
        from.longitude + (_random.nextDouble() - 0.5) * spread,
      );

  FamilySnapshot _snapshot() => (
        people: List.unmodifiable(_session.people),
        requests: List.unmodifiable(_session.requests),
        offline: false,
      );

  void _emit() {
    if (!_controller.isClosed) _controller.add(_snapshot());
  }

  void dispose() {
    _drift?.cancel();
    _controller.close();
  }
}
