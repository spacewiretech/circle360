import 'dart:async';

import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

import '../../app/theme/app_colors.dart';
import '../../app/theme/app_theme.dart';
import '../../data/analytics/analytics.dart';
import '../../data/analytics/analytics_events.dart';

/// The one rule about what may be handed to the plugin: https, or nothing.
///
/// iOS App Transport Security and Android's default `usesCleartextTraffic = false` both refuse
/// plain http, so an `http://` row fails on every device rather than on some of them — better
/// treated as unset here than discovered twelve seconds later at the end of a timeout.
///
/// Top-level because [PromoVideo] is no longer the only caller: `promo_video_warmup.dart` decides
/// whether a row is worth opening a player for long before this widget is built, and a rule that
/// lived in two places would eventually be enforced in one.
Uri? promoVideoUri(String url) {
  final trimmed = url.trim();
  if (trimmed.isEmpty) return null;
  final uri = Uri.tryParse(trimmed);
  if (uri == null || uri.scheme != 'https' || uri.host.isEmpty) return null;
  return uri;
}

/// The looping promo that fills the space above the paywall sheet.
///
/// Everything here is defensive on purpose. The URL is an `app_config` row an operator edits by
/// hand, and this is the one screen with no way out except a payment: a blank row, a 404, a codec
/// the device cannot decode and a phone too short to show a card at all must every one of them
/// leave a working Subscribe button underneath. Three states, and only the first ever reaches the
/// plugin at all:
///
///  * no usable URL — nothing. Not an empty card, not a placeholder: the sheet simply sits higher
///    on the warm page, which is exactly the frame the onboarding steps use.
///  * usable URL, still opening — the brand gradient with a shimmer sweeping over it.
///  * failed — the same gradient, held still. The sweep is a claim that something is arriving,
///    and once nothing is, it stops.
///  * playing — the video, cropped to fill the card.
///
/// The playing state can also be reached without ever opening anything: see [adopt].
class PromoVideo extends StatefulWidget {
  const PromoVideo({
    super.key,
    required this.url,
    required this.muted,
    required this.onToggleMute,
    this.adopt,
    this.paused = false,
    this.aspectRatio = 16 / 16,
    this.minHeight = 132,
  });

  /// `paywall_video_url`. Empty is the normal state — it is what every build sees before
  /// `app_config` resolves, and what a checkout with no video row sees forever.
  final String url;

  /// Owned by the screen so the button and the player can never disagree about it.
  final bool muted;
  final VoidCallback onToggleMute;

  /// Held quiet while the screen is doing something more important than a promo: a mandate in
  /// flight, or a UPI app about to take the foreground that has not backgrounded us yet.
  final bool paused;

  /// Offers this widget a player somebody else already opened, for [url].
  ///
  /// This is what makes the promo instant. Opening a network video costs one round trip for the
  /// manifest and several more before a frame can be decoded — nine seconds on a good connection,
  /// spent on the one screen in the app that is trying to take money. `promo_video_warmup.dart`
  /// pays that cost during onboarding instead, while the user is waiting on an SMS.
  ///
  /// The contract is a *transfer*, not a loan: a non-null return means this widget now owns the
  /// controller and is the only thing that will ever dispose it, which is why the whole of
  /// [_PromoVideoState]'s teardown applies to an adopted controller unchanged. Returning null is
  /// always allowed — nothing warmed, warming still in flight, the URL moved on since — and lands
  /// on the ordinary open below.
  ///
  /// A callback rather than the warm-up object so this widget stays free of Riverpod, and so a
  /// test can hand it a controller without a provider container.
  ///
  /// Asynchronous because the honest answer is sometimes "not yet": a warm-up caught mid-open
  /// makes this widget wait for it rather than race it with a second download of the same file.
  final Future<VideoPlayerController?> Function(String url)? adopt;

  /// Fixed rather than taken from `controller.value.aspectRatio`. A card that resizes the moment
  /// the video initialises shoves the whole sheet down a frame after the screen has settled;
  /// whatever shape the source turns out to be, [BoxFit.cover] fills this.
  final double aspectRatio;

  /// Below this the card is a postage stamp and reads as a rendering fault rather than as a
  /// video, so it is dropped entirely. A 360x640 phone showing the UPI bar lands here.
  final double minHeight;

  @override
  State<PromoVideo> createState() => _PromoVideoState();
}

