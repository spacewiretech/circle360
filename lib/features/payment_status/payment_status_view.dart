import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/router.dart';
import '../../app/theme/app_colors.dart';
import '../../app/theme/app_theme.dart';
import '../../app/theme/app_typography.dart';
import '../../widgets/primary_button.dart';
import 'payment_outcome.dart';
import 'payment_status_viewmodel.dart';

/// Where a checkout ends up: Figma `12366:12435` (failed), `12366:12476` (pending) and
/// `12366:12514` (success).
///
/// One screen rather than three, because the frames share a skeleton — centred mark, heading,
/// body — and differ only in what hangs below it. The differences that matter are behavioural,
/// and they live in [_Outcome] below.
class PaymentStatusView extends ConsumerStatefulWidget {
  const PaymentStatusView({super.key, required this.outcome});

  final PaymentOutcome outcome;

  @override
  ConsumerState<PaymentStatusView> createState() => _PaymentStatusViewState();
}

class _PaymentStatusViewState extends ConsumerState<PaymentStatusView>
    with WidgetsBindingObserver {
  Timer? _advance;

  /// Long enough to read "Payment Successful!", short enough not to feel stalled.
  static const _successDwell = Duration(seconds: 2);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);

    if (widget.outcome == PaymentOutcome.success) {
      // The frame carries no button, so the screen has to move on by itself.
      _advance = Timer(_successDwell, _toLocation);
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
    // Coming back from the UPI app is the single most likely moment for a pending mandate to
    // have just confirmed, and it is exactly when a timer-only poll is mid-backoff.
    if (state == AppLifecycleState.resumed && widget.outcome == PaymentOutcome.pending) {
      ref.read(paymentStatusViewModelProvider.notifier).check();
    }
  }

  void _toLocation() {
    if (mounted) context.go(Routes.location);
  }

  @override
  Widget build(BuildContext context) {
    final outcome = _Outcome.of(widget.outcome);

    if (widget.outcome == PaymentOutcome.pending) {
      // Confirmed while waiting: hand over to the success screen rather than jumping straight
      // to the location step, so the user gets the same confirmation everyone else does.
      ref.listen(paymentStatusViewModelProvider, (_, next) {
        if (next.confirmed && mounted) {
          context.go('/payment-status/${PaymentOutcome.success.slug}');
        }
      });
    }

    final pending = ref.watch(paymentStatusViewModelProvider);

    return PopScope(
      // Back would land on the paywall, which is either wrong (they have paid) or a dead end
      // (the mandate is still settling). Every outcome offers its own way on.
      canPop: false,
      child: Scaffold(
        backgroundColor: outcome.background,
        body: SafeArea(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: AppShape.gutter),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Spacer(flex: outcome.topFlex),
                Center(child: outcome.mark),
                const SizedBox(height: 30),
                Text(outcome.heading, style: AppText.display, textAlign: TextAlign.center),
                const SizedBox(height: 12),
                Text(outcome.body, style: AppText.body, textAlign: TextAlign.center),
                if (widget.outcome == PaymentOutcome.failed) ...[
                  const Spacer(flex: 3),
                  const _Causes(),
                  const SizedBox(height: 20),
                  PrimaryButton(
                    label: 'Retry Payment',
                    onPressed: () => context.go(Routes.subscribe),
                  ),
                  const SizedBox(height: 8),
                ] else if (widget.outcome == PaymentOutcome.pending) ...[
                  const SizedBox(height: 36),
                  PrimaryButton(
                    label: 'Check Payment Status',
                    busy: pending.checking,
                    onPressed: ref.read(paymentStatusViewModelProvider.notifier).check,
                  ),
                  if (pending.exhausted) ...[
                    const SizedBox(height: 14),
                    Text(
                      'Still not confirmed. If the amount was debited it will activate on its '
                      'own — you can safely close the app and come back.',
                      style: AppText.meta,
                      textAlign: TextAlign.center,
                    ),
                  ],
                ],
                Spacer(flex: outcome.bottomFlex),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Everything that differs between the three frames, in one place.
class _Outcome {
  const _Outcome({
    required this.mark,
    required this.heading,
    required this.body,
    required this.background,
    required this.topFlex,
    required this.bottomFlex,
  });

  final Widget mark;
  final String heading;
  final String body;
  final Color background;

  /// The frames do not sit the mark at the same height: failed is top-weighted because it
  /// carries a reasons box and a button underneath, the other two sit nearer the middle.
  final int topFlex;
  final int bottomFlex;

  static _Outcome of(PaymentOutcome outcome) => switch (outcome) {
        PaymentOutcome.success => const _Outcome(
            mark: _GlyphMark(icon: Icons.check_rounded, color: AppColors.presence),
            heading: 'Payment Successful!',
            body: 'Your Circle360 Premium subscription is now active.',
            background: AppColors.successBg,
            topFlex: 5,
            bottomFlex: 6,
          ),
        PaymentOutcome.pending => const _Outcome(
            mark: _DashedMark(),
            heading: 'Payment Pending',
            body: 'Your payment is being verified. Please wait while we confirm it.',
            background: AppColors.onboardingBg,
            topFlex: 4,
            bottomFlex: 5,
          ),
        PaymentOutcome.failed => const _Outcome(
            mark: _GlyphMark(icon: Icons.close_rounded, color: AppColors.danger),
            heading: 'Payment Failed',
            body: 'We couldn’t complete your payment. Please try again or use another '
                'payment method.',
            background: AppColors.dangerBg,
            topFlex: 3,
            bottomFlex: 0,
          ),
      };
}

/// A stroked ring around a glyph. Drawn rather than shipped as an asset, like the location
/// screen's hero — it stays crisp at any size and takes its colour from the tokens.
class _GlyphMark extends StatelessWidget {
  const _GlyphMark({required this.icon, required this.color});

  final IconData icon;
  final Color color;

  static const _size = 120.0;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: _size,
      height: _size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        border: Border.all(color: color, width: 5),
      ),
      child: Center(child: Icon(icon, size: 58, color: color)),
    );
  }
}

