# `android/` — the Kotlin location tracker

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

`GeneratedPluginRegistrant.java` is generated — never edit or read it.

## Things that bite

- Uploads go straight to the `ingest-location` Edge Function from Kotlin. A change to that
  function's auth or response codes has to be reflected here **and** in the Swift uploader.
- OEM battery managers kill foreground services silently. That is what
  [../lib/widgets/tracking_banner.dart](../lib/widgets/tracking_banner.dart) exists to surface —
  do not remove the upload counters in `TrackingState.kt` that feed it.
