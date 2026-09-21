import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../app/router.dart';
import '../../app/theme/app_colors.dart';
import '../../app/theme/app_theme.dart';
import '../../app/theme/app_typography.dart';
import '../../data/analytics/analytics.dart';
import '../../data/analytics/analytics_events.dart';
import '../../data/analytics/att_consent.dart';
import '../../app/env.dart';
import '../../data/fake/fake_session.dart';
import '../../data/models/subscription_offer.dart';
import '../../data/models/upi_app.dart';
import '../../data/repositories/app_config_repository.dart';
import '../../widgets/brand_logo.dart';
import '../../widgets/map_background.dart';
import '../../widgets/primary_button.dart';
import '../../widgets/sheet_surface.dart';
import '../../widgets/terms_footer.dart';
import 'promo_video.dart';
import 'promo_video_warmup.dart';
import 'subscription_viewmodel.dart';

/// Figma `12310:11295` — the Location History paywall, now backed by Cashfree UPI Autopay.
///
/// This screen is the gate: there is no route out of it except a confirmed subscription, so it
/// deliberately cannot be dismissed with the system back gesture.
class SubscriptionView extends ConsumerStatefulWidget {
  const SubscriptionView({super.key});

  @override
  ConsumerState<SubscriptionView> createState() => _SubscriptionViewState();
}

class _SubscriptionViewState extends ConsumerState<SubscriptionView> {
  /// The promo starts with sound on, and this is where turning it off is remembered.
  ///
  /// Local to the screen rather than to the ViewModel on purpose: a speaker icon is not part of a
  /// payment machine, and `subscriptionViewModelProvider` is deliberately not autoDispose — a
  /// choice made here would otherwise outlive the screen, the payment, and the session.
  bool _muted = false;

  /// `app_config.paywall_video_url`, empty until it arrives and empty forever if it never does.
  String _videoUrl = '';

  /// Read as its own one-row query rather than through `appConfigProvider`.
  ///
  /// That map is served from a six-hour SharedPreferences cache, which is right for prices and
  /// limits and wrong for this: a URL pasted into the dashboard would not reach a device that had
  /// launched in the meantime until the cache aged out, and the paywall would sit there showing
  /// no video with nothing visibly wrong. One row, no cache, no waiting.
  ///
  /// Only reached when [PromoVideoWarmup] has no answer: every user who came through onboarding
  /// has had this row for a minute already. What is left is the paths that skip onboarding
  /// entirely — a lapsed user routed here by the splash, an eviction by `EntitlementGate`, the
  /// retry button on a failed payment — and for those this is exactly the code it always was.
  ///
  /// A failure leaves whatever [initState] seeded from `app.env` in place, which is why the catch
  /// only logs: the env value is already on screen and overwriting it with `''` would take the
  /// card away.
  Future<void> _loadVideoUrl() async {
    if (!Env.hasSupabase) return;
    try {
      final row = await Supabase.instance.client
          .from('app_config')
          .select('value')
          .eq('key', 'paywall_video_url')
          .maybeSingle()
          .timeout(const Duration(seconds: 8));

      // A row that exists and is blank is a deliberate "show no promo" and is taken at its word.
      // No row at all is not an answer, so the seeded value stands.
      if (!mounted || row == null) return;
      setState(() => _videoUrl = (row['value'] as String?)?.trim() ?? '');
    } catch (error) {
      // The paywall's job is to take money, and it can do that with no promo at all.
      debugPrint('[paywall] could not read paywall_video_url: $error');
    }
  }

