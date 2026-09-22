import 'package:flutter_test/flutter_test.dart';
import 'package:loc_360/app/analytics_observer.dart';
import 'package:loc_360/app/router.dart';
import 'package:loc_360/features/payment_status/payment_outcome.dart';
import 'package:loc_360/features/splash/splash_viewmodel.dart';
import 'package:loc_360/suniomax/app/router.dart';
import 'package:loc_360/suniomax/data/language_preference.dart';
import 'package:loc_360/suniomax/features/splash/sunio_splash_viewmodel.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// SunioMax's own logic — the routing table, the language store, and the two places where it has
/// to coexist with Circle360 without colliding.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('sunioDestinationForSession', () {
    test('language comes before everything, even for a signed-in user', () {
      // It needs no account, and a user who abandons at the OTP has still told us which language
      // to advertise in.
      expect(
        sunioDestinationForSession(
          languageChosen: false,
          signedIn: true,
          hasName: true,
          entitled: true,
        ),
        SunioDestination.language,
      );
    });

    test('the full ladder', () {
      SunioDestination at({
        bool languageChosen = true,
        bool signedIn = true,
        bool hasName = true,
        bool entitled = true,
      }) => sunioDestinationForSession(
        languageChosen: languageChosen,
        signedIn: signedIn,
        hasName: hasName,
        entitled: entitled,
      );

      expect(at(signedIn: false), SunioDestination.onboarding);
      expect(at(hasName: false), SunioDestination.name);
      expect(at(entitled: false), SunioDestination.subscribe);
      expect(at(), SunioDestination.home);
    });

    test('a signed-out user is asked to sign in before being asked to pay', () {
      expect(
        sunioDestinationForSession(
          languageChosen: true,
          signedIn: false,
          hasName: false,
          entitled: false,
        ),
        SunioDestination.onboarding,
      );
    });

    test('there is no location step', () {
      // SunioMax never asks for a position, so `location` must not be reachable — the enum has
      // no such value, and this asserts nobody adds one without deciding to.
      expect(SunioDestination.values.map((d) => d.name), [
        'language',
        'onboarding',
        'name',
        'subscribe',
        'home',
      ]);
    });
  });

  group('routes', () {
    test('every SunioMax path is namespaced under /sx', () {
      // The two apps share one navigator observer, which keys screen names off the route
      // pattern. A SunioMax path that collided with a Circle360 one would silently merge two
      // funnels into a single, meaningless screen name.
      final paths = [
        SxRoutes.splash,
        SxRoutes.language,
        SxRoutes.phone,
        SxRoutes.otp,
        SxRoutes.name,
        SxRoutes.subscribe,
        SxRoutes.paymentStatus,
        SxRoutes.home,
        SxRoutes.settings,
      ];

      for (final path in paths) {
        expect(path, startsWith('/sx'), reason: '$path is not namespaced');
      }
    });

    test('no SunioMax path collides with a Circle360 path', () {
      final circle360 = {
        Routes.splash,
        Routes.invite,
        Routes.phone,
        Routes.otp,
        Routes.name,
        Routes.subscribe,
        Routes.paymentStatus,
        Routes.location,
        Routes.home,
        Routes.emergency,
        Routes.profile,
        Routes.settings,
        Routes.diagnostics,
      };
      final sunio = {
        SxRoutes.splash,
        SxRoutes.language,
        SxRoutes.phone,
        SxRoutes.otp,
        SxRoutes.name,
        SxRoutes.subscribe,
        SxRoutes.paymentStatus,
        SxRoutes.home,
        SxRoutes.settings,
      };

      expect(circle360.intersection(sunio), isEmpty);
    });

    test('payment-status slugs build the SunioMax path', () {
      expect(
        SxRoutes.paymentStatusFor(PaymentOutcome.success),
        '/sx/payment-status/success',
      );
      expect(
        SxRoutes.paymentStatusFor(PaymentOutcome.failed),
        '/sx/payment-status/failed',
      );
    });

    test('each destination maps to a declared route', () {
      for (final destination in SunioDestination.values) {
        expect(destination.route, startsWith('/sx'));
      }
    });

    test('Circle360 destinations translate onto SunioMax routes', () {
      // SunioMax onboarding runs on Circle360's ViewModel, which answers in SplashDestination.
      expect(SplashDestination.onboarding.sunioRoute, SxRoutes.phone);
      expect(SplashDestination.name.sunioRoute, SxRoutes.name);
      expect(SplashDestination.subscribe.sunioRoute, SxRoutes.subscribe);
      // Neither has a SunioMax equivalent: no location step, no invite flow.
      expect(SplashDestination.location.sunioRoute, SxRoutes.home);
      expect(SplashDestination.invite.sunioRoute, SxRoutes.home);
      expect(SplashDestination.home.sunioRoute, SxRoutes.home);
    });
  });

  group('sunioRouter', () {
    test('builds without Firebase', () {
      // The load-bearing assertion in this file. `sunioRouter` is a top-level final, so it is
      // constructed the first time anything reads it — and a test process has no Firebase app.
      // Without the `Firebase.apps.isNotEmpty` guard around its FirebaseAnalyticsObserver, this
      // throws `[core/no-app]` and takes every suite that touches SunioMax with it. Reading the
      // variable is what forces the initialiser to run; importing the file is not.
      expect(sunioRouter.configuration.routes, isNotEmpty);
    });

    test('carries the shared analytics observer', () {
      // One observer across both apps, so there is one screen stack and one ambient `screen`
      // property. A second observer would double-count every SunioMax screen view.
      expect(sunioRouter.routerDelegate.navigatorKey, isNotNull);
      expect(sunioRouter.configuration.routes.length, 9);
    });
  });

  group('screen names', () {
    test('every SunioMax route has one, and it is prefixed', () {
      final routes = {
        SxRoutes.splash: 'SX Splash',
        SxRoutes.language: 'SX Language',
        SxRoutes.phone: 'SX Phone',
        SxRoutes.otp: 'SX OTP',
        SxRoutes.name: 'SX Name',
        SxRoutes.subscribe: 'SX Paywall',
        SxRoutes.paymentStatus: 'SX Payment Status',
        SxRoutes.home: 'SX Home',
        SxRoutes.settings: 'SX Settings',
      };

      routes.forEach((route, expected) {
        expect(screenNameFor(route), expected);
      });
    });

    test('Circle360 screen names are untouched', () {
      // The whole point of prefixing: a report built before SunioMax existed still means what it
      // meant.
      expect(screenNameFor(Routes.phone), 'Phone');
      expect(screenNameFor(Routes.subscribe), 'Paywall');
      expect(screenNameFor(Routes.home), 'Home');
    });
  });

  group('SxLanguage', () {
    test('the nine from the design, in the frame\'s order', () {
      expect(SxLanguage.values.map((l) => l.latin), [
        'English',
        'Hindi',
        'Telugu',
        'Tamil',
        'Kanada',
        'Malayalam',
        'Marathi',
        'Odia',
        'Bangla',
      ]);
    });

    test('every code is a distinct Indian BCP-47 tag', () {
      final codes = SxLanguage.values.map((l) => l.code).toList();
      expect(codes.toSet().length, codes.length, reason: 'duplicate locale');
      for (final code in codes) {
        expect(code, endsWith('-IN'));
      }
    });

    test('parse round-trips, and rejects anything else', () {
      for (final language in SxLanguage.values) {
        expect(SxLanguage.parse(language.code), language);
      }
      expect(SxLanguage.parse('fr-FR'), isNull);
      expect(SxLanguage.parse(''), isNull);
      expect(SxLanguage.parse(null), isNull);
    });
  });

  group('LanguagePreference', () {
    setUp(() => SharedPreferences.setMockInitialValues({}));

    test('nothing stored means the picker is shown', () async {
      expect(await const LanguagePreference().read(), isNull);
    });

    test('a written language is read back', () async {
      const preference = LanguagePreference();
      await preference.write(SxLanguage.hindi);
      expect(await preference.read(), SxLanguage.hindi);
    });

    test(
      'a stored code that is no longer offered shows the picker again',
      () async {
        // Rather than crashing, or silently pretending the user chose English.
        SharedPreferences.setMockInitialValues({'suniomax.language': 'fr-FR'});
        expect(await const LanguagePreference().read(), isNull);
      },
    );
  });
}
