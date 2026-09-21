# `lib/features/` — screens

28 files. Most features are a `*_view.dart` / `*_viewmodel.dart` / `*_state.dart` triple; small
ones drop the state file. Views carry their Figma node id in the doc comment — keep it.

Listed in flow order, which is how the app actually runs.

## splash -> invite -> onboarding -> paywall

| File | What it does |
|---|---|
| `splash/splash_viewmodel.dart` | `SplashDestination` and where onboarding resumes for a given user, ignoring any deeplink. Shared with the invite screen so a dealt-with invite rejoins the normal flow. |
| `splash/splash_view.dart` | Figma `12310:11222` — logo on white while the session resolves. |
| `invite/invite_view.dart` | Figma `12362:12297`. Reached **only** when a deeplink brought the app up. |
| `invite/invite_viewmodel.dart` | `submit` returns the `SplashDestination` the flow resumes at, so a signed-out user goes on to the phone screen and an onboarded one lands on Home. |
| `invite/invite_state.dart` | 29 lines. |
| `onboarding/phone_view.dart` | Figma `12310:11223` — step 1 of 3. |
| `onboarding/otp_view.dart` | Figma `12310:11248` — step 2. Adds a resend control the frame does not show; without it a user whose SMS never arrives has no way forward. |
| `onboarding/name_view.dart` | Figma `12310:11274` — step 3, then straight to the paywall. |
| `onboarding/onboarding_viewmodel.dart` | Drives phone -> OTP -> name. Steps return a `SplashDestination` rather than a bare success, because step order is not the same thing as where the user belongs. |
| `onboarding/onboarding_state.dart` | One state object for all three steps — step 2 verifies the number entered in step 1. |
| `onboarding/widgets/onboarding_scaffold.dart` | The shared frame: warm page, white sheet, logo -> welcome -> prompt -> field -> button -> legal. The three frames differ only in `prompt` and `field`. |

## paywall and payment

| File | What it does |
|---|---|
| `subscription/subscription_view.dart` | Figma `12310:11295` — the paywall, backed by Cashfree UPI Autopay. **It is the gate:** no route out except a confirmed subscription, so it deliberately cannot be dismissed with the system back gesture. 541 lines. |
| `subscription/subscription_viewmodel.dart` | `SubscriptionPhase` — only `idle` accepts another tap. 476 lines. |
| `subscription/promo_video.dart` | **https or nothing.** iOS ATS and Android's default `usesCleartextTraffic = false` both refuse plain http, so an `http://` row fails on every device rather than some. |
| `subscription/promo_video_warmup.dart` | Pre-warms the player. A warmed player releases itself if unclaimed — the paywall is where onboarding leads but not always where it ends. |
| `payment_status/payment_outcome.dart` | Three-valued on purpose. "The UPI app handed control back" and "the money moved" are different claims, and the gap is a real state a user can sit in. |
| `payment_status/payment_status_view.dart` | Figma `12366:12435` / `12476` / `12514` — one screen, not three, because the frames share a skeleton. |
| `payment_status/payment_status_viewmodel.dart` | Keeps polling for a pending mandate. Exists because the paywall's own poll gives up after ~30 seconds. |

## location and the main app

| File | What it does |
|---|---|
| `location/location_permission_view.dart` | Asks for location in the app's own words before the OS dialog. Deliberately **not a gate** — Continue always reaches Home; a refusal leaves a banner, not a wall. |
| `home/home_view.dart` | The map, the people list, and the add-person flow. The invite branch confirms first: opening the share sheet unannounced reads as the app acting on the user's behalf. 443 lines. |
| `home/home_viewmodel.dart` | `HomeState`. |
| `emergency/emergency_view.dart` | Figma `12330:11580` (empty) and `12330:11606` (list). |
| `emergency/emergency_viewmodel.dart` | `EmergencyState`. |
| `profile/profile_view.dart` | Figma `12352:11678` — avatar straddling the sheet edge, three nav rows. |
| `profile/profile_viewmodel.dart` | Read-only; editing is a screen the design does not cover yet. 9 lines. |
| `settings/settings_view.dart` | Not in the Figma set. Hosts the entries the design implies plus the door to diagnostics. |
| `diagnostics/tracking_diagnostics_screen.dart` | The pre-Figma tracking UI, kept so the native pipeline stays observable. Reached via Profile -> Settings. Talks to `LocationService` **directly**, bypassing the ViewModel layer, on purpose — it is a debugging tool. 501 lines. |
| `auth/sign_out.dart` | Everything that must happen when a user leaves, in the one correct order. Lives here rather than at either call site because the app offers sign-out from two screens and each step is a real bug when it moves. |
