# Circle 360 (`loc_360`)

Flutter app for family location sharing in India. Phone + OTP onboarding, a UPI Autopay paywall,
then a map of the people who share with you. Android package `com.spacewire.circle360`.

**The web build is only the marketing site.** `lib/main.dart` branches on `kIsWeb` and runs
`Circle360SiteApp` — the app proper never runs on web, because it needs a native background
location service and a UPI checkout that only exists inside the Cashfree app.

## Commands

```bash
flutter run --dart-define=SUNIOMAX_FORCE=true   # run the OTHER app in this build — see below
flutter test                      # 18 suites in test/
flutter analyze
dart format .
flutter build apk / ipa
deno test --allow-env supabase/functions/tests/   # Edge Function tests
supabase db push                  # migrations
supabase functions deploy <name>
```

All of these are already allowlisted in `.claude/settings.local.json`.

## Architecture

Riverpod MVVM, four layers, strictly one-directional:

```
view  ->  viewmodel  ->  repository interface  ->  implementation
```

**Every binding lives in [lib/data/providers.dart](lib/data/providers.dart).** No view and no
viewmodel imports a concrete implementation — swapping a backend means changing the right-hand
side of one provider and nothing else. Read that file before changing anything in the data layer.
The one sanctioned sibling is [lib/suniomax/data/providers.dart](lib/suniomax/data/providers.dart),
which holds the bindings belonging to the second app alone; the no-concrete-imports rule applies
there identically.

Routing is flat: [lib/app/router.dart](lib/app/router.dart) has no global redirect. The splash
resolves the stored session and each onboarding step decides where it goes next. Screens past the
paywall are wrapped in `EntitlementGate`, so a trial that lapses mid-session bounces the user back
to `/subscribe` rather than being noticed at the next cold start.

### The three-rung backend ladder

This is the most load-bearing non-obvious thing in the codebase. The app is walkable at every
level of configuration, and which rung is live changes what is real:

| Rung | Condition | What is real |
|---|---|---|
| Supabase | `Env.hasSupabase` | Everything. OTP proxied through Edge Functions, users persisted, Fast2SMS and Cashfree keys off-device |
| Fast2SMS direct | `Env.isConfigured` | Real SMS, but nothing is stored and the API key ships inside the app |
| Fake | neither | In-memory; any 6-digit code works and the paywall charges nothing |

Selected in [lib/data/providers.dart](lib/data/providers.dart) and reported on every analytics
event as `backendMode`, so a developer on the fakes is distinguishable from a real user.

### Two apps in one APK

The other load-bearing non-obvious thing. This build ships **Circle360 and SunioMax**, a
voice-lock app shown only to installs that arrived through a paid campaign, identified by the Play
install referrer. `bootMobileApp()` resolves which one a device runs and builds either
`Loc360App` or `SunioMaxApp`; every event carries `app` so the two funnels never merge.

Read [lib/suniomax/CLAUDE.md](lib/suniomax/CLAUDE.md) before touching anything there. Two things
to know before you touch anything *elsewhere*:

- **Circle360 is itself bought through Facebook Ads**, so its own installs carry the same
  `utm_source=facebook` a SunioMax campaign does. `AppVariant.resolve()` has an upgrade guard
  that pins any pre-existing install to Circle360 before the referrer is ever consulted. Removing
  it moves paying Circle360 subscribers into the wrong app on their next update.
- SunioMax reuses Circle360's auth, subscription and payment-status **ViewModels unchanged** —
  same numbers, same Edge Functions, same Cashfree plan. Only the views differ. A change to one of
  those ViewModels changes both products.

## Directory map

Each of these has its own `CLAUDE.md` with a one-line entry per file. **Read the subtree doc
before grepping or reading files in that area.**

| Directory | Contents |
|---|---|
| [lib/app/](lib/app/) | App shell, router, env, entitlement gate, analytics observer, theme |
| [lib/data/](lib/data/) | The whole data layer — providers, repositories + 3 implementations, models, analytics, payments, push |
| [lib/features/](lib/features/) | Every screen, as `*_view.dart` / `*_viewmodel.dart` / `*_state.dart` triples |
| [lib/suniomax/](lib/suniomax/) | **The second app in this build.** Its own shell, router, theme, widgets and screens — see below |
| [lib/widgets/](lib/widgets/) | Shared UI, exported from Figma |
| [lib/website/](lib/website/) | The marketing site — the entire web build, independent of the app |
| [supabase/functions/](supabase/functions/) | Edge Functions. Schema, security model and deploy steps are in [supabase/README.md](supabase/README.md) |
| [android/](android/) | Kotlin foreground-service location tracker |
| [ios/](ios/) | Swift CoreLocation tracker |
| [test/](test/) | 18 suites |

### Files directly under `lib/`

- [lib/main.dart](lib/main.dart) — the `kIsWeb` branch. 21 lines, and the only thing it decides.
- [lib/location_service.dart](lib/location_service.dart) — platform channel to the native
  trackers (`loc360/location` methods, `loc360/events` stream). Moves with `android/` and `ios/`.
- [lib/firebase_options.dart](lib/firebase_options.dart) — generated. Android and iOS only; the
  web build never touches Firebase.
- `lib/boot/` — `bootMobileApp()` behind a conditional export: `mobile_boot.dart` picks
  `mobile_boot_io.dart` (the real one, 191 lines) or `mobile_boot_stub.dart` (web, never called
  but required for the export to resolve).

## Reading rules

These exist to keep session cost down. Follow them.

- **Read the subtree `CLAUDE.md` first.** It is there so you do not have to glob.
- **Every file opens with a `///` block explaining *why* it is shaped the way it is.** Read the
  first ~20 lines before reading the whole file — several files here are 400-550 lines and the
  header usually answers the question on its own.
- **[MIXPANEL_TRACKING_PLAN.md](MIXPANEL_TRACKING_PLAN.md) is 46KB (~12k tokens).** It is the
  event-vocabulary reference. **Grep it, never read it whole.** Same for `pubspec.lock`.
- **Never read** `build/`, `.dart_tool/`, `.idea/`, `ios/Pods/`, `supabase/.temp/`, or the
  generated `GeneratedPluginRegistrant.*`.

## Conventions that matter

- **Analytics names are centralised** in
  [lib/data/analytics/analytics_events.dart](lib/data/analytics/analytics_events.dart) as `Ev.*`
  and `P.*`. Never type an event or property name at a call site — Mixpanel has no schema and no
  rename, so one typo becomes a permanent second event.
- **Screens are instrumented once**, by `analyticsObserver` in the router. Do not add per-screen
  tracking for navigation.
- **Secrets never ship in the app** on the Supabase rung. Fast2SMS and Cashfree credentials live
  in private `app_config` rows only the Edge Functions can read. `assets/env/app.env` is
  gitignored; `app.env.example` is the template. That file also carries an `APP_CONFIG_*` line
  per **public** `app_config` row, which is what the app runs on when Supabase never answers —
  gitignored is not secret, it is bundled as an asset and extractable from the APK, so a private
  row must never be pasted in (`Env.parseAppConfig` refuses secret-shaped keys, mirroring the
  `app_config_secrets_stay_private` constraint).
- **The client never sends amounts, plan ids or statuses.** Everything that decides what a user is
  charged and whether they are entitled is resolved server-side.
- **Figma node ids appear in view doc comments** (e.g. `Figma 12310:11295`). Keep them when
  editing a view.

## Maintaining these docs

When you add, remove or repurpose a file in a documented subtree, **update that subtree's
`CLAUDE.md` in the same change**. A stale entry is worse than no entry, because it will be
trusted.
