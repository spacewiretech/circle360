# `android/` — the Kotlin location tracker, and the install-referrer gate

Sources live at `app/src/main/kotlin/com/example/loc_360/`.

> **The directory path does not match the package.** The files declare
> `package com.spacewire.circle360` while sitting in `.../com/example/loc_360/`. Gradle does not
> care, but do not rename the directory to "fix" it without checking the manifest and the Flutter
> plugin registrant.

Moves together with [../ios/CLAUDE.md](../ios/CLAUDE.md) and
[../lib/location_service.dart](../lib/location_service.dart) — change one, check all three.

| File | What it does |
|---|---|
| `LocationTrackingService.kt` (280) | The foreground service that owns the 10-second loop. **Runs independently of the Flutter engine:** after the task is swiped away the Dart isolate is gone but this service and its uploads keep going. That is the whole reason the cadence and the HTTP call are in Kotlin rather than Dart. |
| `MainActivity.kt` (309) | The Flutter bridge — `loc360/location` (`MethodChannel`) and `loc360/events` (`EventChannel`), plus the notification / location / background-location permission requests and the battery-optimisation exemption. |
| `TrackingState.kt` (169) | SharedPreferences state shared by the activity, the service and the boot receiver. The service outlives the engine, so this is the only place "is tracking on" and the upload counters survive; the UI reads it back on resume rather than assuming a fresh start. |
| `LocationUploader.kt` (109) | Posts a fix to `ingest-location` over `HttpURLConnection` on one background thread. Deliberately dependency-free — the only third-party library in the app is Play Services location. |
| `BootReceiver.kt` (72) | Restores tracking after the two events that would otherwise end it silently: reboot, and the restart alarm from `onTaskRemoved`. Only restarts if the user actually had tracking on. |
| `VoiceLockService.kt` (330) | SunioMax's listener. `foregroundServiceType="microphone"`, which brings two rules with it: it cannot be started from the background, so arming is only offered from the Voice Lock screen, and it cannot be started from `BOOT_COMPLETED` at all. `SpeechRecognizer` handles one utterance at a time, so this restarts it in a loop with a backoff — that is the platform's limit, not a shortcut. |
| `LockOverlay.kt` (250) | The lock screen, as a `TYPE_APPLICATION_OVERLAY` window rather than an Activity: Home cannot dismiss a window, and Android 10+ forbids starting an Activity from the background anyway. Back is swallowed. **The notification shade is not blocked and cannot be** — see the class comment. |
| `SunioState.kt` (130) | The voice lock's state, mirroring `TrackingState` for the same reason: the service outlives the Flutter engine. Deliberately **not** the `shared_preferences` plugin's own file, whose format is the plugin's to change. |
| `PhraseCapture.kt` (120) | Records one phrase and returns what the recogniser heard. **The phrase is spoken rather than typed on purpose** — a typed phrase never matches the recogniser's own transcription, so the lock would never fire. `VoiceLockBridge` stops the service around a capture, because two `SpeechRecognizer` instances cannot hold the microphone at once. |
| `VoiceLockBridge.kt` (300) | The `suniomax/voicelock` channels. Owns the microphone, overlay, notification and battery-exemption requests, and refuses to arm the lock without all of them. |
| `InstallReferrer.kt` (78) | Reads the Play campaign referrer, once per install. Nothing to do with tracking — it is what decides whether the device runs Circle360 or SunioMax, on its own `circle360/referrer` channel. Every failure path answers null, and null means "ask again", never "organic". The `AtomicBoolean` guard matters: `InstallReferrerStateListener` has two callbacks and a flaky Play Services fires both, which would resolve the Dart `Result` twice and kill the engine. |

`GeneratedPluginRegistrant.java` is generated — never edit or read it.

## Things that bite

- Uploads go straight to the `ingest-location` Edge Function from Kotlin. A change to that
  function's auth or response codes has to be reflected here **and** in the Swift uploader.
- OEM battery managers kill foreground services silently. That is what
  [../lib/widgets/tracking_banner.dart](../lib/widgets/tracking_banner.dart) exists to surface —
  do not remove the upload counters in `TrackingState.kt` that feed it.
- **`adb install` carries no install referrer**, and Play will not attribute one after the fact,
  so the SunioMax flow is unreachable on a development device without seeding it by hand — see
  [../lib/suniomax/CLAUDE.md](../lib/suniomax/CLAUDE.md).
- The `microphone` foreground service and the `SYSTEM_ALERT_WINDOW` overlay that SunioMax's voice
  lock needs are **not built yet**. When they are: `LocationTrackingService` is
  `foregroundServiceType="location"` only, so the microphone wants its own service and its own
  `FOREGROUND_SERVICE_MICROPHONE` permission — and Android 14+ refuses to start a microphone
  service from the background or from `BOOT_COMPLETED` at all, so `BootReceiver` cannot re-arm it
  the way it re-arms tracking.
