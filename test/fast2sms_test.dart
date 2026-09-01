import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:loc_360/data/fake/fake_session.dart';
import 'package:loc_360/data/fast2sms/fast2sms_auth_repository.dart';
import 'package:loc_360/data/fast2sms/fast2sms_client.dart';
import 'package:loc_360/data/fast2sms/fast2sms_exception.dart';
import 'package:loc_360/data/models/app_user.dart';
import 'package:loc_360/data/providers.dart';
import 'package:loc_360/data/repositories/auth_repository.dart';
import 'package:loc_360/features/onboarding/onboarding_state.dart';
import 'package:loc_360/features/onboarding/onboarding_viewmodel.dart';

/// Every Fast2SMS failure mode the app can meet, driven through a mocked transport.
void main() {
  /// Records the paths hit so tests can assert on the resend → send fallback.
  late List<String> calls;

  Fast2SmsClient clientReturning(
    http.Response Function(http.Request request) respond,
  ) {
    calls = [];
    return Fast2SmsClient(
      apiKey: 'test-key',
      otpId: 'test-otp-id',
      httpClient: MockClient((request) async {
        calls.add(request.url.path);
        return respond(request);
      }),
    );
  }

  http.Response ok([Map<String, Object?> extra = const {}]) => http.Response(
        jsonEncode({'return': true, 'status_code': 200, ...extra}),
        200,
      );

  /// Fast2SMS reports most failures as `return:false` inside an HTTP 200.
  http.Response failure(int code, String message, {int httpStatus = 200}) =>
      http.Response(
        jsonEncode({'return': false, 'status_code': code, 'message': message}),
        httpStatus,
      );

  group('Fast2SmsClient send', () {
    test('posts the mobile, template id, length and expiry', () async {
      Map<String, dynamic>? body;
      final client = clientReturning((request) {
        body = jsonDecode(request.body) as Map<String, dynamic>;
        expect(request.headers['Authorization'], 'test-key');
        return ok();
      });

      await client.sendOtp('9931145610');

      expect(calls.single, '/dev/otp/send');
      expect(body, {
        'mobile': '9931145610',
        'otp_id': 'test-otp-id',
        'otp_length': 6,
        'otp_expiry': 5,
      });
    });

    test('a return:false inside an HTTP 200 is still a failure', () async {
      final client = clientReturning((_) => failure(416, 'Insufficient balance'));
      await expectLater(
        client.sendOtp('9931145610'),
        throwsA(isA<Fast2SmsException>().having((e) => e.code, 'code', 416)),
      );
    });

    test('account problems read as unavailable and never leak the reason', () async {
      for (final (code, provider) in [
        (412, 'Invalid Authentication, Check Authorization Key'),
        (413, 'Authorization Key Disabled'),
        (416, "You don't have sufficient wallet balance"),
        (996, 'Before using OTP SMS API, complete KYC.'),
        (999, 'Complete single transaction of minimum 100 INR'),
        (400, 'Invalid OTP ID'),
      ]) {
        final client = clientReturning((_) => failure(code, provider));
        try {
          await client.sendOtp('9931145610');
          fail('expected a throw for $code');
        } on Fast2SmsException catch (e) {
          expect(e.userMessage, 'Verification is temporarily unavailable. '
              'Please try again later.');
          expect(e.isConfigurationProblem, isTrue, reason: '$code');
          // The real cause stays in the developer detail only.
          expect(e.developerDetail, contains(provider));
        }
      }
    });

    test('actionable problems say something the user can act on', () async {
      final spam = clientReturning((_) => failure(995, 'Spamming detected'));
      await expectLater(
        spam.sendOtp('9931145610'),
        throwsA(isA<Fast2SmsException>()
            .having((e) => e.userMessage, 'message', contains('wait a few minutes'))),
      );

      final badNumber = clientReturning((_) => failure(411, 'Invalid Numbers'));
      await expectLater(
        badNumber.sendOtp('1231231231'),
        throwsA(isA<Fast2SmsException>()
            .having((e) => e.userMessage, 'message', contains('not valid'))),
      );
    });
  });

  group('Fast2SmsClient transport failures', () {
    test('no connectivity reads as an internet problem', () async {
      final client = Fast2SmsClient(
        apiKey: 'k',
        otpId: 'o',
        httpClient: MockClient((_) => throw const SocketException('failed host lookup')),
      );
      await expectLater(
        client.sendOtp('9931145610'),
        throwsA(isA<Fast2SmsException>()
            .having((e) => e.userMessage, 'message', contains('No internet'))
            .having((e) => e.code, 'code', isNull)),
      );
    });

    test('a slow network times out rather than hanging', () async {
      final client = Fast2SmsClient(
        apiKey: 'k',
        otpId: 'o',
        timeout: const Duration(milliseconds: 30),
        httpClient: MockClient((_) async {
          await Future<void>.delayed(const Duration(seconds: 2));
          return http.Response('{}', 200);
        }),
      );
      await expectLater(
        client.sendOtp('9931145610'),
        throwsA(isA<Fast2SmsException>()
            .having((e) => e.userMessage, 'message', contains('network is slow'))),
      );
    });

    test('an HTML error page does not crash the decoder', () async {
      final client = clientReturning(
        (_) => http.Response('<html><body>502 Bad Gateway</body></html>', 502),
      );
      await expectLater(
        client.sendOtp('9931145610'),
        throwsA(isA<Fast2SmsException>()
            .having((e) => e.developerDetail, 'detail', contains('Unreadable body'))),
      );
    });
  });

  group('Fast2SmsClient verify', () {
    test('a good code verifies', () async {
      final client = clientReturning((_) => ok());
      expect(
        await client.verifyOtp(mobile: '9931145610', otp: '123456'),
        VerifyResult.verified,
      );
      expect(calls.single, '/dev/otp/verify');
    });

    test('400 is a wrong code, 404 is expired or already used', () async {
      final wrong = clientReturning((_) => failure(400, 'Invalid OTP', httpStatus: 400));
      expect(
        await wrong.verifyOtp(mobile: '9931145610', otp: '000000'),
        VerifyResult.wrongCode,
      );

      final gone = clientReturning(
        (_) => failure(404, 'OTP not found or already verified', httpStatus: 404),
      );
      expect(
        await gone.verifyOtp(mobile: '9931145610', otp: '123456'),
        VerifyResult.expiredOrUsed,
      );
    });

    test('an account problem during verify still throws', () async {
      final client = clientReturning((_) => failure(412, 'Invalid Authentication'));
      await expectLater(
        client.verifyOtp(mobile: '9931145610', otp: '123456'),
        throwsA(isA<Fast2SmsException>()),
      );
    });
  });

  group('Fast2SmsAuthRepository', () {
    setUp(FakeSession.instance.reset);

    test('resend falls back to a fresh send once the window has closed', () async {
      final client = clientReturning((request) {
        if (request.url.path == '/dev/otp/resend') {
          return failure(404, 'No previous OTP request found', httpStatus: 404);
        }
        return ok();
      });
      final repository = Fast2SmsAuthRepository(client, FakeSession.instance);

      await repository.resendOtp('9931145610');

      expect(calls, ['/dev/otp/resend', '/dev/otp/send']);
    });

    test('the server resend cap reads as too many codes', () async {
      final client = clientReturning(
        (_) => failure(400, 'Maximum resend limit (5 times) reached', httpStatus: 400),
      );
      final repository = Fast2SmsAuthRepository(client, FakeSession.instance);

      await expectLater(
        repository.resendOtp('9931145610'),
        throwsA(isA<OtpSendException>()
            .having((e) => e.message, 'message', contains('too many codes'))),
      );
    });

    test('a wrong code and an expired code raise different exceptions', () async {
      final wrong = Fast2SmsAuthRepository(
        clientReturning((_) => failure(400, 'Invalid OTP', httpStatus: 400)),
        FakeSession.instance,
      );
      await expectLater(
        wrong.verifyOtp(phone: '9931145610', code: '000000'),
        throwsA(isA<InvalidOtpException>()),
      );

      final expired = Fast2SmsAuthRepository(
        clientReturning((_) => failure(404, 'OTP not found', httpStatus: 404)),
        FakeSession.instance,
      );
      await expectLater(
        expired.verifyOtp(phone: '9931145610', code: '123456'),
        throwsA(isA<OtpExpiredException>()),
      );
    });

    test('verifying creates the session user', () async {
      final repository = Fast2SmsAuthRepository(
        clientReturning((_) => ok()),
        FakeSession.instance,
      );

      final user = await repository.verifyOtp(phone: '9931145610', code: '123456');

      expect(user.phone, '9931145610');
      expect(await repository.currentUser(), isNotNull);

      await repository.signOut();
      expect(await repository.currentUser(), isNull);
    });

    test('a send failure surfaces the safe message, not the provider string', () async {
      final repository = Fast2SmsAuthRepository(
        clientReturning((_) => failure(412, 'Invalid Authentication, Check Authorization Key')),
        FakeSession.instance,
      );

      await expectLater(
        repository.sendOtp('9931145610'),
        throwsA(isA<OtpSendException>().having(
          (e) => e.message,
          'message',
          isNot(contains('Authorization')),
        )),
      );
    });
  });

  group('OnboardingViewModel OTP rules', () {
    late _ScriptedAuthRepository auth;
    late ProviderContainer container;

    setUp(() {
      FakeSession.instance.reset();
      auth = _ScriptedAuthRepository();
      container = ProviderContainer(
        overrides: [authRepositoryProvider.overrideWithValue(auth)],
      );
      addTearDown(container.dispose);
    });

    OnboardingViewModel vm() => container.read(onboardingViewModelProvider.notifier);
    OnboardingState now() => container.read(onboardingViewModelProvider);

    test('only Indian mobile numbers unlock continue', () {
      for (final bad in ['1234567890', '5931145610', '093114561', '99311456101']) {
        vm().setPhone(bad);
        expect(now().canSendOtp, isFalse, reason: bad);
      }
      vm().setPhone('9931145610');
      expect(now().canSendOtp, isTrue);
    });

    test('sending starts the resend cooldown', () async {
      vm().setPhone('9931145610');
      expect(await vm().sendOtp(), isTrue);

      expect(now().canResend, isFalse);
      expect(now().resendIn.inSeconds, greaterThan(25));
      expect(now().resendCountdownLabel, matches(r'^0:\d\d$'));
    });

    test('wrong codes burn attempts and lock verification at zero', () async {
      vm().setPhone('9931145610');
      await vm().sendOtp();
      auth.verifyThrows = const InvalidOtpException();

      for (var i = OnboardingState.maxAttempts; i > 1; i--) {
        vm().setCode('000000');
        expect(await vm().verifyOtp(), isNull);
        expect(now().attemptsLeft, i - 1);
        // A rejected code is cleared so the boxes can be retyped.
        expect(now().code, isEmpty);
      }

      vm().setCode('000000');
      expect(await vm().verifyOtp(), isNull);
      expect(now().attemptsLeft, 0);
      expect(now().error, contains('Too many incorrect attempts'));

      // Locked out until a resend, even with a full-length code typed.
      vm().setCode('123456');
      expect(now().canVerify, isFalse);
      expect(await vm().verifyOtp(), isNull);
    });

    test('a network failure during verify does not burn an attempt', () async {
      vm().setPhone('9931145610');
      await vm().sendOtp();
      auth.verifyThrows = const OtpSendException('No internet connection.');

      vm().setCode('123456');
      expect(await vm().verifyOtp(), isNull);
      expect(now().attemptsLeft, OnboardingState.maxAttempts);
      expect(now().error, 'No internet connection.');
      // The typed code survives, so a retry does not mean retyping.
      expect(now().code, '123456');
    });

    test('an expired code unlocks resend immediately and spends no attempt', () async {
      vm().setPhone('9931145610');
      await vm().sendOtp();
      expect(now().canResend, isFalse);

      auth.verifyThrows = const OtpExpiredException();
      vm().setCode('123456');
      expect(await vm().verifyOtp(), isNull);

      expect(now().attemptsLeft, OnboardingState.maxAttempts);
      expect(now().canResend, isTrue);
      expect(now().error, contains('expired'));
    });

    test('resend is refused while the cooldown is running', () async {
      vm().setPhone('9931145610');
      await vm().sendOtp();

      expect(await vm().resendOtp(), isFalse);
      expect(auth.resendCalls, 0);
    });

    test('resend restores the attempt budget and restarts the cooldown', () async {
      vm().setPhone('9931145610');
      await vm().sendOtp();

      // Burn an attempt, then let the code expire — which is the one path that unlocks
      // resend without waiting out the cooldown.
      auth.verifyThrows = const InvalidOtpException();
      vm().setCode('000000');
      await vm().verifyOtp();
      expect(now().attemptsLeft, OnboardingState.maxAttempts - 1);

      auth.verifyThrows = const OtpExpiredException();
      vm().setCode('123456');
      await vm().verifyOtp();
      expect(now().canResend, isTrue);

      auth.verifyThrows = null;
      expect(await vm().resendOtp(), isTrue);

      expect(auth.resendCalls, 1);
      expect(now().attemptsLeft, OnboardingState.maxAttempts);
      expect(now().resendsUsed, 1);
      expect(now().code, isEmpty);
      // A fresh cooldown starts, so resend cannot be hammered.
      expect(now().canResend, isFalse);
    });

    test('changing the number drops the outstanding code and its budgets', () async {
      vm().setPhone('9931145610');
      await vm().sendOtp();
      auth.verifyThrows = const InvalidOtpException();
      vm().setCode('000000');
      await vm().verifyOtp();
      expect(now().attemptsLeft, OnboardingState.maxAttempts - 1);

      vm().setPhone('8764597659');

      expect(now().code, isEmpty);
      expect(now().attemptsLeft, OnboardingState.maxAttempts);
      expect(now().resendsUsed, 0);
      expect(now().resendAvailableAt, isNull);
    });

    test('the resend budget runs out after the provider cap', () {
      // Pure state check — the UI stops offering resend once the cap is reached.
      const exhausted = OnboardingState(resendsUsed: OnboardingState.maxResends);
      expect(exhausted.resendExhausted, isTrue);
      expect(exhausted.canResend, isFalse);
    });
  });
}

/// An [AuthRepository] whose verify outcome each test sets directly.
class _ScriptedAuthRepository implements AuthRepository {
  Exception? verifyThrows;
  int sendCalls = 0;
  int resendCalls = 0;

  @override
  Future<AppUser?> currentUser() async => null;

  @override
  Future<void> sendOtp(String phone) async => sendCalls++;

  @override
  Future<void> resendOtp(String phone) async => resendCalls++;

  @override
  Future<AppUser> verifyOtp({required String phone, required String code}) async {
    if (verifyThrows != null) throw verifyThrows!;
    return AppUser(id: 'u', phone: phone);
  }

  @override
  Future<AppUser> saveName(String name) async => AppUser(id: 'u', phone: '', name: name);

  @override
  Future<void> signOut() async {}
}
