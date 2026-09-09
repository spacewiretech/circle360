import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/router.dart';
import '../../data/analytics/analytics_events.dart';
import '../../data/entitlement.dart';
import '../../data/location/location_controller.dart';
import '../../data/providers.dart';

/// Everything that has to happen when a user leaves, in the one order that is correct.
///
/// Lives here rather than at the call site because the app offers sign-out from two screens, and
/// each step below is a real bug when it moves. A copy of this block on a second screen is a copy
/// of three ordering constraints that nothing would catch drifting apart.
final signOutProvider = Provider<SignOutAction>(SignOutAction.new);

class SignOutAction {
  const SignOutAction(this._ref);

  final Ref _ref;

  /// [source] is the screen the user left from — see [Ev.signedOut].
  Future<void> call({required String source}) async {
    final analytics = _ref.read(analyticsProvider);

    // Emitted before the reset, or it would be attributed to the anonymous identity that
    // replaces this one rather than to the user who actually left.
    analytics.track(Ev.signedOut, {P.source: source});

    // Stop the native tracker and drop its copy of the token first. Signing out while the
    // service kept uploading would leave the previous user broadcasting from a handset they
    // have already handed back.
    await _ref
        .read(locationControllerProvider.notifier)
        .stopSharing(clearCredential: true);
    await _ref.read(authRepositoryProvider).signOut();

    // The analytics counterpart of clearing the session: without it the next person to sign in
    // on this handset inherits the previous user's Mixpanel profile, and every one of their
    // events lands on the wrong person.
    analytics.reset();
    _ref.read(entitlementProvider.notifier).clear();
  }
}

/// True while a sign-out is in flight.
///
/// The sequence above spans a platform call and a network round trip, and the dialog is gone for
/// all of it. Without this, a second tap in that window opens a second dialog and signs the same
/// user out twice, doubling the analytics. File-private rather than widget state so it covers
/// both call sites at once and leaves the screens as `ConsumerWidget`s.
bool _signingOut = false;

/// Asks first, then signs out and restarts onboarding.
///
/// Confirmation is worth a tap here: an accidental sign-out costs the user a full re-onboarding,
/// SMS code and all.
Future<void> confirmSignOut(
  BuildContext context,
  WidgetRef ref, {
  required String source,
}) async {
  if (_signingOut) return;

  final analytics = ref.read(analyticsProvider);
  analytics.track(Ev.signOutRequested, {P.source: source});

  final confirmed = await showDialog<bool>(
    context: context,
    // Named so the navigator observer reports it as a real surface rather than as an anonymous
    // route sitting on top of the screen underneath.
    routeSettings: const RouteSettings(name: 'sign-out'),
    builder: (context) => AlertDialog(
      title: const Text('Log out?'),
      content: const Text(
        'You will stop sharing your location and will need to sign in with your '
        'phone number again.',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('Cancel'),
        ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(true),
          child: const Text('Log out'),
        ),
      ],
    ),
  );

  if (confirmed != true) {
    analytics.track(Ev.signOutCancelled, {P.source: source});
    return;
  }

  _signingOut = true;
  try {
    await ref.read(signOutProvider)(source: source);
  } finally {
    _signingOut = false;
  }

  // The splash re-resolves the session and, finding none, lands on phone entry. Going there
  // rather than to `/phone` directly keeps one place deciding where a session belongs.
  if (context.mounted) context.go(Routes.splash);
}
