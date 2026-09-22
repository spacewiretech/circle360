import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../data/analytics/analytics.dart';
import '../../../data/analytics/analytics_events.dart';
import '../../../features/payment_status/payment_outcome.dart';
import '../../../features/payment_status/payment_status_viewmodel.dart';
import '../../../features/subscription/subscription_viewmodel.dart';
import '../../app/router.dart';
import '../../app/theme/sx_colors.dart';
import '../../app/theme/sx_theme.dart';
import '../../app/theme/sx_typography.dart';
import '../../widgets/sx_primary_button.dart';

/// The three payment outcomes, as one screen.
///
/// Mirrors Circle360's `PaymentStatusView` — including the part that matters most, which is that
/// `pending` is a real state and not a failure: the UPI app handing control back and the money
/// moving are different claims, and the gap between them is somewhere a user can genuinely sit.
/// The polling behind it is `PaymentStatusViewModel`, unchanged.
///
/// Success leads to `/sx/home` rather than a location step, because SunioMax never asks for a
/// position.
class SxPaymentStatusView extends ConsumerStatefulWidget {
  const SxPaymentStatusView({super.key, required this.outcome});

  final PaymentOutcome outcome;

  @override
  ConsumerState<SxPaymentStatusView> createState() =>
      _SxPaymentStatusViewState();
}

class _SxPaymentStatusViewState extends ConsumerState<SxPaymentStatusView>
    with WidgetsBindingObserver {
  Timer? _advance;

  /// Long enough to read "Payment Successful!", short enough not to feel stalled.
  static const _successDwell = Duration(seconds: 2);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);

    // The observer reports all three as one "SX Payment Status" screen, because the outcome is a
    // path parameter and go_router puts the *pattern* in `RouteSettings.name`. Which of the three
    // it was is the entire point, so it is reported here as a property.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      analytics.track(Ev.paymentStatusViewed, {
        P.outcome: widget.outcome.slug,
        P.paymentAttemptId: ref
            .read(subscriptionViewModelProvider.notifier)
            .attemptId,
      });
    });

    if (widget.outcome == PaymentOutcome.success) {
      // The frame carries no button, so the screen moves on by itself.
      _advance = Timer(_successDwell, _toHome);
    } else if (widget.outcome == PaymentOutcome.pending) {
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => ref.read(paymentStatusViewModelProvider.notifier).start(),
      );
    }
  }

  @override
  void dispose() {
    _advance?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Returning from the UPI app is the most likely moment for a pending mandate to have just
    // confirmed, and exactly when a timer-only poll is mid-backoff.
    if (state == AppLifecycleState.resumed &&
        widget.outcome == PaymentOutcome.pending) {
      ref
          .read(paymentStatusViewModelProvider.notifier)
          .check(trigger: 'resume');
    }
  }

  void _toHome() {
    if (mounted) context.go(SxRoutes.home);
  }

  @override
  Widget build(BuildContext context) {
    if (widget.outcome == PaymentOutcome.pending) {
      // Confirmed while waiting: hand over to the success screen rather than jumping straight to
      // Home, so this user gets the same confirmation everyone else does.
      ref.listen(paymentStatusViewModelProvider, (_, next) {
        if (next.confirmed && mounted) {
          context.go(SxRoutes.paymentStatusFor(PaymentOutcome.success));
        }
      });
    }

    final polling = ref.watch(paymentStatusViewModelProvider);

    return Scaffold(
      backgroundColor: switch (widget.outcome) {
        PaymentOutcome.success => const Color(0xFFF7FDF9),
        PaymentOutcome.failed => const Color(0xFFFFFDFC),
        PaymentOutcome.pending => SxColors.surface,
      },
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: SxShape.gutter),
          child: Column(
            children: [
              const Spacer(flex: 3),
              _Badge(outcome: widget.outcome),
              const SizedBox(height: 22),
              Text(_title, style: SxText.outcome, textAlign: TextAlign.center),
              const SizedBox(height: 10),
              Text(
                _message(polling),
                style: SxText.body,
                textAlign: TextAlign.center,
              ),
              const Spacer(flex: 2),
              if (widget.outcome == PaymentOutcome.failed) ...[
                const _FailureReasons(),
                const SizedBox(height: 22),
                SxPrimaryButton(
                  label: 'Retry Payment',
                  analyticsId: 'sx_retry_payment',
                  onPressed: () => context.go(SxRoutes.subscribe),
                ),
              ],
              if (widget.outcome == PaymentOutcome.pending) ...[
                SxPrimaryButton(
                  label: 'Check again',
                  analyticsId: 'sx_payment_check_again',
                  busy: polling.checking,
                  onPressed: () => ref
                      .read(paymentStatusViewModelProvider.notifier)
                      .check(trigger: 'manual'),
                ),
                const SizedBox(height: 12),
              ],
              const SizedBox(height: 20),
            ],
          ),
        ),
      ),
    );
  }

  String get _title => switch (widget.outcome) {
    PaymentOutcome.success => 'Payment Successful!',
    PaymentOutcome.failed => 'Payment Failed',
    PaymentOutcome.pending => 'Confirming your payment',
  };

  String _message(PaymentStatusState polling) => switch (widget.outcome) {
    PaymentOutcome.success =>
      'Your SunioMax Premium subscription is now active.',
    PaymentOutcome.failed =>
      'We couldn’t complete your payment.\nPlease try again or use another '
          'payment method.',
    // The copy admits it is taking longer than it should rather than repeating itself, which
    // is the honest thing to say once a dozen polls have gone unanswered.
    PaymentOutcome.pending =>
      polling.exhausted
          ? 'This is taking longer than usual. Your bank may still be processing it — '
                'we will unlock the app as soon as it clears.'
          : 'Your bank is still confirming the mandate. This usually takes a few seconds.',
  };
}

/// The tick, the cross, or a spinner.
class _Badge extends StatelessWidget {
  const _Badge({required this.outcome});

  final PaymentOutcome outcome;

  @override
  Widget build(BuildContext context) {
    if (outcome == PaymentOutcome.pending) {
      return const SizedBox(
        height: 74,
        width: 74,
        child: CircularProgressIndicator(strokeWidth: 3),
      );
    }

    final success = outcome == PaymentOutcome.success;
    final colour = success ? SxColors.success : SxColors.danger;

    return Container(
      height: 74,
      width: 74,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        border: Border.all(color: colour, width: 3.5),
      ),
      child: Icon(success ? Icons.check : Icons.close, size: 42, color: colour),
    );
  }
}

/// The bulleted box on the failure frame.
///
/// Generic on purpose. The real decline reason comes from the bank through Cashfree and is
/// frequently either absent or unfit to show a user, so this lists what it is usually one of
/// rather than asserting which.
class _FailureReasons extends StatelessWidget {
  const _FailureReasons();

  static const _reasons = [
    'Payment declined by your bank',
    'Insufficient funds',
    'Incorrect payment details',
  ];

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
      decoration: BoxDecoration(
        borderRadius: SxShape.card,
        border: Border.all(color: SxColors.heading, width: 1.2),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final reason in _reasons)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 3),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '•  ',
                    style: SxText.body.copyWith(color: SxColors.heading),
                  ),
                  Expanded(
                    child: Text(
                      reason,
                      style: SxText.body.copyWith(color: SxColors.heading),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
