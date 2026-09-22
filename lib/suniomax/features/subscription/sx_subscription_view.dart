import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../data/analytics/analytics.dart';
import '../../../data/analytics/analytics_events.dart';
import '../../../data/models/subscription_offer.dart';
import '../../../data/providers.dart';
import '../../../features/subscription/promo_video.dart';
import '../../../features/subscription/subscription_viewmodel.dart';
import '../../app/router.dart';
import '../../data/onboarding_audio.dart';
import '../../app/theme/sx_colors.dart';
import '../../app/theme/sx_theme.dart';
import '../../app/theme/sx_typography.dart';
import '../../widgets/sx_primary_button.dart';
import '../../widgets/sx_sheet_surface.dart';
import '../../widgets/sx_wordmark.dart';

/// Figma `13511:14682` — the SunioMax paywall.
///
/// Runs on Circle360's `SubscriptionViewModel` without modification, because it is the same
/// mandate on the same Cashfree plan: the client sends no amount, no plan id and no status, and
/// everything that decides what a user is charged is resolved server-side. What differs here is
/// the frame around it.
///
/// **The prices shown are the prices charged.** They come from `trial_price_label` and
/// `plan_price_label` in `app_config`, the same two rows Circle360 reads. The Figma frame reads
/// "₹99 ₹299", which is not what this plan debits — and a paywall that states one amount while
/// the UPI mandate authorises another is both a consent failure and a lie, so the numbers are
/// read from config rather than typed in. Changing what is charged means a new Cashfree plan,
/// not new copy.
///
/// Like Circle360's, it is the gate: there is no route out except a confirmed subscription, so
/// the system back gesture is deliberately refused.
class SxSubscriptionView extends ConsumerStatefulWidget {
  const SxSubscriptionView({super.key});

  @override
  ConsumerState<SxSubscriptionView> createState() => _SxSubscriptionViewState();
}

class _SxSubscriptionViewState extends ConsumerState<SxSubscriptionView> {
  bool _muted = true;

  Future<void> _subscribe() async {
    final outcome = await ref
        .read(subscriptionViewModelProvider.notifier)
        .subscribe();
    // Null means the tap was ignored — a second press while the first is still in flight. It is
    // not an outcome and must not navigate.
    if (outcome == null || !mounted) return;
    context.go(SxRoutes.paymentStatusFor(outcome));
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(subscriptionViewModelProvider);
    final offer = state.offer;

    // `suniomax_paywall_video_url`, falling back to Circle360's `paywall_video_url` — which is
    // what both apps showed before the split, and is footage of a map and a family that SunioMax
    // does not sell. The fallback is what lets the new row ship blank and change nothing.
    //
    // Served from the six-hour config cache rather than its own query. Circle360's paywall reads
    // its row uncached because it warms a player during onboarding and a stale URL would cost it
    // that; SunioMax warms nothing, so the cache is the right trade.
    final config = ref.watch(appConfigProvider).valueOrNull;
    final videoUrl = config == null ? '' : sunioPaywallVideoUrl(config);

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) {
          // A user pressing back repeatedly on the paywall is trying to leave and cannot, which
          // is invisible everywhere else — the navigator observer only sees pops that happened.
          analytics.track(Ev.backPressed, {
            P.screen: 'SX Paywall',
            P.blocked: true,
          });
        }
      },
      child: Scaffold(
        backgroundColor: SxColors.surface,
        body: Column(
          children: [
            Expanded(
              child: SafeArea(
                bottom: false,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(
                    SxShape.gutter,
                    16,
                    SxShape.gutter,
                    16,
                  ),
                  child: PromoVideo(
                    url: videoUrl,
                    muted: _muted,
                    // Quiet from the moment the button is tapped: `phase` goes to `opening`
                    // before the mandate call, and a promo talking over the handover to a UPI app
                    // is unforgivable.
                    paused: state.busy,
                    onToggleMute: () => setState(() => _muted = !_muted),
                  ),
                ),
              ),
            ),
            SxSheetSurface(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const SizedBox(height: 26),
                  const SxWordmark(height: 34),
                  const SizedBox(height: 20),
                  Text(
                    'Let Your Voice Do More.',
                    style: SxText.display,
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Control, protect, and find your phone\nwith SunioMax.',
                    style: SxText.body,
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 22),
                  if (state.loading || offer == null)
                    const Padding(
                      padding: EdgeInsets.symmetric(vertical: 22),
                      child: CircularProgressIndicator(),
                    )
                  else ...[
                    _SxPlanRow(
                      offer: offer,
                      trialAvailable: state.trialAvailable,
                    ),
                    const SizedBox(height: 10),
                    Text(
                      state.trialAvailable
                          ? offer.consent
                          : '${offer.planPrice}/month will be auto-debited from your '
                                'UPI. Cancel anytime.',
                      style: SxText.legal.copyWith(
                        color: SxColors.muted,
                        height: 1.5,
                      ),
                      textAlign: TextAlign.center,
                    ),
                  ],
                  if (state.phase == SubscriptionPhase.confirming) ...[
                    const SizedBox(height: 12),
                    Text(
                      'Confirming your payment…',
                      style: SxText.rowSubtitle.copyWith(color: SxColors.brand),
                      textAlign: TextAlign.center,
                    ),
                  ],
                  if (state.error != null) ...[
                    const SizedBox(height: 12),
                    Text(
                      state.error!,
                      style: SxText.rowSubtitle.copyWith(
                        color: SxColors.danger,
                      ),
                      textAlign: TextAlign.center,
                    ),
                  ],
                  const SizedBox(height: 18),
                  SxPrimaryButton(
                    label: 'Subscribe Now',
                    // Pinned, like Circle360's: the app's single most important button must not
                    // change id when the pricing copy does.
                    analyticsId: 'sx_subscribe',
                    busy: state.busy,
                    onPressed: state.canSubscribe ? _subscribe : null,
                  ),
                  const SizedBox(height: 14),
                  const SxTermsFooter(compact: true),
                  const SizedBox(height: 12),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// "Monthly Plan            ₹3  ₹499" — one plan, always selected.
///
/// The struck-through price is the one *not* being charged today: on the trial offer that is the
/// monthly price, shown beside the trial amount. It is never a price this plan does not have.
class _SxPlanRow extends StatelessWidget {
  const _SxPlanRow({required this.offer, required this.trialAvailable});

  final SubscriptionOffer offer;
  final bool trialAvailable;

  @override
  Widget build(BuildContext context) {
    final price = trialAvailable ? offer.trialPrice : offer.planPrice;
    final strike = trialAvailable ? offer.planPrice : offer.strikePrice;

    return Container(
      height: 58,
      padding: const EdgeInsets.symmetric(horizontal: 18),
      decoration: BoxDecoration(
        color: SxColors.surface,
        borderRadius: SxShape.control,
        border: Border.all(color: SxColors.brand, width: 1.6),
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              trialAvailable ? '${offer.trialDays}-Day Trial' : 'Monthly Plan',
              style: SxText.planName,
            ),
          ),
          Text(price, style: SxText.price),
          if (strike != null) ...[
            const SizedBox(width: 8),
            Text(strike, style: SxText.priceStrike),
          ],
        ],
      ),
    );
  }
}
