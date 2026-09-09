import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:video_player/video_player.dart';

import '../../app/env.dart';
import '../../data/analytics/analytics.dart';
import '../../data/analytics/analytics_events.dart';
import 'promo_video.dart';

/// How long a warmed player waits to be claimed before it gives up and releases itself.
///
/// The paywall is where onboarding leads, but it is not where onboarding always ends: a returning
/// user signing in on a wiped device can still have a live trial, and `verifyOtp` sends them
/// straight to Home without the paywall ever being built. Nothing would then claim the player, and
/// a decoder plus its read-ahead buffer would sit in memory for the life of the process.
///
/// Generous on purpose. It is a leak stop, not a policy — the window it has to cover is one SMS,
/// and a user who takes four minutes over a code should still get the fast paywall.
const _unclaimedTimeout = Duration(minutes: 5);

/// Opens the paywall promo early, so the paywall does not have to.
///
/// The promo costs roughly nine seconds to first frame on a good connection, and that time is
/// spent in two serial round trips: one to read `paywall_video_url` out of `app_config`, then the
/// player's own, which cannot start until the first returns. Both used to happen in
/// `SubscriptionView.initState` — on the single screen in the app whose only exit is a payment,
/// where the card is either absent or a shimmer for the whole of it.
///
/// Onboarding is phone → OTP → name, and the middle step is a wait on an SMS. That is twenty to
/// sixty seconds of a user watching a text field, with the network otherwise idle and no auth
/// needed to read the row — `app_config` is world-readable to `anon`. So the work moves there.
///
/// The result is handed over rather than shared. [take] transfers ownership of the controller and
/// forgets it; from that moment the claimant is the only thing that will ever dispose it. That is
/// what lets [PromoVideo] keep its entire existing teardown — generation counters, error listener,
/// `dispose` — and treat an adopted player exactly like one it opened itself.
///
/// Every failure here is silent by design. A warm-up that resolves nothing, times out, or opens a
/// player the device cannot decode must leave the paywall running precisely the code it ran
/// before, because the paywall's job is to take money and it can do that with no promo at all.
class PromoVideoWarmup {
  /// Both seams exist for tests: the Supabase query and the platform player are the two things a
  /// unit test cannot have, and the claim/expiry logic around them is the part worth testing.
  PromoVideoWarmup({
    Future<String> Function()? readUrl,
    Future<VideoPlayerController> Function(Uri uri)? openPlayer,
  })  : _readUrl = readUrl ?? _readUrlFromConfig,
        _openPlayer = openPlayer ?? _openNetworkPlayer;

  final Future<String> Function() _readUrl;
  final Future<VideoPlayerController> Function(Uri uri) _openPlayer;

  /// The row's value as read, trimmed. Null until [start] resolves it; `''` once it has resolved
  /// to "there is no promo", which is a real answer and not a missing one.
  String? _url;

  /// Initialised, looping, silent, and never played. Null whenever there is nothing to give away.
  VideoPlayerController? _ready;

  Future<void>? _inFlight;
  Timer? _expiry;

  /// Bumped by [discard], so an open that was already in flight when it ran knows to throw away
  /// what it finishes with. Without it, a warm-up cancelled at second three still installs its
  /// player at second nine — into an object nothing will ever claim from again.
  int _generation = 0;

  /// What [start] resolved, for a screen that would otherwise query the same row again.
  ///
  /// Null means "no answer yet" — not "no video" — and a caller that gets null must fall back to
  /// reading the row itself.
  String? get url => _url;

  /// Resolves the URL and opens a player for it. Safe to call more than once; the second call
  /// joins the first rather than starting a second download.
  Future<void> start() => _inFlight ??= _start();

  Future<void> _start() async {
    final generation = ++_generation;

    final String url;
    try {
      url = await _readUrl();
    } catch (error) {
      // Not reported. A config read that fails here fails again on the paywall, which has its own
      // handling and its own debug line — counting it twice would double every such session.
      debugPrint('[paywall] could not prewarm paywall_video_url: $error');
      return;
    }

    // Trimmed here rather than trusted from the reader, because [take] matches on this string and
    // an operator-entered row with a stray space would otherwise warm a player that could never
    // be claimed — the most expensive possible outcome, and a silent one.
    _url = url.trim();

    // No row, a blank row, or an `http://` row. All three mean this checkout has no promo, and
    // none of them is worth opening a player for.
    final uri = promoVideoUri(url);
    if (uri == null) return;

    final VideoPlayerController controller;
    try {
      controller = await _openPlayer(uri);
    } catch (error) {
      _report(uri, error);
      return;
    }

    // A zero size means the platform reported "initialised" with nothing decodable behind it — an
    // HTML error page served with a video content type does exactly this. Handing that to the
    // paywall would move the failure rather than prevent it.
    final size = controller.value.size;
    if (size.width <= 0 || size.height <= 0) {
      // Awaited, unlike the widget's equivalent: nothing is waiting on this warm-up, so there is
      // no frame to be late for, and letting `start()` complete with a player still shutting down
      // in the background is how a decoder outlives the thing that decided to drop it.
      await controller.dispose();
      _report(uri, 'zero_size');
      return;
    }

    // Silent, because the screen owns the mute state and has not been built yet. [PromoVideo]
    // sets the real volume when it adopts this.
    await controller.setLooping(true);
    await controller.setVolume(0);

    // Everything above this line is an await, and [discard] can have run inside any of them.
    // Installing the player past that point is a texture held with no way left to reach it.
    if (generation != _generation) {
      await controller.dispose();
      return;
    }

    _ready = controller;
    _expiry = Timer(_unclaimedTimeout, () => unawaited(discard()));
  }

