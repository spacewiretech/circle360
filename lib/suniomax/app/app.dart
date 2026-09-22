import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/providers.dart';
import 'router.dart';
import 'theme/sx_theme.dart';

/// The SunioMax app tree.
///
/// Mirrors `Loc360App`, minus the deeplink listener — SunioMax has no invite flow, and the
/// `loc360://` links belong to the other app. It keeps [analyticsBootstrapProvider] for the same
/// reason Circle360 does: the Mixpanel token arrives with `app_config`, and that fetch must
/// outlive the screen that triggered it.
///
/// Which of the two apps is built is decided once in `bootMobileApp()`. Nothing below this widget
/// knows the other one exists.
class SunioMaxApp extends ConsumerWidget {
  const SunioMaxApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.watch(analyticsBootstrapProvider);

    return MaterialApp.router(
      title: 'SunioMax',
      debugShowCheckedModeBanner: false,
      theme: buildSunioTheme(),
      routerConfig: sunioRouter,
    );
  }
}
