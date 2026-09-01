import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/router.dart';
import '../../widgets/brand_logo.dart';
import 'splash_viewmodel.dart';

/// Figma `12310:11222` — logo centred on white while the session resolves.
class SplashView extends ConsumerWidget {
  const SplashView({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.listen(splashDestinationProvider, (_, next) {
      final destination = next.valueOrNull;
      if (destination == null || !context.mounted) return;
      context.go(destination.route);
    });

    return const Scaffold(
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            LogoPin(height: 101),
            SizedBox(height: 15),
            LogoWordmark(height: 29),
          ],
        ),
      ),
    );
  }
}
