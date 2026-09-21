# `ios/` — the Swift location tracker

Sources live at `Runner/`. Moves together with [../android/CLAUDE.md](../android/CLAUDE.md) and
[../lib/location_service.dart](../lib/location_service.dart) — change one, check all three.

| File | What it does |
|---|---|
| `LocationTracker.swift` (260) | Owns CoreLocation and the 10-second cadence. **The cadence is a repeating timer, not the delegate callbacks:** CoreLocation only calls `didUpdateLocations` when the fix changes, so a stationary device would stop reporting entirely if the delegate were the clock. The timer posts the most recent fix on a fixed heartbeat, matching Android's fused provider. |
| `TrackingState.swift` (150) | UserDefaults mirror of Android's `TrackingState`. iOS can relaunch the app in the background after a force-quit, and nothing from the previous process survives except this — `isTracking` is what tells the relaunched process to resume. |
| `AppDelegate.swift` (136) | A non-nil `.location` launch key means iOS relaunched us in the background for a location event — **that is the entire force-quit / reboot recovery path**, and the Flutter UI is not running, so everything past that point is handled natively. Channels are registered via `applicationRegistrar` on the implicit engine. |
| `LocationUploader.swift` (89) | Posts a fix to `ingest-location`. **No offline queue, deliberately:** the backend keeps only the latest position per user, so a fix buffered through an outage is worthless ten seconds later. Failures are counted and dropped. Timeouts stay under the 10s cadence so a dead network cannot pile up requests. |
| `SceneDelegate.swift` (6) | Empty `FlutterSceneDelegate` subclass. |

`GeneratedPluginRegistrant.{h,m}` and `Runner-Bridging-Header.h` are generated or boilerplate.

## Things that bite

- `ios/Flutter/Facebook.xcconfig` is **gitignored**; `Facebook.xcconfig.example` is committed and
  documents both values. A fresh checkout will not build the Facebook SDK without it.
- Uploads go straight to `ingest-location` from Swift — a change to that function's auth or
  response codes has to land here **and** in `LocationUploader.kt`.
- Never read `Pods/`.
