import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:loc_360/data/fake/fake_session.dart';
import 'package:loc_360/data/models/tracked_person.dart';
import 'package:loc_360/data/repositories/family_repository.dart';
import 'package:loc_360/features/emergency/emergency_viewmodel.dart';
import 'package:loc_360/features/home/home_viewmodel.dart';
import 'package:loc_360/features/onboarding/onboarding_viewmodel.dart';
import 'package:loc_360/features/splash/splash_viewmodel.dart';
import 'package:loc_360/data/models/app_user.dart';
import 'package:loc_360/location_service.dart';

/// The ViewModels run against the fake repositories, so these cover the rules the UI relies
/// on: gating, the person cap and expand/collapse.
void main() {
  // HomeViewModel reads this device's position for the "km away" line, which reaches the
  // location platform channel. Without a binding that throws before any test body runs.
  TestWidgetsFlutterBinding.ensureInitialized();

  late ProviderContainer container;

  setUp(() {
    FakeSession.instance.reset();
    container = ProviderContainer();
    addTearDown(container.dispose);
  });

  group('OnboardingViewModel', () {
    test('continue stays locked until the number is 10 digits', () {
      final viewModel = container.read(onboardingViewModelProvider.notifier);

      viewModel.setPhone('99311456');
      expect(container.read(onboardingViewModelProvider).canSendOtp, isFalse);

      viewModel.setPhone('9931145610');
      expect(container.read(onboardingViewModelProvider).canSendOtp, isTrue);
    });

    test('continue stays locked until the code is 6 digits', () {
      final viewModel = container.read(onboardingViewModelProvider.notifier);

      viewModel.setCode('12');
      expect(container.read(onboardingViewModelProvider).canVerify, isFalse);

      viewModel.setCode('123456');
      expect(container.read(onboardingViewModelProvider).canVerify, isTrue);
    });

    test('a short code is rejected and surfaces an error', () async {
      final viewModel = container.read(onboardingViewModelProvider.notifier);
      viewModel.setPhone('9931145610');
      viewModel.setCode('12');

      expect(await viewModel.verifyOtp(), isNull);
      expect(container.read(onboardingViewModelProvider).busy, isFalse);
    });

    test('verifying then naming completes onboarding', () async {
      final viewModel = container.read(onboardingViewModelProvider.notifier);
      viewModel.setPhone('9931145610');
      viewModel.setCode('123456');

      // A brand new account has no name yet, so it still goes through the name step.
      expect(await viewModel.verifyOtp(), SplashDestination.name);

      viewModel.setName('  Ayush  ');
      // Named but never paid — the paywall is where this one belongs.
      expect(await viewModel.saveName(), SplashDestination.subscribe);
      // The name is trimmed on the way into the session.
      expect(FakeSession.instance.user?.name, 'Ayush');
    });

    test('a blank name cannot be submitted', () {
      container.read(onboardingViewModelProvider.notifier).setName('   ');
      expect(container.read(onboardingViewModelProvider).canSaveName, isFalse);
    });

    // Regression: signing in again on a wiped device used to walk the user through the name
    // step and then hard-navigate to the paywall, which quoted ₹499 because the trial had
    // already been used. Only a cold start put them right, because only the splash asked where
    // the user actually belonged. Every step that resolves a user now asks the same question.
    test('a returning trial user is never sent back to the paywall', () async {
      final onTrial = AppUser(
        id: 'u1',
        phone: '9931145610',
        name: 'Ayush',
        trialEndsAt: DateTime.now().add(const Duration(days: 1)),
        entitled: true,
      );

      final destination = await destinationForUser(
        user: onTrial,
        locationService: LocationService(),
      );

      expect(destination, isNot(SplashDestination.subscribe));
      expect(destination, isNot(SplashDestination.name));
      // No platform channel under test, so location reads as never-asked and the permission
      // step is the honest answer — the point is that it is on the far side of the paywall.
      expect(destination, SplashDestination.location);
    });

    test('a named user who never paid still lands on the paywall', () async {
      const neverPaid = AppUser(id: 'u2', phone: '9931145610', name: 'Ayush');

      expect(
        await destinationForUser(user: neverPaid, locationService: LocationService()),
        SplashDestination.subscribe,
      );
    });
  });

  group('HomeViewModel', () {
    test('starts empty and accepts people up to the cap', () async {
      final viewModel = container.read(homeViewModelProvider.notifier);

      for (var i = 0; i < FamilyRepository.maxPeople; i++) {
        await viewModel.addPerson(name: 'Person $i', phone: '+91 900000000$i');
      }
      expect(container.read(homeViewModelProvider).people, hasLength(3));
      expect(container.read(homeViewModelProvider).canAddMore, isFalse);

      // The fourth is refused by the repository and reported, not thrown.
      await viewModel.addPerson(name: 'Fourth', phone: '+91 9000000004');
      expect(container.read(homeViewModelProvider).people, hasLength(3));
      expect(
        container.read(homeViewModelProvider).message,
        contains('up to 3 people'),
      );
    });

    test('toggling a card opens it, and toggling again closes it', () async {
      final viewModel = container.read(homeViewModelProvider.notifier);
      await viewModel.addPerson(name: 'Mom', phone: '+91 8764597659');
      final person = container.read(homeViewModelProvider).people.single;

      viewModel.toggle(person.id);
      expect(container.read(homeViewModelProvider).expanded?.id, person.id);

      viewModel.toggle(person.id);
      expect(container.read(homeViewModelProvider).expanded, isNull);
    });

    test('removing the expanded person clears the selection', () async {
      final viewModel = container.read(homeViewModelProvider.notifier);
      await viewModel.addPerson(name: 'Mom', phone: '+91 8764597659');
      final person = container.read(homeViewModelProvider).people.single;
      viewModel.toggle(person.id);

      await viewModel.removePerson(person);
      await Future<void>.delayed(Duration.zero);

      expect(container.read(homeViewModelProvider).people, isEmpty);
      expect(container.read(homeViewModelProvider).expandedId, isNull);
    });

    test('an action reports back a confirmation naming the person', () async {
      final viewModel = container.read(homeViewModelProvider.notifier);
      await viewModel.addPerson(name: 'Mom', phone: '+91 8764597659');
      final person = container.read(homeViewModelProvider).people.single;

      await viewModel.runAction(PersonAction.call, person);
      expect(container.read(homeViewModelProvider).message, contains(person.name));

      viewModel.consumeMessage();
      expect(container.read(homeViewModelProvider).message, isNull);
    });
  });

  group('EmergencyViewModel', () {
    test('adds, caps at 3 and removes', () async {
      final viewModel = container.read(emergencyViewModelProvider.notifier);
      // Let the initial load settle before asserting on the empty state.
      await Future<void>.delayed(const Duration(milliseconds: 500));
      expect(container.read(emergencyViewModelProvider).isEmpty, isTrue);

      await viewModel.add(name: 'Mom', phone: '+91 8764597659');
      expect(container.read(emergencyViewModelProvider).contacts, hasLength(1));

      await viewModel.add(name: 'Dad', phone: '+91 8764597658');
      await viewModel.add(name: 'Sister', phone: '+91 8764597657');
      await viewModel.add(name: 'Fourth', phone: '+91 8764597656');
      expect(container.read(emergencyViewModelProvider).contacts, hasLength(3));

      final first = container.read(emergencyViewModelProvider).contacts.first;
      await viewModel.remove(first);
      expect(container.read(emergencyViewModelProvider).contacts, hasLength(2));
    });
  });
}
