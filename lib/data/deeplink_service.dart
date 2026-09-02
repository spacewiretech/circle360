import 'dart:async';

import 'package:app_links/app_links.dart';

import 'models/invite_link.dart';

/// Domain the https invite links will eventually live on.
///
/// The App Links / Universal Links half is scaffolding: it only resolves once
/// `assetlinks.json` and `apple-app-site-association` are hosted there. The `loc360://` scheme
/// works today and is what the simulator/adb tests use.
const inviteHost = 'loc360.app';

/// Reads invites out of the URLs that launch, or reach, the app.
///
/// Platform deeplinking is turned off in the manifest and Info.plist so the URL does not go
/// straight into `GoRouter` — the splash has to stay in charge of the decision.
class DeeplinkService {
  DeeplinkService([AppLinks? links]) : _links = links ?? AppLinks();

  final AppLinks _links;

  /// The URL the app was cold-started with, if it carried an invite.
  Future<InviteLink?> initialInvite() async {
    final uri = await _links.getInitialLink();
    return uri == null ? null : parseInvite(uri);
  }

  /// Invites arriving while the app is already running.
  Stream<InviteLink> invites() =>
      _links.uriLinkStream.map(parseInvite).where((invite) => invite != null).cast<InviteLink>();
}

/// Pulls an [InviteLink] out of a deeplink URL, or returns null when the URL is not an invite.
///
/// Accepts both forms:
/// - `loc360://invite?code=ABC123&from=Mom`
/// - `https://loc360.app/invite/ABC123?from=Mom`
///
/// The https form is also what the marketing site serves to someone who does not have the
/// app — `SiteRoutes.invite` in `lib/website/site_router.dart` matches the same shape, so a
/// change to the link format has to be made in both places.
///
/// Kept a free function so it can be tested without the platform channel.
InviteLink? parseInvite(Uri uri) {
  final segments = uri.pathSegments.where((s) => s.isNotEmpty).toList();
  final inviterName = uri.queryParameters['from'];

  final isCustomScheme = uri.scheme == 'loc360' && uri.host == 'invite';
  final isWebLink =
      (uri.scheme == 'https' || uri.scheme == 'http') &&
      uri.host == inviteHost &&
      segments.firstOrNull == 'invite';

  if (!isCustomScheme && !isWebLink) return null;

  // The code rides as a query parameter on the custom scheme and as a path segment on the
  // web link; accept either on both so a malformed link still resolves.
  final code = uri.queryParameters['code']?.trim() ??
      (isWebLink ? segments.elementAtOrNull(1)?.trim() : segments.firstOrNull?.trim());

  if (code == null || code.isEmpty) return null;
  return InviteLink(code: code, inviterName: inviterName?.trim());
}
