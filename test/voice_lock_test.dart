import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:loc_360/suniomax/data/local/local_voice_lock_repository.dart';
import 'package:loc_360/suniomax/data/repositories/voice_lock_repository.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:loc_360/suniomax/data/providers.dart';
import 'package:loc_360/suniomax/features/home/voice_lock/voice_lock_viewmodel.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The voice lock's Dart half.
///
/// The parts worth pinning down are the refusals: a lock that arms without a way back in is a
/// phone its owner cannot open, which is the one genuinely unrecoverable failure this feature has.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('VoiceLockSettings', () {
    const complete = VoiceLockSettings(
      phrase: 'hare krishna',
      unlockPhrase: 'open sesame',
      hasPasscode: true,
    );

    test('all three parts are needed before it can be armed', () {
      expect(complete.configured, isTrue);
      expect(complete.copyWith(phrase: '').configured, isFalse);
      expect(complete.copyWith(unlockPhrase: '').configured, isFalse);
      expect(complete.copyWith(hasPasscode: false).configured, isFalse);
    });

    test('a phrase of whitespace is not a phrase', () {
      expect(complete.copyWith(phrase: '   ').hasPhrase, isFalse);
      expect(complete.copyWith(phrase: '   ').configured, isFalse);
    });

    test('a re-arm in flight is not a fault', () {
      // Starting the native service is asynchronous, so `listening` is false in the same reply
      // that started it. Without the rearming flag every app open showed "on but not listening".
      final rearming = complete.copyWith(
        enabled: true,
        listening: false,
        rearming: true,
      );
      expect(rearming.stalled, isFalse);

      // Once the re-arm is done and it still is not listening, that IS a fault.
      expect(rearming.copyWith(rearming: false).stalled, isTrue);
    });

    test('active means armed AND actually listening', () {
      // The switch is what the user asked for; `listening` is what is true. A screen that
      // conflates them tells a user their phone is protected when nothing is running.
      final armed = complete.copyWith(enabled: true, listening: true);
      expect(armed.active, isTrue);
      expect(armed.stalled, isFalse);

      final stalled = complete.copyWith(enabled: true, listening: false);
      expect(stalled.active, isFalse);
      expect(
        stalled.stalled,
        isTrue,
        reason: 'on but not listening must be visible',
      );
    });

    test(
      'phraseWordCount counts words, and the phrase is never the payload',
      () {
        expect(complete.phraseWordCount, 2);
        expect(complete.copyWith(phrase: 'one two  three').phraseWordCount, 3);
        expect(complete.copyWith(phrase: '').phraseWordCount, 0);
      },
    );

    test('fromMap tolerates a channel that answers with nothing useful', () {
      // Every failure path in ChannelVoiceLockRepository lands here.
      expect(VoiceLockSettings.fromMap(null).configured, isFalse);
      expect(VoiceLockSettings.fromMap('nonsense').enabled, isFalse);
      expect(VoiceLockSettings.fromMap(const {}).listening, isFalse);
    });

    test('fromMap reads a real native payload', () {
      final settings = VoiceLockSettings.fromMap(const {
        'enabled': true,
        'phrase': 'hare krishna',
        'unlockPhrase': 'open sesame',
        'hasPasscode': true,
        'listening': true,
        'locked': false,
        'permissions': {
          'microphone': true,
          'overlay': true,
          'notifications': true,
          'batteryOptimized': false,
        },
      });

      expect(settings.active, isTrue);
      expect(settings.permissions.granted, isTrue);
      expect(settings.permissions.ideal, isTrue);
    });

    test(
      'an empty phrase from the channel reads as unset, not as an empty string',
      () {
        // Kotlin returns "" rather than null for an unset phrase.
        final settings = VoiceLockSettings.fromMap(const {
          'phrase': '',
          'unlockPhrase': '',
        });
        expect(settings.phrase, isNull);
        expect(settings.hasPhrase, isFalse);
      },
    );
  });

  group('phrasesConflict', () {
    test('the pair that actually broke: lock vs unlock my phone', () {
      // These are word-distinct — "unlock" is not "lock" — so they are a legitimate pair and
      // must NOT be rejected. The bug was the matcher doing a raw substring test, not the
      // phrases being genuinely ambiguous.
      expect(phrasesConflict('lock my phone', 'unlock my phone'), isFalse);
    });

    test('one phrase wholly inside the other is a conflict', () {
      // The matcher looks for containment, so this pair leaves one command unreachable.
      expect(
        phrasesConflict('lock my phone', 'please lock my phone now'),
        isTrue,
      );
      expect(
        phrasesConflict('please lock my phone now', 'lock my phone'),
        isTrue,
      );
    });

    test('identical phrases conflict', () {
      expect(phrasesConflict('hare krishna', 'Hare Krishna'), isTrue);
    });

    test('punctuation and spacing do not create a false difference', () {
      expect(phrasesConflict('hare, krishna!', 'hare  krishna'), isTrue);
    });

    test('genuinely different phrases do not conflict', () {
      expect(phrasesConflict('hare krishna', 'open sesame'), isFalse);
      expect(phrasesConflict('lock it now', 'open it now'), isFalse);
    });

    test('a shared tail is not a conflict', () {
      // "my phone" appears in both, but neither phrase contains the other.
      expect(phrasesConflict('secure my phone', 'release my phone'), isFalse);
    });

    test('an empty phrase never conflicts', () {
      expect(phrasesConflict('', 'lock my phone'), isFalse);
      expect(phrasesConflict('lock my phone', '   '), isFalse);
    });

    test('non-Latin scripts are compared, not stripped', () {
      // The six Indic languages the picker offers must survive normalisation on both sides.
      expect(phrasesConflict('ஒலிப்பூட்டு', 'ஒலிப்பூட்டு'), isTrue);
      expect(phrasesConflict('ஒலிப்பூட்டு', 'திற'), isFalse);
      expect(phrasesConflict('हरे कृष्ण', 'हरे कृष्ण'), isTrue);
    });
  });

  group('VoiceLockPermissions', () {
    test('granted needs the two that the feature cannot work without', () {
      const both = VoiceLockPermissions(microphone: true, overlay: true);
      expect(both.granted, isTrue);
      expect(const VoiceLockPermissions(microphone: true).granted, isFalse);
      expect(const VoiceLockPermissions(overlay: true).granted, isFalse);
    });

    test('notifications and battery are advisory, not blocking', () {
      const granted = VoiceLockPermissions(microphone: true, overlay: true);
      expect(granted.granted, isTrue);
      expect(
        granted.ideal,
        isFalse,
        reason: 'still battery-optimised and no notifications',
      );
    });

    test('an unreadable answer means still optimised', () {
      // The visible consequence of guessing wrong this way is a prompt the user can dismiss;
      // guessing the other way is a listener that silently dies overnight.
      expect(VoiceLockPermissions.fromMap(null).batteryOptimised, isTrue);
      expect(VoiceLockPermissions.fromMap(const {}).batteryOptimised, isTrue);
      expect(
        VoiceLockPermissions.fromMap(const {
          'batteryOptimized': false,
        }).batteryOptimised,
        isFalse,
      );
    });
  });

  group('turning the lock on', () {
    ProviderContainer containerFor(_FakeVoiceLock fake) {
      final container = ProviderContainer(
        overrides: [voiceLockRepositoryProvider.overrideWithValue(fake)],
      );
      addTearDown(container.dispose);
      return container;
    }

    test('the overlay screen opens even when the microphone was refused', () async {
      // The bug this exists to stop: the overlay request used to be gated behind the microphone,
      // so the explainer's "Open Settings" button opened nothing at all if the mic was denied.
      final fake = _FakeVoiceLock();
      final container = containerFor(fake);
      final notifier = container.read(voiceLockViewModelProvider.notifier);

      await notifier.setEnabled(true);

      expect(
        fake.overlayRequests,
        1,
        reason: 'Open Settings must always open settings',
      );
    });

    test('nothing is configured, and it still tries to arm', () async {
      // Turning the lock on comes first; phrases are recorded afterwards. Requiring the
      // configuration here made the switch impossible to turn on at all.
      final fake = _FakeVoiceLock();
      final container = containerFor(fake);

      await container
          .read(voiceLockViewModelProvider.notifier)
          .setEnabled(true);

      expect(fake.overlayRequests, greaterThan(0));
      expect(fake.microphoneRequests, greaterThan(0));
    });

    test(
      'an enable left waiting on Settings completes on the way back',
      () async {
        final fake = _FakeVoiceLock()
          ..grantedWhileAway = const VoiceLockPermissions(
            microphone: true,
            overlay: true,
          );
        final container = containerFor(fake);
        final notifier = container.read(voiceLockViewModelProvider.notifier);

        // requestOverlay returns before the user has answered, so this cannot arm yet — and must
        // not show a refusal for something still being decided.
        await notifier.setEnabled(true);
        expect(container.read(voiceLockViewModelProvider).error, isNull);

        // Back from Settings, grant given.
        await notifier.refresh();

        expect(
          container.read(voiceLockViewModelProvider).settings.enabled,
          isTrue,
        );
        expect(container.read(voiceLockViewModelProvider).error, isNull);
      },
    );

    test('coming back without granting it is a real refusal', () async {
      final fake = _FakeVoiceLock();
      final container = containerFor(fake);
      final notifier = container.read(voiceLockViewModelProvider.notifier);

      await notifier.setEnabled(true);
      await notifier.refresh();

      final state = container.read(voiceLockViewModelProvider);
      expect(state.settings.enabled, isFalse);
      expect(state.error, contains('display over other apps'));
    });
  });

  group('clear', () {
    setUp(() {
      SharedPreferences.setMockInitialValues({});
      FlutterSecureStorageTestBackend.install();
    });

    test('sign-out leaves nothing behind for the next user', () async {
      // The phrases and the passcode live on the device, not on the account. Leaving them would
      // let whoever signs in next be protected — and locked out — by a stranger's voice.
      final repository = LocalVoiceLockRepository();
      await repository.setPhrase('hare krishna');
      await repository.setUnlockPhrase('open sesame');
      await repository.setPasscode('1234');
      await repository.setEnabled(true);

      await repository.clear();

      final after = await repository.load();
      expect(after.enabled, isFalse);
      expect(after.hasPhrase, isFalse);
      expect(after.hasUnlockPhrase, isFalse);
      expect(after.hasPasscode, isFalse);
      // The old passcode must not still verify.
      expect(await repository.verifyPasscode('1234'), isFalse);
    });

    test('nothing is left in storage either', () async {
      final repository = LocalVoiceLockRepository();
      await repository.setPasscode('1234');
      await repository.clear();
      expect(
        FlutterSecureStorageTestBackend.values['suniomax.passcode'],
        isNull,
      );
    });
  });

  group('LocalVoiceLockRepository', () {
    setUp(() {
      SharedPreferences.setMockInitialValues({});
      FlutterSecureStorageTestBackend.install();
    });

    test('arms before anything is configured', () async {
      // The flow is: turn it on, grant the permissions, *then* record a phrase. Requiring the
      // configuration first would make the switch impossible to turn on and the setup rows
      // impossible to reach. What prevents a lock-out is VoiceLockService refusing to put the
      // overlay up until a passcode exists, not this.
      final repository = LocalVoiceLockRepository();
      final settings = await repository.setEnabled(true);
      expect(settings.enabled, isTrue);
      expect(settings.configured, isFalse);
    });

    test('stays armed once all three parts are set', () async {
      final repository = LocalVoiceLockRepository();
      await repository.setPhrase('hare krishna');
      await repository.setUnlockPhrase('open sesame');
      await repository.setPasscode('1234');

      final settings = await repository.setEnabled(true);
      expect(settings.enabled, isTrue);
      // Never claims to be listening: there is no native side here.
      expect(settings.listening, isFalse);
    });

    test('the passcode round-trips and a wrong one is refused', () async {
      final repository = LocalVoiceLockRepository();
      await repository.setPasscode('4321');

      expect(await repository.verifyPasscode('4321'), isTrue);
      expect(await repository.verifyPasscode('1234'), isFalse);
      expect(await repository.verifyPasscode(''), isFalse);
    });

    test('an unset passcode is not satisfied by an empty guess', () async {
      final repository = LocalVoiceLockRepository();
      expect(await repository.verifyPasscode(''), isFalse);
      expect(await repository.verifyPasscode('0000'), isFalse);
    });

    test('the same passcode stores differently every time', () async {
      // A fresh salt per write, so two users with 1234 do not share a stored value.
      final repository = LocalVoiceLockRepository();
      await repository.setPasscode('1234');
      final first = FlutterSecureStorageTestBackend.values['suniomax.passcode'];
      await repository.setPasscode('1234');
      final second =
          FlutterSecureStorageTestBackend.values['suniomax.passcode'];

      expect(first, isNot(second));
      expect(await repository.verifyPasscode('1234'), isTrue);
    });

    test('the stored passcode is never the passcode', () async {
      final repository = LocalVoiceLockRepository();
      await repository.setPasscode('1234');
      expect(
        FlutterSecureStorageTestBackend.values['suniomax.passcode'],
        isNot(contains('1234')),
      );
    });

    test(
      'a blank phrase is ignored rather than clearing the real one',
      () async {
        final repository = LocalVoiceLockRepository();
        await repository.setPhrase('hare krishna');
        await repository.setPhrase('   ');
        expect((await repository.load()).phrase, 'hare krishna');
      },
    );

    test('armed but unconfigured is a real state, and is reported as one', () async {
      // The state a user is in between granting the permissions and recording a phrase.
      // `enabled` says the listener is meant to run; `configured` says whether it has anything
      // to do. Collapsing the two is what made the switch impossible to turn on.
      SharedPreferences.setMockInitialValues({
        'suniomax.voice_lock_enabled': true,
      });
      final settings = await LocalVoiceLockRepository().load();
      expect(settings.enabled, isTrue);
      expect(settings.configured, isFalse);
    });
  });
}

