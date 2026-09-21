# `lib/app/` — shell, routing, config, theme

The wiring between `main()` and the screens. 6 files plus `theme/`.

| File | What it does |
|---|---|
| `app.dart` | `Loc360App`, the `MaterialApp.router`. Watches `deeplinkListenerProvider` and `analyticsBootstrapProvider` here rather than on the splash so both outlive the screen that triggered them — the splash is replaced within a frame or two. Also listens for a warm-start invite and routes to `/invite`. |
| `router.dart` | `Routes` constants + the flat `GoRouter`. No global redirect: the splash resolves the session and each onboarding step picks its own next step. `SplashDestinationRoute` maps a resolved destination to a route, shared by splash and invite. |
| `entitlement_gate.dart` | Wraps every screen behind the paywall and bounces the user back when access lapses. Exists because the splash gate only runs at cold start, and the trial is short enough to expire while the app sits in a pocket. |
| `analytics_observer.dart` | One `NavigatorObserver` instruments every screen, modal and back gesture. Hand-written screen names keyed by route *pattern* (that is what go_router puts in `RouteSettings.name`). |
| `env.dart` | Values read from `assets/env/app.env` at startup. Every getter tolerates a missing file — that is what flips `isConfigured` false and drops the app onto the fake rung. Also `Env.appConfig`: the `APP_CONFIG_*` lines, stripped and lowercased into `app_config` keys, which is the offline fallback for that table. Blank values are skipped and secret-shaped keys refused — the file ships inside the APK. |
| `assets.dart` | `Img` and `Svg` — every asset in the app, exported from Figma. |

## `theme/`

| File | What it does |
|---|---|
| `app_colors.dart` | `AppColors`. Raw hex read off the Figma design nodes — the file defines no Figma variables, so there is nothing more semantic to map to. |
| `app_theme.dart` | `AppShape` (geometry the design repeats) + `buildAppTheme()`. |
| `app_typography.dart` | `AppText`. Poppins for headings, labels and buttons; Inter for body copy, as in the design. |

## Gotchas

- **The `Firebase.apps.isNotEmpty` guard in `router.dart` is load-bearing.** `appRouter` is a
  top-level `final`, so it is constructed the moment anything imports the file — and
  `test/analytics_test.dart` and `test/subscription_test.dart` both import it without booting
  Firebase. An unguarded `FirebaseAnalytics.instance` throws `[core/no-app]` at import time and
  takes both suites down.
- **Firebase gets its own parallel `screen_view` stream**, deliberately named differently from
  Mixpanel's. The Mixpanel reports are built on the hand-written names in `analytics_observer.dart`.
- **`/payment-status/:outcome` is deliberately ungated.** A failed or pending payment is exactly
  the case where the user is not entitled; wrapping it would bounce them back to the paywall they
  just came from and they would never see the outcome.
- **`/location` is gated but is not itself a gate** — it always offers a way through to Home,
  whatever the user answers.