  @override
  void initState() {
    super.initState();

    // Synchronously, before the first build, and that is the whole point: with the URL already in
    // hand the card is laid out at its real height in frame one. Waiting on the query instead is
    // what used to make the promo appear out of nothing and shove the sheet down behind it —
    // `PromoVideo` renders no card at all until it has a usable URL.
    final warmUrl = ref.read(promoVideoWarmupProvider).url;
    if (warmUrl != null) {
      _videoUrl = warmUrl;
    } else {
      // The `APP_CONFIG_PAYWALL_VIDEO_URL` line in `app.env`, seeded here for the same reason the
      // warm URL is: it costs nothing and the card gets its real height in frame one. Wired by
      // hand because this row is the one key outside `appConfigProvider`'s ladder, so nothing
      // else would ever apply the env fallback to it. The query below overrides it if it answers.
      _videoUrl = appConfigFallbacks()['paywall_video_url']?.trim() ?? '';
      unawaited(_loadVideoUrl());
    }
    // Stateful purely for this. `Paywall Offer Loaded` cannot stand in as the view event: the
    // ViewModel is not autoDispose, so `_load` runs once for the life of the app and a user sent
    // back here by a failed payment or a lapsed trial would never be counted a second time.
    //
    // Deferred a frame because the navigator observer's `Screen Viewed` for this route is emitted
    // as part of the same navigation, and the two read better in that order.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final state = ref.read(subscriptionViewModelProvider);
      analytics.track(Ev.paywallViewed, {
        P.trialAvailable: state.trialAvailable,
        // Whether the flags above are authoritative yet. The offer is still in flight on a first
        // view, and `trial_available` defaults to true until the user's history comes back.
        P.state: state.loading ? 'loading' : 'loaded',
      });

      // iOS only, and deliberately here rather than at launch: this is the last screen before a
      // purchase, so a granted IDFA still reaches the conversion event, and the user has already
      // been through onboarding rather than meeting a permission dialog cold. Not awaited — the
      // paywall must paint whether or not the user has answered.
      unawaited(ensureTrackingConsent());
    });
  }

  Future<void> _pickApp(
    BuildContext context,
    WidgetRef ref,
    List<UpiApp> apps,
    String? selectedId,
  ) async {
    analytics.track(Ev.upiPickerOpened, {
      P.appId: selectedId,
      P.availableCount: apps.length,
    });

    final chosen = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: Colors.transparent,
      // Named so the observer reports the sheet as its own surface rather than as an anonymous
      // route over the paywall.
      routeSettings: const RouteSettings(name: 'upi-picker'),
      builder: (_) => _UpiAppSheet(apps: apps, selectedId: selectedId),
    );

    if (chosen == null) {
      // Opening the picker and backing out is a real signal — the user looked for their bank's
      // app and did not find it — and until now it left no trace at all: a null result was
      // simply dropped.
      analytics.track(Ev.upiPickerDismissed, {
        P.appId: selectedId,
        P.availableCount: apps.length,
      });
      return;
    }

    ref.read(subscriptionViewModelProvider.notifier).selectApp(chosen);
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
  Widget build(BuildContext context) {
    final state = ref.watch(subscriptionViewModelProvider);
    final offer = state.offer;

    return PopScope(
      // Back must not slip past the paywall. Onboarding is already behind us at this point,
      // so there is nowhere legitimate for it to go.
      canPop: false,
      // The refusal is worth recording. A user pressing back repeatedly on the paywall is
      // trying to leave and cannot, and that is invisible everywhere else — the navigator
      // observer only ever sees pops that actually happened.
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) {
          analytics.track(Ev.backPressed, {P.screen: 'Paywall', P.blocked: true});
        }
      },
      child: Scaffold(
        // A Stack sizes itself to its non-positioned children, so it is told to fill the
        // screen — otherwise Positioned.fill resolves against a collapsed box.
        body: SizedBox.expand(
          child: Stack(
            children: [
              // Back behind the promo rather than replaced by it. The video is a card, not a
              // full-bleed background, and the band of bare page around it read as an unfinished
              // screen — the map is what the rest of the app puts under a floating card.
              const Positioned.fill(child: MapBackground(center: FakeSession.home)),
              Column(
                children: [
                  // Expanded rather than a fixed height so a sheet that grows — an error line,
                  // the UPI bar appearing after discovery — takes the room from the promo
                  // instead of overflowing, and so the promo can decide for itself that what is
                  // left is too little to be worth showing.
                  Expanded(
                    child: SafeArea(
                      bottom: false,
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(
                            AppShape.gutter, 12, AppShape.gutter, 16),
                        child: PromoVideo(
                          url: _videoUrl,
                          muted: _muted,
                          // The player onboarding opened, if it opened one for this same URL and
                          // nothing has claimed it yet. Ownership transfers on the call, so the
                          // widget disposes it exactly as it disposes its own. `claim` rather than
                          // `take` so a user who beat the warm-up here waits for it instead of
                          // starting a second download of the same file.
                          adopt: ref.read(promoVideoWarmupProvider).claim,
                          // Quiet from the moment the button is tapped. `phase` goes to
                          // `opening` before the mandate call, and there are a few hundred
                          // milliseconds of Edge Function and intent launch before the UPI app
                          // actually takes the foreground — the lifecycle observer cannot cover
                          // that gap, and a promo talking over the most important moment of the
                          // funnel is unforgivable.
                          paused: state.busy,
                          onToggleMute: () => setState(() => _muted = !_muted),
                        ),
                      ),
                    ),
                  ),
                  SheetSurface(
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
                          // Pinned because the label carries the price and the trial length, both
                          // of which come from config: without this the app's single most
                          // important button would change id whenever the pricing copy changed.
                          analyticsId: 'subscribe',
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
                ],
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
