import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/analytics/analytics_events.dart';
import '../data/pending_invite.dart';
import '../data/providers.dart';
import 'router.dart';
import 'theme/app_theme.dart';

class Loc360App extends ConsumerWidget {
  const Loc360App({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Keeps the deeplink subscription alive for the life of the app, not just while the
    // splash is on screen, so links arriving later still land.
    ref.watch(deeplinkListenerProvider);

    // Fetches `app_config` and, with it, the Mixpanel token. Watched here rather than on the
    // splash because it must outlive the screen that triggered it: the splash is replaced within
    // a frame or two of the config request going out.
    ref.watch(analyticsBootstrapProvider);

    // A link that arrives while the app is already running jumps to the invite screen. The
    // cold-start case is handled by the splash instead, because the invite is already set
    // before this listener exists — and it reports its own `Deep Link Opened` for the same
    // reason, so the two paths stay distinguishable by `cold_start`.
    ref.listen(pendingInviteProvider, (_, invite) {
      if (invite == null) return;
      ref.read(analyticsProvider).track(Ev.deepLinkOpened, {
        P.linkType: 'invite',
        P.code: invite.code,
        P.inviterName: invite.inviterName,
        P.coldStart: false,
      });
      appRouter.go(Routes.invite);
    });

    return MaterialApp.router(
      title: 'Circle 360',
      debugShowCheckedModeBanner: false,
      theme: buildAppTheme(),
      routerConfig: appRouter,
    );
  }
}
