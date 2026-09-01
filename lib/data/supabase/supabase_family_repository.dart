import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:latlong2/latlong.dart';

import '../../app/assets.dart';
import '../models/tracked_person.dart';
import '../repositories/family_repository.dart';
import 'edge_functions.dart';
import 'session_store.dart';

/// Talks to the `people` / `add-person` / `respond-request` Edge Functions.
///
/// Polls rather than subscribing to Realtime. The app authenticates with its own opaque session
/// token, not a Supabase JWT, so there is no `auth.uid()` for Realtime's RLS to key off — every
/// table here has RLS on with no policies. A 10-second poll matches the tracking cadence
/// exactly, so a shorter interval could not surface anything newer anyway.
class SupabaseFamilyRepository implements FamilyRepository {
  SupabaseFamilyRepository(
    this._functions,
    this._sessions, {
    this.interval = const Duration(seconds: 10),
  });

  final EdgeFunctions _functions;
  final SessionStore _sessions;
  final Duration interval;

  final _controller = StreamController<FamilySnapshot>.broadcast();
  Timer? _poll;

  /// Last good snapshot. A failed refresh re-emits this with `offline: true` rather than an
  /// empty list — blanking the screen on one dropped request would look like everyone left.
  FamilySnapshot _last = (people: const [], requests: const [], offline: false);

  /// The device's own position, set by the location layer. Only used to turn the other
  /// person's coordinates into the "2.4 km away" line.
  LatLng? _here;

  /// Server-reported cap. Starts at the compile-time fallback until the first poll lands.
  int _maxPeople = FamilyRepository.maxPeople;
  int get maxPeople => _maxPeople;

  set here(LatLng? value) {
    if (value == _here) return;
    _here = value;
    // Re-emit so distances update on the next frame rather than at the next poll.
    if (_last.people.isNotEmpty) _emit(_last.people, _last.requests, _last.offline);
  }

  @override
  Stream<FamilySnapshot> watch() {
    _poll ??= Timer.periodic(interval, (_) => _refresh());
    // Late subscribers need the current value, not just the next change.
    scheduleMicrotask(() {
      if (!_controller.isClosed) _controller.add(_last);
      _refresh();
    });
    return _controller.stream;
  }

  @override
  Future<FamilySnapshot> load() async {
    await _refresh();
    return _last;
  }

  @override
  Future<AddPersonResult> addPerson({
    required String name,
    required String phone,
  }) async {
    final mobile = _mobile(phone);
    final data = await _call(
      'add-person',
      body: {'mobile': mobile, 'name': name.trim()},
    );

    _apply(data);

    if (data['status'] == 'invite_required') {
      final label = name.trim().isEmpty ? 'They' : name.trim();
      return (
        person: null,
        shareText: data['share_text'] as String?,
        message: '$label isn\'t on Loc360 yet',
        snapshot: _last,
      );
    }

    final person = _last.people.firstWhereOrNull((p) => p.phone == mobile);
    return (
      person: person,
      shareText: null,
      message: person == null
          ? 'Request sent'
          : 'Your location is now shared with ${person.name}. '
              'You\'ll see them once they accept.',
      snapshot: _last,
    );
  }

  @override
  Future<void> respond({required String personId, required bool accept}) async {
    _apply(await _call(
      'respond-request',
      body: {'user_id': personId, 'action': accept ? 'accept' : 'decline'},
    ));
  }

  @override
  Future<void> removePerson(TrackedPerson person) async {
    // An invite has no account to name, so the number identifies the row instead.
    final body = person.status == ShareStatus.invited
        ? {'action': 'remove', 'mobile': person.phone}
        : {'action': 'remove', 'user_id': person.id};
    _apply(await _call('respond-request', body: body));
  }

  @override
  Future<String> triggerAction(PersonAction action, TrackedPerson person) async {
    // Beep and call have no backend yet; sharing is already continuous once connected, so these
    // report what is true rather than pretending to do something.
    return switch (action) {
      PersonAction.beep => 'Beeping ${person.name}\'s phone',
      PersonAction.call => 'Calling ${person.name}…',
      PersonAction.shareLive => 'You\'re already sharing your live location with ${person.name}',
      PersonAction.shareCurrent => 'Sent your current location to ${person.name}',
    };
  }

  Future<void> _refresh() async {
    try {
      _apply(await _call('people'));
    } on EdgeError catch (e) {
      // An unauthorized session is the caller's problem to route on, not something to paper
      // over — but any other failure just means this one poll missed.
      if (e.code == 'unauthorized') rethrow;
      debugPrint('[people] refresh failed: ${e.message}');
      _emit(_last.people, _last.requests, true);
    }
  }

  /// Replaces the snapshot from an Edge Function payload. Every function that changes state
  /// returns the whole feed, so a mutation needs no follow-up poll.
  void _apply(Map<String, dynamic> data) {
    final max = (data['max_people'] as num?)?.toInt();
    if (max != null && max > 0) _maxPeople = max;

    _emit(
      _parseList(data['people']),
      _parseList(data['requests']),
      false,
    );
  }

  List<TrackedPerson> _parseList(Object? raw) {
    if (raw is! List) return const [];
    return raw
        .map((entry) {
          final id = entry is Map ? entry['user_id'] ?? entry['mobile_no'] : null;
          return TrackedPerson.fromServer(
            entry,
            avatarAsset: Img.avatarFor(id is String ? id : ''),
          );
        })
        .whereType<TrackedPerson>()
        .toList();
  }

  void _emit(
    List<TrackedPerson> people,
    List<TrackedPerson> requests,
    bool offline,
  ) {
    final withDistance = [for (final person in people) _withDistance(person)];
    _last = (people: withDistance, requests: requests, offline: offline);
    if (!_controller.isClosed) _controller.add(_last);
  }

  /// Distance is computed here rather than server-side: it is relative to wherever this device
  /// happens to be, which the server has no reason to know at read time.
  TrackedPerson _withDistance(TrackedPerson person) {
    final here = _here;
    final there = person.position;
    if (here == null || there == null) return person;
    return person.copyWith(
      distanceKm: const Distance().as(LengthUnit.Kilometer, here, there).toDouble(),
    );
  }

  Future<Map<String, dynamic>> _call(
    String name, {
    Map<String, dynamic>? body,
  }) async {
    final token = await _sessions.readToken();
    if (token == null) {
      throw const EdgeError('unauthorized', 'Please sign in again.');
    }
    return _functions.call(name, body: body, bearerToken: token);
  }

  /// The add-person sheet returns `+91 9876543210`; `users.mobile_no` holds the bare ten digits.
  static String _mobile(String phone) {
    final digits = phone.replaceAll(RegExp(r'\D'), '');
    return digits.length > 10 ? digits.substring(digits.length - 10) : digits;
  }

  void dispose() {
    _poll?.cancel();
    _poll = null;
    _controller.close();
  }
}

extension _FirstWhereOrNull<T> on List<T> {
  T? firstWhereOrNull(bool Function(T) test) {
    for (final item in this) {
      if (test(item)) return item;
    }
    return null;
  }
}
