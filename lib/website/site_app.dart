import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import 'site_copy.dart';
import 'site_router.dart';
import 'site_theme.dart';

/// The marketing site. This is what the web build runs — see `lib/main.dart`.
///
/// Deliberately independent of the app: no `ProviderScope`, no repositories, no network. It
/// borrows only the brand — `AppColors`, the wordmark and the hero mockup.
class Circle360SiteApp extends StatelessWidget {
  const Circle360SiteApp({super.key, this.router});

  /// Tests pass their own from [buildSiteRouter] so each case starts at a known route.
  final GoRouter? router;

  @override
  Widget build(BuildContext context) {
    return MaterialApp.router(
      // Each page overrides this with a `Title` widget so the browser tab tracks the route.
      title: '${SiteCopy.appName} — ${SiteCopy.tagline}',
      debugShowCheckedModeBanner: false,
      theme: buildSiteTheme(),
      routerConfig: router ?? siteRouter,
    );
  }
}