class _PromoVideoState extends State<PromoVideo> with WidgetsBindingObserver {
  /// Only ever a fully initialised, current-generation controller. Anything mid-flight lives in a
  /// local inside [_open], which is what keeps "is there something to paint" a single null check
  /// rather than a conjunction of flags that can disagree with each other.
  VideoPlayerController? _controller;

  /// Separates "still opening" from "will never open", which is the only thing the placeholder
  /// needs it for: a shimmer over the gradient while there is still hope, and a bare gradient
  /// once there is not. It deliberately does *not* gate the video branch — [_controller] alone
  /// decides that, so the two can never disagree about what is on screen.
  bool _failed = false;

  bool _foreground = true;

  /// Two URL changes in quick succession leave two `initialize()` futures in flight. Without a
  /// generation the slower one wins and installs a controller the widget has already moved past.
  int _generation = 0;

  /// The plugin has no timeout of its own: a host that accepts the connection and then goes quiet
  /// leaves `initialize()` pending forever, and the placeholder up with it.
  static const _initTimeout = Duration(seconds: 12);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(_open(widget.url));
  }

  @override
  void didUpdateWidget(PromoVideo oldWidget) {
    super.didUpdateWidget(oldWidget);

    // Not defensive code — this is the normal path. The screen builds before its one-row query
    // comes back, so the first build genuinely has no URL and the second one does.
    if (widget.url != oldWidget.url) {
      unawaited(_open(widget.url));
      return;
    }
    if (widget.muted != oldWidget.muted) {
      unawaited(_controller?.setVolume(widget.muted ? 0 : 1));
    }
    if (widget.paused != oldWidget.paused) _applyPlayPause();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // `video_player` installs an observer of its own that pauses on `paused` and resumes on
    // `resumed`, and on Android that alone would nearly do. It is not enough here. A UPI hand-off
    // goes inactive -> hidden -> paused, and on iOS the control centre and the app switcher stop
    // at `inactive` and never reach `paused` at all — a promo with sound on has no business
    // talking over either.
    //
    // Pausing this early also settles which observer owns the resume: by the time the package's
    // sees `paused`, `isPlaying` is already false, so it records `_wasPlayingBeforePause = false`
    // and does nothing on the way back. Exactly one resume, ours, and ours honours [paused].
    final foreground = state == AppLifecycleState.resumed;
    if (foreground == _foreground) return;
    _foreground = foreground;
    _applyPlayPause();
  }

  bool get _shouldPlay => _foreground && !widget.paused;

  void _applyPlayPause() {
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) return;
    unawaited(_shouldPlay ? controller.play() : controller.pause());
  }

  Future<void> _open(String url) async {
    final generation = ++_generation;
    await _teardown();
    if (!mounted || generation != _generation) return;

    // Back to the placeholder for the whole of the open. This rebuild is not cosmetic:
    // [_teardown] has already disposed the previous controller, and without it the tree would go
    // on painting that controller for the length of the fetch — which is precisely the
    // "used after being disposed" crash.
    //
    // An unusable URL stops here rather than reporting a failure: an operator who has not filled
    // the row in yet gets no card at all, not an apology in a gradient.
    setState(() => _failed = false);

    final uri = promoVideoUri(url);
    if (uri == null) return;

    // A player somebody else already opened for this exact URL, if there is one. Past this point
    // the two cases are deliberately indistinguishable — same options, same looping, same
    // teardown — and the only difference is that the twelve seconds happened during onboarding
    // instead of here.
    final warm = await widget.adopt?.call(url);

    // That await is a gap like any other, and this one is unusual in that the thing to protect is
    // not this widget: ownership of [warm] has already transferred, so nobody else will ever
    // dispose it. Dropping the reference here is a texture leaked for the life of the process.
    if (warm != null && (!mounted || generation != _generation)) {
      unawaited(warm.dispose());
      return;
    }

    final controller = warm ??
        VideoPlayerController.networkUrl(
          uri,
          videoPlayerOptions: VideoPlayerOptions(
            // Defaults to true, and true is meant for content someone chose to watch. This loops
            // forever, so leaving it would hold the screen awake for as long as the paywall is
            // open.
            preventsDisplaySleepDuringVideoPlayback: false,
            // The default, passed explicitly because it is a decision. False means the promo takes
            // audio focus and stops whatever the user was listening to, which is what a video with
            // sound is expected to do; true would play both streams at once, which reads as a bug.
            mixWithOthers: false,
          ),
        );

    // Skipped for an adopted controller, and only because [PromoVideoWarmup] hands over nothing
    // that has not already come back from `initialize()` — a second call on a live player throws.
    if (warm == null) {
      try {
        await controller.initialize().timeout(_initTimeout);
      } catch (error) {
        unawaited(controller.dispose());
        if (!mounted || generation != _generation) return;
        _reportFailure(uri, error);
        setState(() => _failed = true);
        return;
      }
    }

    // A zero size means the platform reported "initialised" with nothing decodable behind it —
    // an HTML error page served with a video content type does exactly this. Painting it would
    // hand [FittedBox] a zero-sized child and divide by zero.
    final size = controller.value.size;
    final usable =
        mounted && generation == _generation && size.width > 0 && size.height > 0;

    if (!usable) {
      unawaited(controller.dispose());
      if (!mounted || generation != _generation) return;
      _reportFailure(uri, 'zero_size');
      setState(() => _failed = true);
      return;
    }

    await controller.setLooping(true);
    await controller.setVolume(widget.muted ? 0 : 1);

    // Checked again, because those two awaits are a gap like any other: the screen can be
    // disposed and a newer URL can arrive inside it. Installing the controller past that point
    // strands a texture and throws on the setState.
    if (!mounted || generation != _generation) {
      unawaited(controller.dispose());
      return;
    }

    // A late error — the stream drops halfway through the third loop — arrives here and nowhere
    // else. `initialize()`'s future completed long ago and cannot report it.
    controller.addListener(_onControllerValue);

    setState(() {
      _controller = controller;
      _failed = false;
    });
    _applyPlayPause();
  }

  void _onControllerValue() {
    final controller = _controller;
    if (controller == null || !mounted || !controller.value.hasError) return;

    controller.removeListener(_onControllerValue);
    _reportFailure(promoVideoUri(widget.url), controller.value.errorDescription);
    setState(() {
      _controller = null;
      _failed = true;
    });
    unawaited(controller.dispose());
  }

  void _reportFailure(Uri? uri, Object? error) {
    analytics.track(Ev.paywallVideoFailed, {
      // The host, not the URL: the row is operator-entered and could carry a signed link with a
      // token in the query string. A host is enough to tell a dead bucket from a bad encode.
      P.source: uri?.host,
      P.error: error?.toString(),
    });
  }

  Future<void> _teardown() async {
    final controller = _controller;
    _controller = null;
    if (controller == null) return;
    controller.removeListener(_onControllerValue);
    await controller.dispose();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    // Not awaited, and it cannot be — `dispose` is synchronous. `VideoPlayerController.dispose`
    // waits on its own creation future internally, so a controller killed mid-`initialize` still
    // shuts down cleanly and the texture is released either way.
    unawaited(_teardown());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Checked before anything is laid out: no row, or a row that is not an https URL, means this
    // screen has no promo and the space above the sheet is simply the warm page.
    if (promoVideoUri(widget.url) == null) return const SizedBox.shrink();

    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxHeight < widget.minHeight) return const SizedBox.shrink();

        final controller = _controller;

        return Center(
          // Center is load-bearing: it loosens the constraints, and that is the whole trick.
          // Handed the tight box [Expanded] produces, AspectRatio would just fill it and the
          // ratio would be a lie. Loose, it takes the largest 16:9 that fits — width-driven on a
          // tall phone, height-driven on a short one.
          child: AspectRatio(
            aspectRatio: widget.aspectRatio,
            // The card floats over the map, and every other element in the app that does gets
            // this shadow — without it the video reads as a hole cut in the tiles rather than as
            // something sitting on top of them. Outside the clip, because a ClipRRect would cut
            // the shadow off at exactly the edge it is meant to fall past.
            child: DecoratedBox(
              decoration: const BoxDecoration(
                borderRadius: AppShape.card,
                boxShadow: [AppColors.floatingShadow],
              ),
              child: ClipRRect(
                borderRadius: AppShape.card,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    const _PromoGradient(),
                    // Only while there is still something to wait for. A card that has already
                    // failed shows the gradient and nothing else — a shimmer that never resolves
                    // is worse than no shimmer, and the screen behind it still sells fine.
                    if (controller == null && !_failed) const _PromoShimmer(),
                    AnimatedSwitcher(
                      duration: const Duration(milliseconds: 240),
                      child: controller == null
                          ? const SizedBox.shrink(key: ValueKey('placeholder'))
                          : _CoverVideo(controller: controller),
                    ),
                    if (controller != null)
                      Positioned(
                        left: 8,
                        bottom: 8,
                        child: _MuteButton(
                          muted: widget.muted,
                          onTap: widget.onToggleMute,
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

/// Fills the card whatever shape the source is, cropping rather than letterboxing.
class _CoverVideo extends StatelessWidget {
  const _CoverVideo({required this.controller});

  final VideoPlayerController controller;

  @override
  Widget build(BuildContext context) {
    final size = controller.value.size;
    return FittedBox(
      fit: BoxFit.cover,
      clipBehavior: Clip.hardEdge,
      child: SizedBox(
        width: size.width,
        height: size.height,
        child: VideoPlayer(controller),
      ),
    );
  }
}

/// What stands in for the video while it opens, and instead of it when it will not play.
///
/// A gradient rather than an asset: the two blues are ones the app already uses on cards, so an
/// operator who never sets the row gets a card that reads as part of the screen rather than as a
/// missing image. There is nothing to add to `assets/` and nothing to keep in sync.
class _PromoGradient extends StatelessWidget {
  const _PromoGradient();

  @override
  Widget build(BuildContext context) {
    return const DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [AppColors.chipBlue, AppColors.cardBlue],
        ),
      ),
    );
  }
}

/// The band of light that sweeps across [_PromoGradient] while the video opens.
///
/// A shimmer rather than a spinner because of what the two promise. A spinner is a claim about
/// work in progress and reads as a stall the moment it outlives a second or two; a shimmer says
/// only "something is going to fill this shape", which is exactly what is true here — and it says
/// it in the shape of the card, so nothing moves when the frame arrives.
///
/// Hand-rolled rather than a package: this is one sliding gradient in one place, and the
/// alternative is a dependency on the paywall's critical path.
class _PromoShimmer extends StatefulWidget {
  const _PromoShimmer();

  @override
  State<_PromoShimmer> createState() => _PromoShimmerState();
}

class _PromoShimmerState extends State<_PromoShimmer>
    with SingleTickerProviderStateMixin {
  /// Only ever runs behind the placeholder, which is bounded by [_PromoVideoState._initTimeout] —
  /// there is no path where this repeats forever. Flutter mutes tickers with the app, so a
  /// backgrounded paywall is not animating anything either.
  late final AnimationController _sweep = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1400),
  )..repeat();

  @override
  void dispose() {
    _sweep.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _sweep,
      builder: (context, _) => DecoratedBox(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            // Diagonal, matching the gradient underneath, so the two read as one surface being
            // lit rather than as a bar travelling over a card.
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            // White at a third of full: over #E0ECFE -> #F9FAFE this is a highlight you notice
            // moving and never a flash. Transparent ends keep the band's edges soft.
            colors: const [
              Color(0x00FFFFFF),
              Color(0x55FFFFFF),
              Color(0x00FFFFFF),
            ],
            stops: const [0.35, 0.5, 0.65],
            transform: _SweepTransform(_sweep.value),
          ),
        ),
      ),
    );
  }
}

