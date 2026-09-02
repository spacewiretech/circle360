import 'package:go_router/go_router.dart';

import 'pages/contact_page.dart';
import 'pages/home_page.dart';
import 'pages/invite_page.dart';
import 'pages/policy_page.dart';
import 'policy_docs.dart';

abstract final class SiteRoutes {
  static const home = '/';
  static const privacy = '/privacy';
  static const terms = '/terms';
  static const refund = '/refund';
  static const shipping = '/shipping';
  static const deleteAccount = '/delete-account';
  static const contact = '/contact';

  /// Where an SMS invite lands when the app is not installed. The shape has to keep matching
  /// `parseInvite` in `lib/data/deeplink_service.dart` — `/invite/<code>?from=<name>`.
  static const invite = '/invite/:code';

  /// Jump straight to a section of the home page — used by the nav when you are already on
  /// another page. `HomePage` reads it and scrolls after the first frame.
  static String homeSection(String anchor) => '/?to=$anchor';
}

/// Separate from `appRouter` in `lib/app/router.dart` on purpose: the site shares the brand
/// but none of the app's state, gates or redirects.
final siteRouter = GoRouter(
  initialLocation: SiteRoutes.home,
  routes: [
    GoRoute(
      path: SiteRoutes.home,
      builder: (context, state) => HomePage(anchor: state.uri.queryParameters['to']),
    ),
    GoRoute(
      path: SiteRoutes.privacy,
      builder: (context, state) => const PolicyPage(doc: PolicyDocs.privacy),
    ),
    GoRoute(
      path: SiteRoutes.terms,
      builder: (context, state) => const PolicyPage(doc: PolicyDocs.terms),
    ),
    GoRoute(
      path: SiteRoutes.refund,
      builder: (context, state) => const PolicyPage(doc: PolicyDocs.refund),
    ),
    GoRoute(
      path: SiteRoutes.shipping,
      builder: (context, state) => const PolicyPage(doc: PolicyDocs.shipping),
    ),
    GoRoute(
      path: SiteRoutes.deleteAccount,
      builder: (context, state) => const PolicyPage(doc: PolicyDocs.deleteAccount),
    ),
    GoRoute(
      path: SiteRoutes.contact,
      builder: (context, state) => const ContactPage(),
    ),
    GoRoute(
      path: SiteRoutes.invite,
      builder: (context, state) => InvitePage(
        code: state.pathParameters['code'] ?? '',
        inviterName: state.uri.queryParameters['from'],
      ),
    ),
  ],
  // A mistyped or stale URL should show the pitch, not a stack trace.
  errorBuilder: (context, state) => const HomePage(),
);