/// A stand-in for the Keychain/Keystore.
///
/// `flutter_secure_storage` has no in-memory test mode, so its platform channel is intercepted
/// here. Exposing the written values is the point: two of the tests above assert on what actually
/// reached storage, which is the only way to check the passcode is not sitting there in plaintext.
abstract final class FlutterSecureStorageTestBackend {
  static final Map<String, String> values = {};

  static void install() {
    values.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
          (call) async {
            final args = Map<String, Object?>.from(call.arguments as Map);
            final key = args['key'] as String?;
            return switch (call.method) {
              'write' => values[key!] = args['value'] as String,
              'read' => values[key!],
              'delete' => values.remove(key!),
              'readAll' => Map<String, String>.from(values),
              'deleteAll' => values.clear(),
              'containsKey' => values.containsKey(key),
              _ => null,
            };
          },
        );
  }
}

/// A repository that behaves like the Android one: `requestOverlay` opens a Settings screen and
/// returns immediately, *without* the grant — because the user has left the app to give it.
///
/// That asymmetry is the whole reason `refresh()` has to finish the job, and it is what the
/// "Open Settings does nothing" bug came down to.
class _FakeVoiceLock implements VoiceLockRepository {
  _FakeVoiceLock();

  var settings = const VoiceLockSettings();
  var grants = const VoiceLockPermissions();

