import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:loc_360/data/fake/fake_session.dart';
import 'package:loc_360/data/deeplink_service.dart';
import 'package:loc_360/data/models/invite_link.dart';
import 'package:loc_360/data/pending_invite.dart';
import 'package:loc_360/data/providers.dart';
import 'package:loc_360/features/invite/invite_viewmodel.dart';
import 'package:loc_360/features/splash/splash_viewmodel.dart';

void main() {
  group('parseInvite', () {
    test('reads the custom scheme with a query code', () {
      final invite = parseInvite(Uri.parse('loc360://invite?code=ABC123&from=Mom'));
      expect(invite, const InviteLink(code: 'ABC123', inviterName: 'Mom'));
    });

    test('reads the custom scheme with the code as a path segment', () {
      final invite = parseInvite(Uri.parse('loc360://invite/XYZ789'));
      expect(invite?.code, 'XYZ789');
      expect(invite?.inviterName, isNull);
    });

    test('reads the https App Link form', () {
      final invite = parseInvite(Uri.parse('https://$inviteHost/invite/ABC123?from=Sister'));
      expect(invite, const InviteLink(code: 'ABC123', inviterName: 'Sister'));
    });

    test('rejects URLs that are not invites', () {
      for (final url in [
        'loc360://profile?code=ABC',
        'https://$inviteHost/pricing',
        'https://example.com/invite/ABC123',
        'loc360://invite',
        'loc360://invite?code=',
        'https://$inviteHost/invite',
      ]) {
        expect(parseInvite(Uri.parse(url)), isNull, reason: url);
      }
    });
  });

  group('splashDestinationProvider', () {
    /// The real service touches a platform channel, so tests swap in a scripted one.
    ProviderContainer containerWith(InviteLink? invite) {
      final container = ProviderContainer(
        overrides: [
          deeplinkServiceProvider.overrideWithValue(_StubDeeplinkService(invite)),
        ],
      );
      addTearDown(container.dispose);
      return container;
    }

    setUp(FakeSession.instance.reset);

    test('a normal launch goes to the phone screen', () async {
      final container = containerWith(null);
      expect(
        await container.read(splashDestinationProvider.future),
        SplashDestination.onboarding,
      );
    });

    test('a deeplink launch goes to the invite screen', () async {
      final container = containerWith(const InviteLink(code: 'ABC123'));
      expect(
        await container.read(splashDestinationProvider.future),
        SplashDestination.invite,
      );
      expect(container.read(pendingInviteProvider)?.code, 'ABC123');
    });

    test('the invite wins over a resumable session', () async {
      final container = containerWith(const InviteLink(code: 'ABC123'));
      await container.read(authRepositoryProvider).verifyOtp(
            phone: '9931145610',
            code: '123456',
          );
      expect(
        await container.read(splashDestinationProvider.future),
        SplashDestination.invite,
      );
    });
  });

  group('InviteViewModel', () {
    ProviderContainer containerWith(InviteLink? invite) {
      final container = ProviderContainer(
        overrides: [
          deeplinkServiceProvider.overrideWithValue(_StubDeeplinkService(invite)),
        ],
      );
      addTearDown(container.dispose);
      return container;
    }

    setUp(FakeSession.instance.reset);

    test('Continue stays locked until the number is 10 digits', () {
      final container = containerWith(null);
      final viewModel = container.read(inviteViewModelProvider.notifier);

      viewModel.setPhone('99311456');
      expect(container.read(inviteViewModelProvider).canSubmit, isFalse);

      viewModel.setPhone('9931145610');
      expect(container.read(inviteViewModelProvider).canSubmit, isTrue);
    });

    test('a signed-out user continues to the phone screen', () async {
      final container = containerWith(const InviteLink(code: 'ABC123'));
      await container.read(splashDestinationProvider.future);

      final viewModel = container.read(inviteViewModelProvider.notifier);
      viewModel.setPhone('8764597659');

      expect(await viewModel.submit(), SplashDestination.onboarding);
      // Consumed, so a later launch without a link does not land here again.
      expect(container.read(pendingInviteProvider), isNull);
    });

    test('an onboarded user continues to home, and the code rides along', () async {
      final container = containerWith(const InviteLink(code: 'ABC123'));
      await container.read(splashDestinationProvider.future);

      await container.read(authRepositoryProvider).verifyOtp(
            phone: '9931145610',
            code: '123456',
          );
      await container.read(authRepositoryProvider).saveName('Ayush');
      // The fake grants the trial on the status refresh, mirroring the real flow where the
      // entitlement only exists once the server confirms the mandate.
      await container.read(subscriptionRepositoryProvider).refreshStatus();

      final viewModel = container.read(inviteViewModelProvider.notifier);
      viewModel.setPhone('8764597659');
      expect(await viewModel.submit(), SplashDestination.home);
    });

    test('a half-onboarded user resumes at the step they left off', () async {
      final container = containerWith(const InviteLink(code: 'ABC123'));
      await container.read(splashDestinationProvider.future);

      // Verified, but never named — the flow owes them the name step.
      await container.read(authRepositoryProvider).verifyOtp(
            phone: '9931145610',
            code: '123456',
          );

      final viewModel = container.read(inviteViewModelProvider.notifier);
      viewModel.setPhone('8764597659');
      expect(await viewModel.submit(), SplashDestination.name);
    });

    test('submitting below 10 digits does nothing', () async {
      final container = containerWith(null);
      final viewModel = container.read(inviteViewModelProvider.notifier);
      viewModel.setPhone('876');
      expect(await viewModel.submit(), isNull);
    });
  });
}

/// Stands in for the platform channel: reports one cold-start link and no warm ones.
class _StubDeeplinkService implements DeeplinkService {
  _StubDeeplinkService(this._invite);

  final InviteLink? _invite;

  @override
  Future<InviteLink?> initialInvite() async => _invite;

  @override
  Stream<InviteLink> invites() => const Stream.empty();

  @override
  noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