/// Slides the whole gradient across the card, which is what turns three static stops into a
/// sweep. The travel is a full card width either side of centre, so the band is off the card at
/// both ends of the cycle and the wrap from 1 back to 0 happens out of sight.
class _SweepTransform extends GradientTransform {
  const _SweepTransform(this.t);

  /// The controller's value, 0..1.
  final double t;

  @override
  Matrix4 transform(Rect bounds, {TextDirection? textDirection}) =>
      Matrix4.translationValues(bounds.width * (t * 2 - 1), 0, 0);
}

/// The one control on the card.
class _MuteButton extends StatelessWidget {
  const _MuteButton({required this.muted, required this.onTap});

  final bool muted;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      // Neither the brand blue nor [AppColors.scrim]: this sits on video frames nobody has seen
      // yet, and only a dark translucent puck keeps a white glyph legible over all of them.
      color: Colors.black.withValues(alpha: 0.38),
      shape: const CircleBorder(),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: trackedTap(
          onTap,
          id: 'paywall_video_mute',
          // The state being moved *to*, so the two directions stay separable in a breakdown. A
          // high unmute rate is the signal that unmuted-by-default was the wrong call.
          properties: {P.action: muted ? 'unmute' : 'mute'},
        ),
        child: SizedBox(
          width: 36,
          height: 36,
          child: Center(
            child: Icon(
              muted ? Icons.volume_off_rounded : Icons.volume_up_rounded,
              size: 20,
              color: Colors.white,
            ),
          ),
        ),
      ),
    );
  }
}
