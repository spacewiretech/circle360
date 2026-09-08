import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:share_plus/share_plus.dart';

import '../../app/assets.dart';
import '../../app/router.dart';
import '../../app/theme/app_colors.dart';
import '../../app/theme/app_theme.dart';
import '../../app/theme/app_typography.dart';
import '../../data/analytics/analytics.dart';
import '../../data/analytics/analytics_events.dart';
import '../../data/entitlement.dart';
import '../../data/fake/fake_session.dart';
import '../../data/location/location_controller.dart';
import '../../data/providers.dart';
import '../../location_service.dart';
import '../../widgets/add_person_sheet.dart';
import '../../widgets/avatar.dart';
import '../../widgets/brand_logo.dart';
import '../../widgets/floating_pill.dart';
import '../../widgets/map_background.dart';
import '../../widgets/person_card.dart';
import '../../widgets/primary_button.dart';
import '../../widgets/request_card.dart';
import '../../widgets/sheet_surface.dart';
import '../../widgets/tracking_banner.dart';
import 'home_viewmodel.dart';

/// Collects a name and number, then either connects or hands the invite to the share sheet.
///
/// The invite branch confirms first. Opening the system share sheet unannounced, straight out
/// of an "Add" tap, reads as the app having done something on the user's behalf — and what it
/// is about to do is message a third party.
Future<void> _addPerson(BuildContext context, WidgetRef ref) async {
  final analytics = ref.read(analyticsProvider);
  analytics.track(Ev.addPersonSheetOpened, {P.source: 'home'});

  final draft = await showAddPersonSheet(context, title: 'Add Person');
  if (draft == null) {
    analytics.track(Ev.addPersonSheetDismissed, {P.source: 'home'});
    return;
  }

  final result = await ref
      .read(homeViewModelProvider.notifier)
      .addPerson(name: draft.name, phone: draft.phone);

  final shareText = result?.shareText;
  // A null result is the ViewModel refusing — a duplicate, the three-person cap, or a failed
  // call. A non-null result with no share text is the happy path: the number is already a user
  // and the two are now connected without an invite ever being needed.
  analytics.track(
    result == null ? Ev.addPersonFailed : Ev.addPersonSubmitted,
    {
      P.source: 'home',
      P.isExistingUser: result == null ? null : shareText == null,
      if (result == null) P.message: ref.read(homeViewModelProvider).message,
    },
  );

  if (shareText == null || !context.mounted) return;

  final who = draft.name.trim().isEmpty ? 'They' : draft.name.trim();
  analytics.track(Ev.inviteDialogShown);
  final send = await showDialog<bool>(
    context: context,
    // Named so the observer reports the confirmation as its own surface.
    routeSettings: const RouteSettings(name: 'invite-confirm'),
    builder: (context) => AlertDialog(
      title: Text('$who isn\'t on Loc360 yet'),
      content: Text(
        'Send $who an invite? They\'ll be connected to you automatically once they install '
        'the app and sign in with ${draft.phone}.',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('Not now'),
        ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(true),
          child: const Text('Send invite'),
        ),
      ],
    ),
  );

  if (send == true) {
    analytics.track(Ev.inviteSent, {P.source: 'home'});
    await SharePlus.instance.share(ShareParams(text: shareText));
  } else {
    // Reaching the invite dialog and declining is a different outcome from never getting there,
    // and it is the step where an added person quietly fails to become a connection.
    analytics.track(Ev.inviteDialogDismissed, {P.source: 'home'});
  }
}

/// Figma `12310:11331` (empty), `12330:11354` (list) and `12330:11431` (expanded) — one
/// screen with three states.
class HomeView extends ConsumerStatefulWidget {
  const HomeView({super.key});

  @override
  ConsumerState<HomeView> createState() => _HomeViewState();
}

class _HomeViewState extends ConsumerState<HomeView> with WidgetsBindingObserver {
  final _map = MapController();
  final _sheet = DraggableScrollableController();

  /// Tall enough for an open card's action row to clear the bottom of the screen.
  static const _expandedSheetSize = 0.72;