  /// [take], but waits for a warm-up that is still opening.
  ///
  /// The difference matters for the user who gets through onboarding unusually fast — an SMS
  /// autofilled in seconds — and reaches the paywall while the player is mid-initialise. [take]
  /// would say no, and the screen would start a *second* download of the same video: two decoders
  /// and twice the data, on a connection the user is paying for.
  ///
  /// Waiting is not a gamble. The warm-up started at least three screens earlier, so it can only
  /// be closer to a first frame than an open begun now; the worst case is that it times out and
  /// the caller falls back having lost nothing it would not have spent anyway.
  ///
  /// A warm-up that was never started — the splash routing a lapsed user straight here — has
  /// nothing in flight and answers null immediately.
  Future<VideoPlayerController?> claim(String url) async {
    await _inFlight;
    return take(url);
  }

  /// Hands over the player for [url], or null if there isn't one.
  ///
  /// Null is the ordinary answer, not an error: warming may still be in flight, may have failed,
  /// or — the case the URL match exists for — an operator may have changed the row since, in which
  /// case what was warmed is the wrong video and must never reach the screen.
  ///
  /// Ownership moves with the return value, so a second call gets null and opens its own.
  VideoPlayerController? take(String url) {
    final controller = _ready;
    if (controller == null || _url != url.trim()) return null;

    _ready = null;
    _expiry?.cancel();
    _expiry = null;
    return controller;
  }

  /// Releases anything unclaimed. Idempotent, and harmless after [take].
  ///
  /// The resolved URL is dropped along with the player rather than kept as a hint. It was read to
  /// be used within the minute; by the time this runs it can be an hour old, and the whole reason
  /// this row is not served from `appConfigProvider`'s six-hour cache is that a URL pasted into
  /// the dashboard has to reach the next paywall that opens.
  Future<void> discard() async {
    _generation++;
    _expiry?.cancel();
    _expiry = null;
    _url = null;
    _inFlight = null;

    final controller = _ready;
    _ready = null;
    await controller?.dispose();
  }

  void _report(Uri uri, Object? error) {
    analytics.track(Ev.paywallVideoFailed, {
      // The host, not the URL: the row is operator-entered and could carry a signed link with a
      // token in the query string. A host is enough to tell a dead bucket from a bad encode.
      P.source: uri.host,
      P.error: error?.toString(),
      // What separates these from the paywall's own failures. They are the same event because
      // they are the same fault, but a prewarm failure costs the user nothing — the paywall still
      // tries — and a funnel that could not tell them apart would read every one as a lost promo.
      P.trigger: 'prewarm',
    });
  }

  /// The same one-row query the paywall used to run in `initState`, moved rather than copied.
  ///
  /// Read as its own query rather than through `appConfigProvider`: that map is served from a
  /// six-hour SharedPreferences cache, which is right for prices and limits and wrong for this. A
  /// URL pasted into the dashboard would not reach a device that had launched in the meantime
  /// until the cache aged out, and the paywall would sit there showing no video with nothing
  /// visibly wrong. One row, no cache, no waiting.
  static Future<String> _readUrlFromConfig() async {
    if (!Env.hasSupabase) return '';

    final row = await Supabase.instance.client
        .from('app_config')
        .select('value')
        .eq('key', 'paywall_video_url')
        .maybeSingle()
        .timeout(const Duration(seconds: 8));

    return (row?['value'] as String?)?.trim() ?? '';
  }

  /// Deliberately identical to the paywall's own open — same options, same timeout — because an
  /// adopted player has to be indistinguishable from one [PromoVideo] opened for itself.
  static Future<VideoPlayerController> _openNetworkPlayer(Uri uri) async {
    final controller = VideoPlayerController.networkUrl(
      uri,
      videoPlayerOptions: VideoPlayerOptions(
        preventsDisplaySleepDuringVideoPlayback: false,
        mixWithOthers: false,
      ),
    );

    try {
      // The plugin has no timeout of its own: a host that accepts the connection and then goes
      // quiet leaves this pending forever, and the player with it.
      await controller.initialize().timeout(const Duration(seconds: 12));
    } catch (_) {
      unawaited(controller.dispose());
      rethrow;
    }

    return controller;
  }
}

/// App-lifetime, like the rest of the data layer, because the whole point is to outlive the screen
/// that starts it — the phone step is three navigations away from the paywall that claims it.
final promoVideoWarmupProvider = Provider<PromoVideoWarmup>((ref) {
  final warmup = PromoVideoWarmup();
  ref.onDispose(warmup.discard);
  return warmup;
});
