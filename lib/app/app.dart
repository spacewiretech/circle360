import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/pending_invite.dart';
import 'router.dart';
import 'theme/app_theme.dart';

class Loc360App extends ConsumerWidget {
  const Loc360App({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Keeps the deeplink subscription alive for the life of the app, not just while the
    // splash is on screen, so links arriving later still land.
    ref.watch(deeplinkListenerProvider);

    // A link that arrives while the app is already running jumps to the invite screen. The
    // cold-start case is handled by the splash instead, because the invite is already set
    // before this listener exists.
    ref.listen(pendingInviteProvider, (_, invite) {
      if (invite != null) appRouter.go(Routes.invite);
    });

    return MaterialApp.router(
      title: 'Loc 360',
      debugShowCheckedModeBanner: false,
      theme: buildAppTheme(),
      routerConfig: appRouter,
    );
  }
}
