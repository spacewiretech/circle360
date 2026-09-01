import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/location/location_controller.dart';
import '../../data/models/tracked_person.dart';
import '../../data/providers.dart';
import '../../data/repositories/family_repository.dart';
import '../../data/supabase/edge_functions.dart';
import '../../data/supabase/supabase_family_repository.dart';

@immutable
class HomeState {
  const HomeState({
    this.people = const [],
    this.requests = const [],
    this.expandedId,
    this.loading = true,
    this.offline = false,
    this.message,
    this.maxPeople = FamilyRepository.maxPeople,
  });

  final List<TrackedPerson> people;

  /// People asking to see this account. Rendered above the list, not inside it.
  final List<TrackedPerson> requests;

  /// The card currently open, and therefore the person focused on the map.
  final String? expandedId;
  final bool loading;

  /// The last refresh failed. [people] is then the last known good set rather than live.
  final bool offline;

  /// One-shot confirmation for the last action, consumed by the view as a SnackBar.
  final String? message;

  final int maxPeople;

  bool get isEmpty => !loading && people.isEmpty && requests.isEmpty;

  bool get canAddMore => people.length < maxPeople;

  TrackedPerson? get expanded => people.where((p) => p.id == expandedId).firstOrNull;

  /// Only connected people with an actual fix belong on the map — a pending or invited person
  /// has no position, and drawing one at (0, 0) would put them off the coast of Africa.
  List<TrackedPerson> get mappable =>
      people.where((p) => p.isMappable).toList(growable: false);

  HomeState copyWith({
    List<TrackedPerson>? people,
    List<TrackedPerson>? requests,
    String? expandedId,
    bool clearExpanded = false,
    bool? loading,
    bool? offline,
    String? message,
    bool clearMessage = false,
    int? maxPeople,
  }) {
    return HomeState(
      people: people ?? this.people,
      requests: requests ?? this.requests,
      expandedId: clearExpanded ? null : (expandedId ?? this.expandedId),
      loading: loading ?? this.loading,
      offline: offline ?? this.offline,
      message: clearMessage ? null : (message ?? this.message),
      maxPeople: maxPeople ?? this.maxPeople,
    );
  }
}

class HomeViewModel extends Notifier<HomeState> {
  StreamSubscription<FamilySnapshot>? _subscription;

  @override
  HomeState build() {
    final repository = ref.watch(familyRepositoryProvider);

    // Distances are measured from this device, so the repository has to be told where that is.
    //
    // `listen`, emphatically not `watch`: this device's position changes every 10 seconds, and
    // watching it would rebuild the whole Notifier on each fix — resetting the list to empty
    // and collapsing whatever card the user had open, twice a minute.
    if (repository is SupabaseFamilyRepository) {
      ref.listen(
        locationControllerProvider.select((s) => s.here),
        (_, here) => repository.here = here,
        fireImmediately: true,
      );
    }

    _subscription = repository.watch().listen(
      (snapshot) {
        state = state.copyWith(
          people: snapshot.people,
          requests: snapshot.requests,
          offline: snapshot.offline,
          loading: false,
          // A person removed elsewhere must not stay expanded.
          clearExpanded: snapshot.people.every((p) => p.id != state.expandedId),
          maxPeople: repository is SupabaseFamilyRepository ? repository.maxPeople : null,
        );
      },
      // An expired session surfaces here; EntitlementGate is what routes on it, so this only
      // has to avoid killing the stream.
      onError: (Object error) => debugPrint('[home] people stream: $error'),
    );
    ref.onDispose(() => _subscription?.cancel());

    return const HomeState();
  }

  FamilyRepository get _family => ref.read(familyRepositoryProvider);

  void toggle(String personId) {
    final person = state.people.where((p) => p.id == personId).firstOrNull;
    // Only a connected person has actions worth opening to.
    if (person == null || person.status != ShareStatus.sharing) return;

    state = state.expandedId == personId
        ? state.copyWith(clearExpanded: true)
        : state.copyWith(expandedId: personId);
  }

  /// Adds a number. Returns the result so the view can open the share sheet for an invite —
  /// that has to happen from the widget layer, in response to the user's own tap.
  Future<AddPersonResult?> addPerson({
    required String name,
    required String phone,
  }) async {
    try {
      final result = await _family.addPerson(name: name, phone: phone);
      // Applied from the result rather than waited for on the stream, so the list moves on the
      // same frame as the tap instead of a poll interval later.
      state = state.copyWith(
        people: result.snapshot.people,
        requests: result.snapshot.requests,
        loading: false,
        message: result.message,
      );
      return result;
    } on EdgeError catch (e) {
      state = state.copyWith(message: e.message);
      return null;
    } on StateError catch (e) {
      state = state.copyWith(message: e.message);
      return null;
    }
  }

  Future<void> respond({required String personId, required bool accept}) async {
    // Drop it from the list on the same frame as the tap; the stream reconciles a moment later.
    state = state.copyWith(
      requests: state.requests.where((p) => p.id != personId).toList(),
    );
    try {
      await _family.respond(personId: personId, accept: accept);
      state = state.copyWith(
        message: accept ? 'You\'re now sharing your location' : 'Request declined',
      );
    } on EdgeError catch (e) {
      state = state.copyWith(message: e.message);
    }
  }

  Future<void> removePerson(TrackedPerson person) async {
    state = state.copyWith(
      people: state.people.where((p) => p.id != person.id).toList(),
      clearExpanded: state.expandedId == person.id,
    );
    try {
      await _family.removePerson(person);
      state = state.copyWith(
        message: person.status == ShareStatus.invited
            ? 'Invite withdrawn'
            : 'You and ${person.name} are no longer sharing',
      );
    } on EdgeError catch (e) {
      state = state.copyWith(message: e.message);
    }
  }

  Future<void> runAction(PersonAction action, TrackedPerson person) async {
    final message = await _family.triggerAction(action, person);
    state = state.copyWith(message: message);
  }

  void consumeMessage() => state = state.copyWith(clearMessage: true);
}

final homeViewModelProvider =
    NotifierProvider<HomeViewModel, HomeState>(HomeViewModel.new);
