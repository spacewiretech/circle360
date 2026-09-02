import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/router.dart';
import '../../app/theme/app_colors.dart';
import '../../app/theme/app_theme.dart';
import '../../app/theme/app_typography.dart';
import '../../data/fake/fake_session.dart';
import '../../data/models/subscription_offer.dart';
import '../../data/models/upi_app.dart';
import '../../widgets/brand_logo.dart';
import '../../widgets/map_background.dart';
import '../../widgets/primary_button.dart';
import '../../widgets/sheet_surface.dart';
import '../../widgets/terms_footer.dart';
import 'subscription_viewmodel.dart';

/// Figma `12310:11295` — the Location History paywall, now backed by Cashfree UPI Autopay.
///
/// This screen is the gate: there is no route out of it except a confirmed subscription, so it
/// deliberately cannot be dismissed with the system back gesture.
class SubscriptionView extends ConsumerWidget {
  const SubscriptionView({super.key});

  Future<void> _pickApp(
    BuildContext context,
    WidgetRef ref,
    List<UpiApp> apps,
    String? selectedId,
  ) async {
    final chosen = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (_) => _UpiAppSheet(apps: apps, selectedId: selectedId),
    );
    if (chosen != null) {
      ref.read(subscriptionViewModelProvider.notifier).selectApp(chosen);
    }
  }

  Future<void> _subscribe(BuildContext context, WidgetRef ref) async {
    final outcome = await ref.read(subscriptionViewModelProvider.notifier).subscribe();
    if (outcome == null || !context.mounted) return;
    // Every outcome gets its own screen, failures included. A payment that is still settling
    // used to be an error string on this sheet with no route forward; now it is a screen whose
    // job is to keep asking. The success screen carries on to the location step, which is the
    // one moment the user has just chosen to be here.
    context.go(Routes.paymentStatusFor(outcome));
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(subscriptionViewModelProvider);
    final offer = state.offer;

    return PopScope(
      // Back must not slip past the paywall. Onboarding is already behind us at this point,
      // so there is nowhere legitimate for it to go.
      canPop: false,
      child: Scaffold(
        // A Stack sizes itself to its non-positioned children, so it is told to fill
        // the screen — otherwise Positioned.fill resolves against a collapsed box.
        body: SizedBox.expand(
          child: Stack(
            children: [
              const Positioned.fill(child: MapBackground(center: FakeSession.home)),
              Align(
                alignment: Alignment.bottomCenter,
                child: SheetSurface(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const SizedBox(height: 32),
                      const BrandMark(),
                      const SizedBox(height: 24),
                      Text('Location History', style: AppText.display),
                      const SizedBox(height: 10),
                      Text(
                        'Track the location history of your family\nmember & Loved ones 24*7',
                        style: AppText.body,
                        textAlign: TextAlign.center,
                      ),
                      const SizedBox(height: 24),
                      if (state.loading || offer == null)
                        const Padding(
                          padding: EdgeInsets.symmetric(vertical: 20),
                          child: CircularProgressIndicator(),
                        )
                      else ...[
                        _PlanRow(offer: offer, trialAvailable: state.trialAvailable),
                        const SizedBox(height: 12),
                        _ConsentText(offer: offer, trialAvailable: state.trialAvailable),
                      ],
                      if (state.phase == SubscriptionPhase.confirming) ...[
                        const SizedBox(height: 12),
                        Text(
                          'Confirming your payment…',
                          style: AppText.meta.copyWith(color: AppColors.brand),
                          textAlign: TextAlign.center,
                        ),
                      ],
                      if (state.error != null) ...[
                        const SizedBox(height: 12),
                        Text(
                          state.error!,
                          style: AppText.meta.copyWith(
                            color: Theme.of(context).colorScheme.error,
                          ),
                          textAlign: TextAlign.center,
                        ),
                      ],
                      // Hidden when nothing is installed: the button then opens Cashfree's own
                      // checkout, which is the only route to the enter-a-UPI-ID flow.
                      if (state.selectedApp != null) ...[
                        const SizedBox(height: 14),
                        _UpiAppBar(
                          app: state.selectedApp!,
                          onChange: state.busy
                              ? null
                              : () => _pickApp(context, ref, state.upiApps,
                                  state.selectedAppId),
                        ),
                      ],
                      const SizedBox(height: 18),
                      PrimaryButton(
                        label: offer == null
                            ? 'Subscribe Now'
                            : state.trialAvailable
                                ? 'Start ${offer.trialDays}-day trial · ${offer.trialPrice}'
                                : 'Subscribe · ${offer.planPrice}/month',
                        busy: state.busy,
                        onPressed:
                            state.canSubscribe ? () => _subscribe(context, ref) : null,
                      ),
                      const SizedBox(height: 16),
                      const TermsFooter(compact: true),
                      const SizedBox(height: 16),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// "Monthly Plan            ₹3  ₹499" in a 52pt box, always selected — there is one plan.
class _PlanRow extends StatelessWidget {
  const _PlanRow({required this.offer, required this.trialAvailable});

  final SubscriptionOffer offer;
  final bool trialAvailable;

  @override
  Widget build(BuildContext context) {
    // On the trial offer the ₹499 is shown struck through beside the ₹3, which is what the
    // strike-through in the design was always for.
    final price = trialAvailable ? offer.trialPrice : offer.planPrice;
    final strike = trialAvailable ? offer.planPrice : null;

    return Container(
      height: 52,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: AppShape.control,
        border: Border.all(color: AppColors.brand, width: 1.5),
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              trialAvailable ? '${offer.trialDays}-Day Trial' : 'Monthly Plan',
              style: AppText.price.copyWith(fontWeight: FontWeight.w500),
            ),
          ),
          Text(price, style: AppText.price),
          if (strike != null) ...[
            const SizedBox(width: 6),
            Text(
              strike,
              style: AppText.price.copyWith(
                color: AppColors.muted,
                decoration: TextDecoration.lineThrough,
                decorationColor: AppColors.muted,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// "[icon] Google Pay                          Change ⌄"
///
/// The whole row is tappable, not just the "Change" text — a 52pt target beats an 8pt one, and
/// there is nothing else on the row it could be confused with.
class _UpiAppBar extends StatelessWidget {
  const _UpiAppBar({required this.app, required this.onChange});

  final UpiApp app;
  final VoidCallback? onChange;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: AppColors.surface,
      borderRadius: AppShape.control,
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onChange,
        child: Container(
          height: 52,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          decoration: BoxDecoration(
            borderRadius: AppShape.control,
            border: Border.all(color: const Color(0xFFE0E0E0)),
          ),
          child: Row(
            children: [
              _UpiAppIcon(app: app, size: 28),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  app.displayName,
                  overflow: TextOverflow.ellipsis,
                  style: AppText.price.copyWith(fontWeight: FontWeight.w500),
                ),
              ),
              if (onChange != null) ...[
                Text('Change', style: AppText.meta.copyWith(color: AppColors.muted)),
                const Icon(Icons.expand_more, size: 18, color: AppColors.muted),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// The app's own logo, or a neutral stand-in.
///
/// The SDK hands icons over as base64 and any one of them can be missing or corrupt, so the
/// placeholder is not an edge case worth skipping — on iOS the icons come from the SDK's own
/// bundle and simply may not cover a given app.
class _UpiAppIcon extends StatelessWidget {
  const _UpiAppIcon({required this.app, required this.size});

  final UpiApp app;
  final double size;

  @override
  Widget build(BuildContext context) {
    final icon = app.icon;
    if (icon == null) {
      return Container(
        width: size,
        height: size,
        decoration: const BoxDecoration(
          color: AppColors.chipBlue,
          shape: BoxShape.circle,
        ),
        child: const Icon(Icons.account_balance_wallet_outlined,
            size: 16, color: AppColors.brand),
      );
    }

    return ClipRRect(
      borderRadius: BorderRadius.circular(6),
      child: Image.memory(
        icon,
        width: size,
        height: size,
        fit: BoxFit.cover,
        // Decoded bytes that turn out not to be a valid image would otherwise throw during
        // paint, taking the whole paywall down with them.
        errorBuilder: (context, error, stack) => _UpiAppIcon(
          app: UpiApp(id: app.id, displayName: app.displayName),
          size: size,
        ),
      ),
    );
  }
}

/// "Pay with UPI — select an app to complete payment", over the installed apps.
class _UpiAppSheet extends StatelessWidget {
  const _UpiAppSheet({required this.apps, required this.selectedId});

  final List<UpiApp> apps;
  final String? selectedId;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      top: false,
      child: Container(
        decoration: const BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
        ),
        padding: const EdgeInsets.symmetric(vertical: 12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Center(
              child: Container(
                width: 36,
                height: 4,
                decoration: BoxDecoration(
                  color: const Color(0xFFE0E0E0),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            const SizedBox(height: 18),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Text('Pay with UPI', style: AppText.title),
            ),
            const SizedBox(height: 4),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Text(
                'Select an app to complete payment',
                style: AppText.meta.copyWith(color: AppColors.muted),
              ),
            ),
            const SizedBox(height: 8),
            // Shrink-wrapped and scrollable: a phone with eight UPI apps must not push the
            // sheet past the top of the screen.
            Flexible(
              child: ListView.builder(
                shrinkWrap: true,
                padding: const EdgeInsets.symmetric(vertical: 4),
                itemCount: apps.length,
                itemBuilder: (context, index) {
                  final app = apps[index];
                  return ListTile(
                    onTap: () => Navigator.of(context).pop(app.id),
                    leading: _UpiAppIcon(app: app, size: 36),
                    title: Text(app.displayName, style: AppText.rowLabel),
                    trailing: app.id == selectedId
                        ? const Icon(Icons.check, size: 20, color: AppColors.brand)
                        : const Icon(Icons.chevron_right, size: 20, color: AppColors.muted),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The mandate disclosure.
///
/// UPI Autopay requires the recurring amount and cadence to be stated before the user
/// authorises, so this is a compliance requirement rather than marketing copy — it must stay on
/// screen next to the button, not behind a link.
class _ConsentText extends StatelessWidget {
  const _ConsentText({required this.offer, required this.trialAvailable});

  final SubscriptionOffer offer;
  final bool trialAvailable;

  @override
  Widget build(BuildContext context) {
    return Text(
      trialAvailable
          ? offer.consent
          : '${offer.planPrice}/month will be auto-debited from your UPI. Cancel anytime.',
      style: AppText.legal.copyWith(color: AppColors.muted),
      textAlign: TextAlign.center,
    );
  }
}
