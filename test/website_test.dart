import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';

import 'package:loc_360/data/deeplink_service.dart';
import 'package:loc_360/website/policy_docs.dart';
import 'package:loc_360/website/site_app.dart';
import 'package:loc_360/website/site_copy.dart';
import 'package:loc_360/website/site_router.dart';

/// Covers the marketing site.
///
/// Two things here are load-bearing rather than cosmetic: every policy route has to resolve,
/// because Play Console and the payment provider are given those URLs directly and a 404
/// fails onboarding; and `/invite/:code` has to keep matching the link format
/// `deeplink_service.dart` puts into outgoing SMS.
void main() {
  setUpAll(() {
    // Otherwise every pump tries to pull Poppins and Inter over the network.
    GoogleFonts.config.allowRuntimeFetching = false;
  });

  /// Pumps the site at [location] on a desktop-sized surface.
  Future<void> pumpSite(WidgetTester tester, {String location = SiteRoutes.home}) async {
    tester.view.physicalSize = const Size(1440, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      Circle360SiteApp(router: buildSiteRouter(initialLocation: location)),
    );
    await tester.pumpAndSettle();
  }

  group('home page', () {
    testWidgets('leads with the headline, the price and every feature', (tester) async {
      await pumpSite(tester);

      expect(find.text(SiteCopy.heroHeadline), findsOneWidget);
      expect(find.text(SiteCopy.priceLine), findsOneWidget);

      for (final feature in SiteCopy.features) {
        expect(find.text(feature.title), findsOneWidget,
            reason: '"${feature.title}" should be on the page');
      }
    });

    testWidgets('quotes the same trial and plan price the paywall does', (tester) async {
      await pumpSite(tester);

      // If these drift from `app_config_repository.dart`, the site is advertising a price the
      // app does not charge.
      expect(SiteCopy.trialPrice, '₹3');
      expect(SiteCopy.planPrice, '₹499');
      expect(SiteCopy.trialDays, 2);
      expect(find.textContaining(SiteCopy.trialPrice), findsWidgets);
    });

    testWidgets('every feature card carries a distinct icon', (tester) async {
      final icons = SiteCopy.features.map((feature) => feature.icon).toSet();
      expect(icons.length, SiteCopy.features.length,
          reason: 'two cards sharing an icon read as a duplicate');
    });
  });

  group('policy routes', () {
    for (final doc in PolicyDocs.all) {
      testWidgets('/${doc.slug} renders ${doc.title}', (tester) async {
        await pumpSite(tester, location: '/${doc.slug}');

        expect(find.text(doc.title), findsWidgets);
        for (final section in doc.sections) {
          expect(find.text(section.heading), findsWidgets,
              reason: '${doc.slug} should show the "${section.heading}" section');
        }
      });
    }

    testWidgets('the footer links to all five, plus contact', (tester) async {
      await pumpSite(tester);

      for (final doc in PolicyDocs.all) {
        expect(find.text(doc.navLabel), findsWidgets,
            reason: '${doc.navLabel} should be linked from the footer');
      }
      expect(find.text('Contact Us'), findsWidgets);
    });

    testWidgets('contact page shows the support address', (tester) async {
      await pumpSite(tester, location: SiteRoutes.contact);

      expect(find.textContaining(SitePlaceholders.supportEmail), findsWidgets);
    });

    testWidgets('an unknown path falls back to the home page', (tester) async {
      await pumpSite(tester, location: '/no-such-page');

      expect(find.text(SiteCopy.heroHeadline), findsOneWidget);
    });
  });

  group('invite landing', () {
    testWidgets('names the inviter when the link carries one', (tester) async {
      await pumpSite(tester, location: '/invite/ABC123?from=Mom');

      expect(find.text('Mom invited you to ${SiteCopy.appName}'), findsOneWidget);
    });

    testWidgets('stays generic when it does not', (tester) async {
      await pumpSite(tester, location: '/invite/ABC123');

      expect(find.text('You’ve been invited to ${SiteCopy.appName}'), findsOneWidget);
    });

    testWidgets('serves the same URL shape the app puts into an SMS', (tester) async {
      // The site route and `parseInvite` have to agree, or an invite that lands in a browser
      // shows the wrong page — or none.
      final link = Uri.parse('https://$inviteHost/invite/ABC123?from=Mom');
      final parsed = parseInvite(link);

      expect(parsed, isNotNull);
      expect(parsed!.code, 'ABC123');
      expect(parsed.inviterName, 'Mom');

      await pumpSite(tester, location: '${link.path}?from=${parsed.inviterName}');
      expect(find.text('Mom invited you to ${SiteCopy.appName}'), findsOneWidget);
    });
  });

  group('placeholders', () {
    // Rewritten now the real details are in. Rather than pinning each value — which just moves
    // the maintenance burden — this asserts the *shape* of an unfilled placeholder, so a new
    // one added later is caught without anyone remembering to add a case for it.
    test('nothing obviously unfilled can ship', () {
      const filled = <String, String>{
        'legalEntity': SitePlaceholders.legalEntity,
        'address': SitePlaceholders.address,
        'supportEmail': SitePlaceholders.supportEmail,
        'siteDomain': SitePlaceholders.siteDomain,
        'supportPhone': SitePlaceholders.supportPhone,
      };

      filled.forEach((name, value) {
        expect(value, isNotEmpty, reason: '$name is blank');
        expect(value, isNot(startsWith('[')), reason: '$name is still bracketed');
        expect(
          value.toUpperCase(),
          isNot(contains('XXX')),
          reason: '$name still has an XXXXX placeholder in it',
        );
        expect(value.toUpperCase(), isNot(contains('TODO')), reason: '$name is a TODO');
      });
    });

    test('store links stay null until the listings are real', () {
      // Null is the deliberate "coming soon" state, not an oversight — the download buttons
      // read it directly. Flip these when the listings go live.
      expect(SitePlaceholders.playStoreUrl, isNull);
      expect(SitePlaceholders.appStoreUrl, isNull);
    });
  });
}
