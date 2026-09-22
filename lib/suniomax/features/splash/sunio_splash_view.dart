import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/router.dart';
import '../../app/theme/sx_colors.dart';
import '../../widgets/sx_wordmark.dart';
import 'sunio_splash_viewmodel.dart';

/// Figma `13538:15312` — the wordmark on white while the stored session resolves.
///
/// Mirrors Circle360's `SplashView`: no spinner, because the answer usually arrives within a frame
/// or two of the first paint and a spinner that flashes reads worse than a still logo.
class SunioSplashView extends ConsumerWidget {
  const SunioSplashView({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.listen(sunioSplashDestinationProvider, (_, next) {
      final destination = next.valueOrNull;
      if (destination != null) context.go(destination.route);
    });

    return const Scaffold(
      backgroundColor: SxColors.surface,
      body: Center(child: SxWordmark(height: 54)),
    );
  }
}