  /// `Home Viewed` waits for the first snapshot, so it can carry the counts that make it useful.
  /// The observer's own `Screen Viewed` already covers the bare arrival.
  bool _reportedView = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // Re-push the session token on every entry to Home. A token refreshed by a re-sign-in
    // would otherwise never reach the native uploader, which cannot ask for one itself.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(locationControllerProvider.notifier).syncSession();
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Permission can be revoked from Settings while the app is backgrounded, and on Android an
    // OEM battery manager can kill the service outright. Neither sends a notification, so the
    // only reliable moment to notice is coming back.
    if (state == AppLifecycleState.resumed) {
      ref.read(locationControllerProvider.notifier).refresh();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _map.dispose();
    _sheet.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(homeViewModelProvider);
    final location = ref.watch(locationControllerProvider);

    if (!state.loading && !_reportedView) {
      _reportedView = true;
      analytics.track(Ev.homeViewed, {
        P.peopleCount: state.people.length,
        P.requestsCount: state.requests.length,
        P.state: state.people.isEmpty ? 'empty' : 'list',
        P.trackingActive: location.permission.canTrack,
        P.permission: location.permission.name,
      });
    }

    // The mandate warning, reported once per state rather than once per rebuild. Whether it is
    // ever seen is the precondition for `Manage Billing Tapped` meaning anything.
    ref.listen(entitlementProvider.select((user) => user?.billingState), (_, billing) {
      if (billing != null) {
        analytics.track(Ev.billingIssueShown, {P.billingState: billing.name});
      }
    });

    // Action confirmations surface as a SnackBar, then are cleared so they fire once.
    ref.listen(homeViewModelProvider.select((s) => s.message), (_, message) {
      if (message == null) return;
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text(message)));
      ref.read(homeViewModelProvider.notifier).consumeMessage();
    });

    // Opening a card pans the map onto that person and lifts the sheet far enough for the
    // action row to show, as in the expanded Figma frame.
    //
    // Keyed on the id, not the person: this fires an animation and takes the map away from the
    // user, so it has to run on "a card was opened" and nothing else. Selecting the person
    // instead re-ran it on every poll — re-centring the map, resetting the zoom, and dragging
    // the sheet back up from wherever the user had put it, twice a minute.
    ref.listen(homeViewModelProvider.select((s) => s.expandedId), (previous, id) {
      if (id == null || id == previous) return;
      final position = ref.read(homeViewModelProvider).expanded?.position;
      if (position == null) return;
      _map.move(position, 16);
      if (_sheet.isAttached && _sheet.size < _expandedSheetSize) {
        _sheet.animateTo(
          _expandedSheetSize,
          duration: const Duration(milliseconds: 250),
          curve: Curves.easeOutCubic,
        );
      }
    });

    return Scaffold(
      // A Stack sizes itself to its non-positioned children, so it is told to fill
      // the screen — otherwise Positioned.fill resolves against a collapsed box.
      body: SizedBox.expand(
        child: Stack(
          children: [
            Positioned.fill(
              child: MapBackground(
                controller: _map,
                center: state.expanded?.position ?? location.here ?? FakeSession.home,
                markers: state.mappable,
                focused: state.expanded,
                me: location.here,
                interactive: true,
              ),
            ),
            SafeArea(
              bottom: false,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(14, 8, 14, 0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        _ProfileButton(onTap: () => context.push(Routes.profile)),
                        const Spacer(),
                        FloatingPill(
                          label: 'Emergency Contacts',
                          trailing:
                              Image.asset(Img.emergencyPill, width: 24, height: 26),
                          onTap: () => context.push(Routes.emergency),
                        ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    _StatusStrip(location: location, offline: state.offline),
                  ],
                ),
              ),
            ),
            if (state.isEmpty)
              const Align(alignment: Alignment.bottomCenter, child: _EmptyHomeSheet())
            else
              DraggableSheetSurface(
                controller: _sheet,
                builder: (context, controller) => _PeopleList(controller: controller),
              ),
          ],
        ),
      ),
    );
  }
}

/// Whether this device's own location is going out, and whether the list on screen is live.
///
/// Two separate truths that are easy to conflate: a working upload with a stale list means
/// "they can find me, I can't find them", and the user needs to be able to tell.
class _StatusStrip extends ConsumerWidget {
  const _StatusStrip({required this.location, required this.offline});

