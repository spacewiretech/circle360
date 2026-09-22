import 'package:flutter_test/flutter_test.dart';
import 'package:loc_360/data/repositories/app_config_repository.dart';
import 'package:loc_360/suniomax/data/onboarding_audio.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// SunioMax's spoken onboarding prompts: which row each screen reads, what counts as "nothing to
/// play", and the paywall fallback.
///
/// The controller itself is not exercised here — it opens a real `VideoPlayerController`, which
/// needs a platform. What *is* testable without one is every decision made before a player is
/// opened, and those are the decisions that go wrong: a mistyped key, an `http://` URL nobody
/// noticed, a fallback that fires in the wrong direction.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('clips', () {
    test('each screen reads its own row', () {
      expect(SxAudioClip.language.configKey, sunioMaxAudioLanguageKey);
      expect(SxAudioClip.phone.configKey, sunioMaxAudioPhoneKey);
      expect(SxAudioClip.otp.configKey, sunioMaxAudioOtpKey);
      expect(SxAudioClip.name.configKey, sunioMaxAudioNameKey);
    });

    test('no two clips share a row', () {
      // A copy-paste that pointed two screens at one row would be invisible on device — both
      // screens would play, just the same clip twice, which reads as a recording mistake.
      final keys = SxAudioClip.values.map((clip) => clip.configKey).toSet();
      expect(keys, hasLength(SxAudioClip.values.length));
    });
  });

  group('audioUrlFor', () {
    test('serves an https URL', () {
      const config = {
        sunioMaxAudioPhoneKey: 'https://cdn.example.com/phone.mp3',
      };
      expect(
        audioUrlFor(SxAudioClip.phone, config),
        'https://cdn.example.com/phone.mp3',
      );
    });

    test('a missing row is silence, not a failure', () {
      expect(audioUrlFor(SxAudioClip.phone, const {}), '');
    });

    test('a blank row is silence', () {
      // The seeded state. Every one of these rows ships empty, so this is what the feature looks
      // like on the day it is deployed.
      expect(audioUrlFor(SxAudioClip.otp, const {sunioMaxAudioOtpKey: ''}), '');
      expect(
        audioUrlFor(SxAudioClip.otp, const {sunioMaxAudioOtpKey: '   '}),
        '',
      );
    });

    test('an http URL is treated as unset', () {
      // iOS ATS and Android's default `usesCleartextTraffic = false` both refuse cleartext, so
      // this would fail on every device — better silent here than twelve seconds into a timeout.
      expect(
        audioUrlFor(SxAudioClip.name, const {
          sunioMaxAudioNameKey: 'http://cdn.example.com/name.mp3',
        }),
        '',
      );
    });

    test('a value that is not a URL at all is treated as unset', () {
      expect(
        audioUrlFor(SxAudioClip.language, const {
          sunioMaxAudioLanguageKey: 'coming soon',
        }),
        '',
      );
    });

    test('surrounding whitespace is forgiven', () {
      // Pasted out of a dashboard field, which is where every one of these values comes from.
      expect(
        audioUrlFor(SxAudioClip.phone, const {
          sunioMaxAudioPhoneKey: '  https://cdn.example.com/phone.mp3  ',
        }),
        'https://cdn.example.com/phone.mp3',
      );
    });
  });

  group('sunioPaywallVideoUrl', () {
    test('prefers SunioMax\'s own footage', () {
      expect(
        sunioPaywallVideoUrl(const {
          sunioMaxPaywallVideoKey: 'https://cdn.example.com/sunio.mp4',
          paywallVideoKey: 'https://cdn.example.com/circle360.mp4',
        }),
        'https://cdn.example.com/sunio.mp4',
      );
    });

    test('falls back to Circle360\'s while the row is blank', () {
      // The state this ships in: the migration seeds the row empty, and until somebody records
      // SunioMax footage the paywall must keep showing exactly what it shows today.
      expect(
        sunioPaywallVideoUrl(const {
          sunioMaxPaywallVideoKey: '',
          paywallVideoKey: 'https://cdn.example.com/circle360.mp4',
        }),
        'https://cdn.example.com/circle360.mp4',
      );
    });

    test('falls back when the row is missing entirely', () {
      // A device whose config cache predates the migration.
      expect(
        sunioPaywallVideoUrl(const {
          paywallVideoKey: 'https://cdn.example.com/circle360.mp4',
        }),
        'https://cdn.example.com/circle360.mp4',
      );
    });

    test('empty when neither row has anything', () {
      expect(sunioPaywallVideoUrl(const {}), '');
    });

    test('a malformed SunioMax row is used, not silently replaced', () {
      // Deliberate. The https rule belongs to `PromoVideo`, which applies it to whatever it is
      // handed; filtering here would mean a typo in the SunioMax row quietly showed Circle360's
      // video instead — which looks deliberate and would never be reported.
      expect(
        sunioPaywallVideoUrl(const {
          sunioMaxPaywallVideoKey: 'http://cdn.example.com/sunio.mp4',
          paywallVideoKey: 'https://cdn.example.com/circle360.mp4',
        }),
        'http://cdn.example.com/sunio.mp4',
      );
    });
  });

  group('SxAudioPreference', () {
    setUp(() => SharedPreferences.setMockInitialValues({}));

    test('defaults to unmuted', () {
      // The direction that matters. These clips are the accessibility affordance the whole
      // feature exists for, so an unset or unreadable store must mean "plays" — one tap to fix —
      // rather than "silent for a user who needs it", which is invisible.
      expect(const SxAudioPreference().read(), completion(isFalse));
    });

    test('round-trips', () async {
      const preference = SxAudioPreference();

      await preference.write(true);
      expect(await preference.read(), isTrue);

      await preference.write(false);
      expect(await preference.read(), isFalse);
    });

    test('a value written under a different key does not leak in', () async {
      SharedPreferences.setMockInitialValues({'audio_muted': true});
      expect(await const SxAudioPreference().read(), isFalse);
    });
  });
}
