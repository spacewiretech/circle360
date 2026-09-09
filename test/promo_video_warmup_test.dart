import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:loc_360/features/subscription/promo_video_warmup.dart';
import 'package:video_player/video_player.dart';
import 'package:video_player_platform_interface/video_player_platform_interface.dart';

/// What the paywall is allowed to assume about a player somebody else opened.
///
/// The interesting behaviour is entirely in ownership: exactly one thing may dispose a controller,
/// and the moment it changes hands is the moment that can go wrong. A player handed out twice is
/// a "used after being disposed" crash on the one screen with no way out except a payment; a
/// player handed out never is a decoder held for the life of the process.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _FakeVideoPlayerPlatform platform;

  setUp(() {
    platform = _FakeVideoPlayerPlatform();
    VideoPlayerPlatform.instance = platform;
  });

  /// A warm-up wired to a fake row and the fake platform, so nothing here touches a network.
  PromoVideoWarmup warmupFor(String url, {Duration delay = Duration.zero}) {
    return PromoVideoWarmup(
      readUrl: () => Future.delayed(delay, () => url),
      openPlayer: (uri) async {
        final controller = VideoPlayerController.networkUrl(uri);
        await controller.initialize();
        return controller;
      },
    );
  }

  group('claiming', () {
    test('hands the player over exactly once', () async {
      final warmup = warmupFor('https://cdn.example.com/promo.mp4');
      await warmup.start();

      final first = warmup.take('https://cdn.example.com/promo.mp4');
      expect(first, isNotNull, reason: 'the warmed player should be claimable');

      // The paywall can be built more than once for one session — a failed payment routes back
      // here. The second build must open its own rather than be handed a controller the first
      // build already owns and will dispose.
      final second = warmup.take('https://cdn.example.com/promo.mp4');
      expect(second, isNull);

      await first!.dispose();
    });

    test('refuses a player warmed for a different URL', () async {
      final warmup = warmupFor('https://cdn.example.com/old.mp4');
      await warmup.start();

      // An operator recutting the promo between onboarding and the paywall. Playing what was
      // warmed would show the video they just replaced.
      expect(warmup.take('https://cdn.example.com/new.mp4'), isNull);

      await warmup.discard();
    });

    test('tolerates the trailing whitespace an operator-entered row can carry', () async {
      final warmup = warmupFor('  https://cdn.example.com/promo.mp4  ');
      await warmup.start();

      expect(warmup.url, 'https://cdn.example.com/promo.mp4');
      final claimed = warmup.take('https://cdn.example.com/promo.mp4');
      expect(claimed, isNotNull);

      await claimed!.dispose();
    });

    test('claim waits for a warm-up that is still opening', () async {
      final warmup = warmupFor(
        'https://cdn.example.com/promo.mp4',
        delay: const Duration(milliseconds: 50),
      );
      unawaited(warmup.start());

      // A user whose OTP autofilled in seconds can reach the paywall mid-open. Answering "no"
      // here is what would put two downloads of the same video on a metered connection.
      final claimed = await warmup.claim('https://cdn.example.com/promo.mp4');
      expect(claimed, isNotNull);
      expect(platform.created, 1);

      await claimed!.dispose();
    });

    test('claim answers immediately when nothing was ever warmed', () async {
      final warmup = warmupFor('https://cdn.example.com/promo.mp4');

      // The splash routing a lapsed user straight to the paywall — onboarding never ran, so there
      // is nothing in flight to wait for and the screen must not be held up looking for it.
      expect(await warmup.claim('https://cdn.example.com/promo.mp4'), isNull);
      expect(platform.created, 0);
    });

    test('returns null while the row is still in flight', () async {
      final warmup = warmupFor(
        'https://cdn.example.com/promo.mp4',
        delay: const Duration(milliseconds: 50),
      );
      final pending = warmup.start();

      // The splash can reach the paywall in well under a second. Nothing is ready yet, and the
      // screen has to fall back to opening its own without being told anything went wrong.
      expect(warmup.url, isNull);
      expect(warmup.take('https://cdn.example.com/promo.mp4'), isNull);

      await pending;
      await warmup.discard();
    });
  });

  group('rows that warrant no player', () {
    test('a blank row resolves to no video and opens nothing', () async {
      final warmup = warmupFor('');
      await warmup.start();

      // `''` is an answer — "this checkout has no promo" — and the paywall must be able to tell it
      // apart from "not resolved yet", which is null.
      expect(warmup.url, '');
      expect(platform.created, 0);
      expect(warmup.take(''), isNull);
    });

    test('an http row is treated as unset rather than opened', () async {
      final warmup = warmupFor('http://cdn.example.com/promo.mp4');
      await warmup.start();

      // ATS and Android's cleartext default reject it on every device, so spending a player and
      // twelve seconds discovering that is pure cost.
      expect(platform.created, 0);
      expect(warmup.take('http://cdn.example.com/promo.mp4'), isNull);
    });
  });

  group('lifecycle', () {
    test('start is idempotent', () async {
      final warmup = warmupFor(
        'https://cdn.example.com/promo.mp4',
        delay: const Duration(milliseconds: 20),
      );

      // Two mounts of the phone screen — a back gesture out of OTP and in again — must not open
      // a second player, nor download the video twice.
      await Future.wait([warmup.start(), warmup.start(), warmup.start()]);

      expect(platform.created, 1);
      await warmup.discard();
    });

    test('discard releases an unclaimed player and can be called twice', () async {
      final warmup = warmupFor('https://cdn.example.com/promo.mp4');
      await warmup.start();

      await warmup.discard();
      expect(platform.disposed, 1);

      // The provider's onDispose and the expiry timer can both land on an already-discarded
      // warm-up; neither may throw.
      await warmup.discard();
      expect(platform.disposed, 1);
    });

    test('discard after a claim leaves the claimant its player', () async {
      final warmup = warmupFor('https://cdn.example.com/promo.mp4');
      await warmup.start();

      final claimed = warmup.take('https://cdn.example.com/promo.mp4');
      await warmup.discard();

      // The paywall is playing this. Disposing it from here is exactly the crash the transfer
      // exists to make impossible.
      expect(platform.disposed, 0);

      await claimed!.dispose();
      expect(platform.disposed, 1);
    });

    test('discard mid-open releases the player the open finishes with', () async {
      final warmup = warmupFor(
        'https://cdn.example.com/promo.mp4',
        delay: const Duration(milliseconds: 30),
      );
      final pending = warmup.start();

      // The provider being disposed, or the expiry firing, while the player is still opening.
      // The open cannot be called off — it has to hand back what it built and let this notice.
      await warmup.discard();
      await pending;

      expect(platform.created, 1, reason: 'the open was already under way');
      expect(platform.disposed, 1, reason: 'and what it produced must not survive the discard');
      expect(warmup.take('https://cdn.example.com/promo.mp4'), isNull);
    });

    test('discard forgets the URL so the next paywall reads a fresh one', () async {
      final warmup = warmupFor('https://cdn.example.com/promo.mp4');
      await warmup.start();
      expect(warmup.url, isNotNull);

      await warmup.discard();

      // The row was read to be used within the minute. Once this warm-up has expired the value is
      // old enough that the paywall should ask again — that freshness is the whole reason this
      // row bypasses the six-hour app_config cache.
      expect(warmup.url, isNull);
    });
  });

  test('a player that reports no size is dropped rather than handed over', () async {
    platform.reportZeroSize = true;
    final warmup = warmupFor('https://cdn.example.com/promo.mp4');
    await warmup.start();

    // An HTML error page served with a video content type initialises and then decodes nothing.
    // Passing it on would only move the failure to the paywall.
    expect(warmup.take('https://cdn.example.com/promo.mp4'), isNull);
    expect(platform.disposed, 1);
  });

  test('a player that fails to open leaves the paywall to its own path', () async {
    final warmup = PromoVideoWarmup(
      readUrl: () async => 'https://cdn.example.com/promo.mp4',
      openPlayer: (_) async => throw TimeoutException('no first frame'),
    );

    await warmup.start();

    // The URL still resolved, so the paywall can skip the query and lay the card out at its real
    // height — it just has to open the video itself.
    expect(warmup.url, 'https://cdn.example.com/promo.mp4');
    expect(warmup.take('https://cdn.example.com/promo.mp4'), isNull);
  });
}

