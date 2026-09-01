import 'package:flutter_test/flutter_test.dart';

import 'package:loc_360/data/models/app_user.dart';
import 'package:loc_360/data/repositories/app_config_repository.dart';
import 'package:loc_360/data/repositories/auth_repository.dart';
import 'package:loc_360/data/supabase/edge_functions.dart';
import 'package:loc_360/data/supabase/session_store.dart';
import 'package:loc_360/data/supabase/supabase_app_config_repository.dart';
import 'package:loc_360/data/supabase/supabase_auth_repository.dart';

/// Covers the seam between the app and the Edge Functions: that every documented error code
/// maps onto the exception the OTP screen already knows how to render, and that a session is
/// stored, reused and dropped at the right moments.
void main() {
  group('app config', () {
    test('typed reads fall back to the bundled defaults', () {
      const config = <String, String>{'otp_length': '4', 'env': 'staging'};

      expect(config.configString('env'), 'staging');
      expect(config.configInt('otp_length'), 4);
      // Absent from the map, so the bundled default answers.
      expect(config.configInt('max_tracked_people'), 3);
      expect(config.configString('min_supported_version'), '1.0.0');
    });

    test('a garbled value does not crash a screen', () {
      const config = <String, String>{'otp_length': 'six'};
      expect(config.configInt('otp_length'), 6, reason: 'falls back to the default');
      expect(config.configString('nothing_here'), '');
      expect(config.configFlag('nothing_here'), isFalse);
    });

    test('the fake repository layers overrides over the defaults', () async {
      const repository = FakeAppConfigRepository({'env': 'test'});
      final config = await repository.load();

      expect(config['env'], 'test');
      expect(config['otp_length'], '6');
    });
  });

  group('SupabaseAuthRepository', () {
    late _FakeEdgeFunctions functions;
    late _MemorySessionStore sessions;
    late SupabaseAuthRepository repository;

    setUp(() {
      functions = _FakeEdgeFunctions();
      sessions = _MemorySessionStore();
      repository = SupabaseAuthRepository(functions, sessions);
    });

    // What `verify-otp` returns for a brand new signup: on trial, but with no trial_ends_at,
    // because nothing has been paid yet.
    const userRow = {
      'user_id': '11111111-1111-1111-1111-111111111111',
      'mobile_no': '9931145610',
      'name': null,
      'payment_type': 'trial',
      'trial_ends_at': null,
      'current_period_end': null,
      'entitled': false,
    };

    test('verifying stores the session and returns the new user', () async {
      functions.responses['verify-otp'] = {'user': userRow, 'token': 'secret-token'};

      final user = await repository.verifyOtp(phone: '9931145610', code: '123456');

      expect(user.phone, '9931145610');
      expect(user.hasName, isFalse, reason: 'name is collected on the next screen');
      // A signup that has not paid the ₹3 has no trial yet, so the paywall still shows.
      expect(user.entitled, isFalse);
      expect(user.paymentType, PaymentType.trial);
      expect(await sessions.readToken(), 'secret-token');
    });

    test('entitlement comes from the server, not from payment_type', () async {
      // The server is the only thing that applies the grace window, so the client takes its
      // answer verbatim — a lapsed date with entitled:true is the backend saying "still in
      // grace", and second-guessing it here would lock out a user mid-settlement.
      functions.responses['verify-otp'] = {
        'user': {
          ...userRow,
          'trial_ends_at': '2026-08-30T00:00:00Z',
          'entitled': true,
        },
        'token': 't',
      };

      final user = await repository.verifyOtp(phone: '9931145610', code: '123456');
      expect(user.entitled, isTrue);
      expect(user.isSubscribed, isTrue, reason: 'the legacy getter tracks entitlement');
    });

    test('an active plan whose period has lapsed is not entitled', () async {
      functions.responses['verify-otp'] = {
        'user': {
          ...userRow,
          'payment_type': 'active',
          'current_period_end': '2026-01-01T00:00:00Z',
          'entitled': false,
        },
        'token': 't',
      };

      final user = await repository.verifyOtp(phone: '9931145610', code: '123456');
      expect(user.entitled, isFalse, reason: 'a failed renewal must reach the paywall');
      expect(user.paymentType, PaymentType.active);
    });

    test('a payment_type this build does not know falls back to the paywall', () async {
      functions.responses['verify-otp'] = {
        'user': {...userRow, 'payment_type': 'some_future_state'},
        'token': 't',
      };

      final user = await repository.verifyOtp(phone: '9931145610', code: '123456');
      expect(user.paymentType, PaymentType.trial);
      expect(user.entitled, isFalse);
    });

    test('each error code becomes the exception the OTP screen handles', () async {
      final cases = <String, Matcher>{
        'invalid_otp': isA<InvalidOtpException>(),
        'otp_expired': isA<OtpExpiredException>(),
        'throttled': isA<OtpSendException>(),
        'send_failed': isA<OtpSendException>(),
        'server_error': isA<OtpSendException>(),
      };

      for (final entry in cases.entries) {
        functions.errors['verify-otp'] = EdgeError(entry.key, 'message for ${entry.key}');
        await expectLater(
          repository.verifyOtp(phone: '9931145610', code: '123456'),
          throwsA(entry.value),
          reason: entry.key,
        );
      }
    });

    test('a transport failure surfaces the message the function never sent', () async {
      functions.errors['send-otp'] = const EdgeError(null, 'No internet connection.');

      await expectLater(
        repository.sendOtp('9931145610'),
        throwsA(isA<OtpSendException>()
            .having((e) => e.message, 'message', 'No internet connection.')),
      );
    });

    test('saving the name sends the session token, not a user id', () async {
      await sessions.save(
        token: 'secret-token',
        user: const AppUser(id: 'u', phone: '9931145610'),
      );
      functions.responses['update-profile'] = {
        'user': {...userRow, 'name': 'Ayush'},
      };

      final user = await repository.saveName('  Ayush  ');

      expect(user.name, 'Ayush');
      expect(functions.tokensSeen['update-profile'], 'secret-token');
      // The id is never in the body — the server derives it from the token.
      expect(functions.bodiesSeen['update-profile'], {'name': 'Ayush'});
    });

    test('saving a name with no session refuses rather than calling out', () async {
      await expectLater(repository.saveName('Ayush'), throwsA(isA<OtpSendException>()));
      expect(functions.calls, isEmpty);
    });

    group('currentUser', () {
      test('is null with no stored session, without calling the backend', () async {
        expect(await repository.currentUser(), isNull);
        expect(functions.calls, isEmpty);
      });

      test('a rejected session is cleared so it cannot be reused', () async {
        await sessions.save(
          token: 'revoked',
          user: const AppUser(id: 'u', phone: '9931145610'),
        );
        functions.errors['me'] = const EdgeError('unauthorized', 'Please sign in again.');

        expect(await repository.currentUser(), isNull);
        expect(await sessions.readToken(), isNull);
      });

      test('an unreachable backend falls back to the cached user', () async {
        await sessions.save(
          token: 'good',
          user: const AppUser(id: 'u', phone: '9931145610', name: 'Ayush'),
        );
        functions.errors['me'] = const EdgeError(null, 'No internet connection.');

        final user = await repository.currentUser();

        expect(user?.name, 'Ayush', reason: 'a flaky network must not sign the user out');
        expect(await sessions.readToken(), 'good');
      });
    });

    test('signing out clears the session even when the call fails', () async {
      await sessions.save(
        token: 'good',
        user: const AppUser(id: 'u', phone: '9931145610'),
      );
      functions.errors['me'] = const EdgeError(null, 'offline');

      await repository.signOut();

      expect(await sessions.readToken(), isNull);
      expect(await sessions.readCachedUser(), isNull);
    });
  });
}

class _FakeEdgeFunctions implements EdgeFunctions {
  final responses = <String, Map<String, dynamic>>{};
  final errors = <String, EdgeError>{};
  final calls = <String>[];
  final bodiesSeen = <String, Map<String, dynamic>?>{};
  final tokensSeen = <String, String?>{};

  @override
  Future<Map<String, dynamic>> call(
    String name, {
    Map<String, dynamic>? body,
    String? bearerToken,
    bool delete = false,
  }) async {
    calls.add(name);
    bodiesSeen[name] = body;
    tokensSeen[name] = bearerToken;

    final error = errors[name];
    if (error != null) throw error;
    return responses[name] ?? const {};
  }
}

/// [SessionStore] talks to the Keychain, which does not exist under `flutter test`.
class _MemorySessionStore implements SessionStore {
  String? _token;
  AppUser? _user;

  @override
  Future<String?> readToken() async => _token;

  @override
  Future<void> save({required String token, required AppUser user}) async {
    _token = token;
    _user = user;
  }

  @override
  Future<void> cacheUser(AppUser user) async => _user = user;

  @override
  Future<AppUser?> readCachedUser() async => _user;

  @override
  Future<void> clear() async {
    _token = null;
    _user = null;
  }

  @override
  noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