  final LocationState location;
  final bool offline;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final problem = location.problem;
    // A mandate that has stalled. Shown above the location banner because it is the more
    // urgent of the two: location can be turned back on any time, but a subscription only
    // stays fixable until the paid period runs out. The user is still fully entitled here —
    // this is the warning that gives them a chance to act before that changes.
    final billing = ref.watch(entitlementProvider)?.billingState;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (billing != null) ...[
          TrackingBanner(
            message: billing.message,
            actionLabel: 'Manage',
            // The banner is a paying user's only warning that their mandate is about to stop
            // collecting. How many people it reaches, and how many act on it, is the difference
            // between recoverable churn and silent churn.
            onTap: () {
              analytics.track(Ev.manageBillingTapped, {
                P.billingState: billing.name,
              });
              context.push(Routes.settings);
            },
          ),
          const SizedBox(height: 8),
        ],
        if (problem != null)
          TrackingBanner(
            message: problem,
            actionLabel: location.permission == LocationPermission.deniedForever
                ? 'Settings'
                : 'Turn on',
            onTap: () {
              analytics.track(Ev.trackingBannerTapped, {
                P.permission: location.permission.name,
              });
              final controller = ref.read(locationControllerProvider.notifier);
              if (location.permission == LocationPermission.deniedForever) {
                controller.openAppSettings();
              } else {
                controller.startSharing();
              }
            },
          )
        else
          const Align(alignment: Alignment.centerLeft, child: TrackingOkChip()),
        if (offline) ...[
          const SizedBox(height: 8),
          const Align(
            alignment: Alignment.centerLeft,
            child: TrackingOkChip(label: 'Offline — showing last known'),
          ),
        ],
      ],
    );
  }
}

class _ProfileButton extends StatelessWidget {
  const _ProfileButton({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: const Avatar(asset: Img.avatarMe, size: 50, ring: Colors.white),
    );
  }
}

/// Figma `12310:11331` — nobody is being tracked yet.
class _EmptyHomeSheet extends ConsumerWidget {
  const _EmptyHomeSheet();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return SheetSurface(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(height: 32),
          const BrandMark(),
          const SizedBox(height: 28),
          Text('Location History', style: AppText.display),
          const SizedBox(height: 10),
          Text(
            'Track the location history of your family\nmember & Loved ones 24*7',
            style: AppText.body,
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 32),
          PrimaryButton(label: 'Add Person', onPressed: () => _addPerson(context, ref)),
          const SizedBox(height: 24),
        ],
      ),
    );
  }
}

/// Figma `12330:11354` / `12330:11431` — the tracked list inside the draggable sheet.
class _PeopleList extends ConsumerWidget {
  const _PeopleList({required this.controller});

  final ScrollController controller;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(homeViewModelProvider);
    final viewModel = ref.read(homeViewModelProvider.notifier);

    return ListView(
      controller: controller,
      padding: const EdgeInsets.fromLTRB(
        AppShape.gutter,
        33,
        AppShape.gutter,
        AppShape.gutter,
      ),
      children: [
        const Center(child: BrandMark()),
        const SizedBox(height: 24),
        Center(child: Text("People You’re Tracking", style: AppText.display)),
        const SizedBox(height: 8),
        Center(
          child: Text(
            'Stay connected with your loved ones',
            style: AppText.body,
            textAlign: TextAlign.center,
          ),
        ),
        const SizedBox(height: 24),

        // Requests come first: they are the only thing here that needs an answer, and burying
        // them under the list would leave someone waiting on a reply the user never saw.
        for (final request in state.requests) ...[
          RequestCard(
            person: request,
            onAccept: () => viewModel.respond(personId: request.id, accept: true),
            onDecline: () => viewModel.respond(personId: request.id, accept: false),
          ),
          const SizedBox(height: 9),
        ],

        for (var i = 0; i < state.people.length; i++) ...[
          PersonCard(
            person: state.people[i],
            expanded: state.people[i].id == state.expandedId,
            tint: i.isEven ? AppColors.cardBlue : AppColors.cardWarm,
            onToggle: () => viewModel.toggle(state.people[i].id),
            onAction: (action) => viewModel.runAction(action, state.people[i]),
            onRemove: () => viewModel.removePerson(state.people[i]),
          ),
          const SizedBox(height: 9),
        ],
        if (state.canAddMore)
          AddPersonCard(
            onTap: () => _addPerson(context, ref),
            subtitle: 'You can add up to ${state.maxPeople} people',
          ),
      ],
    );
  }
}