/// The minimum platform a [VideoPlayerController] needs to reach `isInitialized`.
class _FakeVideoPlayerPlatform extends VideoPlayerPlatform {
  int created = 0;
  int disposed = 0;
  bool reportZeroSize = false;

  final Map<int, StreamController<VideoEvent>> _events = {};

  @override
  Future<void> init() async {}

  @override
  Future<int?> createWithOptions(VideoCreationOptions options) async {
    final playerId = created++;
    final events = StreamController<VideoEvent>();
    _events[playerId] = events;

    // After the controller has subscribed, which it does immediately after this returns.
    scheduleMicrotask(() {
      events.add(VideoEvent(
        eventType: VideoEventType.initialized,
        duration: const Duration(seconds: 30),
        size: reportZeroSize ? Size.zero : const Size(1080, 1080),
      ));
    });

    return playerId;
  }

  @override
  Stream<VideoEvent> videoEventsFor(int playerId) => _events[playerId]!.stream;

  @override
  Future<void> dispose(int playerId) async {
    disposed++;
    await _events.remove(playerId)?.close();
  }

  @override
  Future<void> setLooping(int playerId, bool looping) async {}

  @override
  Future<void> setVolume(int playerId, double volume) async {}

  @override
  Future<void> setMixWithOthers(bool mixWithOthers) async {}

  @override
  Future<void> setPreventsDisplaySleepDuringVideoPlayback(int playerId, bool value) async {}

  @override
  Future<void> play(int playerId) async {}

  @override
  Future<void> pause(int playerId) async {}

  @override
  Future<Duration> getPosition(int playerId) async => Duration.zero;

  @override
  Widget buildViewWithOptions(VideoViewOptions options) => const SizedBox.shrink();
}