/// The pending ring: a broken circle, which reads as "in progress" without spinning.
///
/// Deliberately static. A spinner would promise that something is happening on this device,
/// when in fact the wait is on a bank we are only polling.
class _DashedMark extends StatelessWidget {
  const _DashedMark();

  @override
  Widget build(BuildContext context) {
    return const SizedBox(
      width: _GlyphMark._size,
      height: _GlyphMark._size,
      child: CustomPaint(painter: _DashedRingPainter()),
    );
  }
}

class _DashedRingPainter extends CustomPainter {
  const _DashedRingPainter();

  static const _dashes = 12;

  /// Of each dash-plus-gap slot, how much is painted.
  static const _dutyCycle = 0.62;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = AppColors.warning
      ..style = PaintingStyle.stroke
      ..strokeWidth = 5
      ..strokeCap = StrokeCap.round;

    // Inset by half the stroke so the ring's outer edge lands on the box, not outside it.
    final rect = Rect.fromLTWH(0, 0, size.width, size.height).deflate(paint.strokeWidth / 2);
    const slot = 2 * math.pi / _dashes;

    for (var i = 0; i < _dashes; i++) {
      canvas.drawArc(rect, i * slot, slot * _dutyCycle, false, paint);
    }
  }

  @override
  bool shouldRepaint(_DashedRingPainter oldDelegate) => false;
}

/// The three things that usually went wrong.
///
/// Static on purpose: Cashfree's own failure_reason is recorded server-side for support, but it
/// is gateway wording and often means nothing to the person reading it.
class _Causes extends StatelessWidget {
  const _Causes();

  static const _causes = [
    'Payment declined by your bank',
    'Insufficient funds',
    'Incorrect payment details',
  ];

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 18),
      decoration: BoxDecoration(
        borderRadius: AppShape.control,
        border: Border.all(color: AppColors.headingAlt),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final cause in _causes)
            Padding(
              padding: EdgeInsets.only(bottom: cause == _causes.last ? 0 : 10),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('•  ', style: AppText.body.copyWith(color: AppColors.heading)),
                  Expanded(
                    child: Text(cause, style: AppText.body.copyWith(color: AppColors.heading)),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