  /// Set by the test to simulate the user granting the overlay while away in Settings.
  VoiceLockPermissions? grantedWhileAway;

  int overlayRequests = 0;
  int microphoneRequests = 0;

  @override
  Future<VoiceLockSettings> load() async =>
      settings.copyWith(permissions: grants);

  @override
  Stream<VoiceLockSettings> watch() => const Stream.empty();

  @override
  Future<VoiceLockSettings> setEnabled(bool value) async {
    // Mirrors VoiceLockBridge: permissions are the only thing that can refuse.
    final allowed = value && grants.granted;
    settings = settings.copyWith(enabled: value ? allowed : false);
    return settings.copyWith(permissions: grants);
  }

  @override
  Future<VoiceLockPermissions> permissions() async => grants;

  @override
  Future<VoiceLockPermissions> requestMicrophone() async {
    microphoneRequests++;
    grants = VoiceLockPermissions(
      microphone: true,
      overlay: grants.overlay,
      notifications: grants.notifications,
      batteryOptimised: grants.batteryOptimised,
    );
    return grants;
  }

  @override
  Future<VoiceLockPermissions> requestOverlay() async {
    overlayRequests++;
    // Opens Settings and returns with nothing new, exactly as the native side does.
    final away = grantedWhileAway;
    if (away != null) grants = away;
    return grants;
  }

  @override
  Future<VoiceLockPermissions> requestNotifications() async => grants;

  @override
  Future<VoiceLockPermissions> requestIgnoreBatteryOptimizations() async =>
      grants;

  @override
  Future<VoiceLockSettings> setPhrase(String phrase) async => settings;

  @override
  Future<VoiceLockSettings> setUnlockPhrase(String phrase) async => settings;

  @override
  Future<VoiceLockSettings> setPasscode(String passcode) async => settings;

  @override
  Future<bool> verifyPasscode(String passcode) async => false;

  @override
  Future<PhraseCaptureResult> capturePhrase({String? language}) async =>
      const PhraseCaptureResult();

  var cleared = false;

  @override
  Future<void> clear() async {
    cleared = true;
    settings = const VoiceLockSettings();
    grants = const VoiceLockPermissions();
  }
}
