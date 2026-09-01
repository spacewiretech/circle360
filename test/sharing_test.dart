import 'package:flutter_test/flutter_test.dart';

import 'package:loc_360/app/assets.dart';
import 'package:loc_360/data/location/location_controller.dart';
import 'package:loc_360/data/models/tracked_person.dart';
import 'package:loc_360/location_service.dart';

/// Covers the rules that decide who can be seen and whether this device is actually sharing.
///
/// These are the two places a bug would be invisible in review and serious in the field: a
/// person shown on the map who never agreed to be, or a user told they are being tracked when
/// nothing is leaving the phone.
void main() {
  TrackedPerson parse(Map<String, Object?> row) {
    final person = TrackedPerson.fromServer(row, avatarAsset: Img.avatarMe);
    expect(person, isNotNull, reason: 'row should have parsed: $row');
    return person!;
  }

  group('TrackedPerson.fromServer', () {
    test('a connected person carries their position', () {
      final person = parse({
        'user_id': 'u1',
        'name': 'Mom',
        'mobile_no': '8764597659',
        'status': 'sharing',
        'latitude': 12.971599,
        'longitude': 77.594566,
        'updated_at': DateTime.now().toUtc().toIso8601String(),
      });

      expect(person.status, ShareStatus.sharing);
      expect(person.position, isNotNull);
      expect(person.isMappable, isTrue);
      expect(person.isOnline, isTrue);
    });

    test('a pending person is never mappable, even if coordinates arrive', () {
      // The server does not send a position for a pending row, but the client must not depend
      // on that: showing someone who has not accepted would be the worst kind of bug here.
      final person = parse({
        'user_id': 'u2',
        'name': 'Dad',
        'mobile_no': '9812345670',
        'status': 'pending',
        'latitude': 12.9,
        'longitude': 77.5,
        'updated_at': DateTime.now().toUtc().toIso8601String(),
      });

      expect(person.status, ShareStatus.pending);
      expect(person.isMappable, isFalse);
      expect(person.subtitle, contains('Waiting for Dad'));
    });

    test('an unrecognised status falls back to pending, not sharing', () {
      final person = parse({
        'user_id': 'u3',
        'mobile_no': '9812345671',
        'status': 'something-a-newer-server-added',
        'latitude': 12.9,
        'longitude': 77.5,
      });

      expect(person.status, ShareStatus.pending);
      expect(person.isMappable, isFalse);
    });

    test('an invite has no account, so the number becomes its identity', () {
      final person = parse({
        'user_id': null,
        'name': 'Sister',
        'mobile_no': '9931145610',
        'status': 'invited',
      });

      expect(person.id, 'invite:9931145610');
      expect(person.isMappable, isFalse);
      expect(person.subtitle, contains('waiting to install'));
    });

    test('a nameless person falls back to their number rather than rendering blank', () {
      expect(parse({'user_id': 'u4', 'mobile_no': '9931145610', 'status': 'sharing'}).name,
          '9931145610');
    });

    test('a malformed row is dropped instead of blanking the list', () {
      expect(TrackedPerson.fromServer(null, avatarAsset: Img.avatarMe), isNull);
      expect(TrackedPerson.fromServer('nonsense', avatarAsset: Img.avatarMe), isNull);
      // No user id and no number: nothing to key a row on.
      expect(
        TrackedPerson.fromServer({'status': 'sharing'}, avatarAsset: Img.avatarMe),
        isNull,
      );
    });

    test('a stale fix reads as offline', () {
      final person = parse({
        'user_id': 'u5',
        'mobile_no': '9931145611',
        'status': 'sharing',
        'latitude': 12.9,
        'longitude': 77.5,
        'updated_at': DateTime.now()
            .toUtc()
            .subtract(const Duration(minutes: 30))
            .toIso8601String(),
      });

      expect(person.isOnline, isFalse);
      expect(person.freshness, contains('30m ago'));
      // Still mappable — a last known position is useful, it just must not claim to be live.
      expect(person.isMappable, isTrue);
    });

    test('a connected person with no fix yet says so', () {
      final person = parse({
        'user_id': 'u6',
        'mobile_no': '9931145612',
        'status': 'sharing',
      });

      expect(person.isMappable, isFalse);
      expect(person.subtitle, 'Location not shared yet');
    });

    test('the same id always gets the same face', () {
      expect(Img.avatarFor('u1'), Img.avatarFor('u1'));
      expect(Img.avatarPool, contains(Img.avatarFor('u1')));
    });
  });

  group('LocationState', () {
    LocationState stateFor(Map<String, Object?> snapshot) =>
        LocationState(status: TrackingStatus.fromMap(snapshot));

    test('sharing is live only when permitted, tracking AND credentialled', () {
      expect(
        stateFor({
          'permission': 'always',
          'isTracking': true,
          'uploadConfigured': true,
        }).isLive,
        isTrue,
      );

      // The failure this exists to catch: tracking is on and the UI would happily say so, but
      // nothing can be uploaded because no session token ever reached native.
      final noCredential = stateFor({
        'permission': 'always',
        'isTracking': true,
        'uploadConfigured': false,
      });
      expect(noCredential.isLive, isFalse);
      expect(noCredential.problem, contains('Sign in again'));

      final notTracking = stateFor({
        'permission': 'always',
        'isTracking': false,
        'uploadConfigured': true,
      });
      expect(notTracking.isLive, isFalse);
      expect(notTracking.problem, contains('paused'));
    });

    test('a hard denial reports the Settings-only state', () {
      final denied = stateFor({'permission': 'deniedForever', 'isTracking': false});
      expect(denied.isLive, isFalse);
      expect(denied.problem, contains('Settings'));
      // Answered, even though the answer was no — the priming screen must not re-trap them.
      expect(denied.hasAnswered, isTrue);
    });

    test('an unasked permission has not been answered', () {
      expect(const LocationState().hasAnswered, isFalse);
      expect(const LocationState().problem, isNotNull);
    });

    test('here is null until there is a fix', () {
      expect(const LocationState().here, isNull);
      expect(
        stateFor({'permission': 'always', 'latitude': 12.5, 'longitude': 77.5}).here,
        isNotNull,
      );
    });
  });
}
