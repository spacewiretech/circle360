# `lib/data/` — the data layer

45 files. **Start at `providers.dart`** — every binding in the app is there, and nothing above
this layer imports a concrete class.

## The rung ladder, first

The single most confusing thing here is that there are three implementations of most
repositories. Which one is live is decided in `providers.dart` by `Env.hasSupabase` /
`Env.isConfigured`:

| Folder | Rung | Notes |
|---|---|---|
| `supabase/` | real | Everything persisted, all secrets off-device. What production runs. |
| `fast2sms/` | partial | Real SMS only. The account record still lives in `FakeSession`, and the API key ships in the app. |
| `fake/` | in-memory | Nothing survives a restart. Any 6-digit code works; the paywall charges nothing. |

`repositories/` holds the interfaces all three satisfy.

## Root files

| File | What it does |
|---|---|
| `providers.dart` | The whole data layer, bound. Also `backendMode`, sent with every event so a developer on the fakes is distinguishable from a real user in Mixpanel, and `appVariantProvider` — which of the two apps in this build is running. That one lives here rather than in `lib/suniomax/` because `authRepositoryProvider` depends on it, to stamp a new account with the app it signed up in. |
| `deeplink_service.dart` | `loc360://` scheme + `parseInvite`. The https App Links / Universal Links half is scaffolding until `assetlinks.json` and `apple-app-site-association` are hosted. **The URL shape must stay in sync with `lib/website/pages/invite_page.dart`.** |
| `pending_invite.dart` | The invite the app was opened with and has not acted on. Held here so `splashDestinationProvider` stays side-effect-free: the service writes, the screens read and clear. |
| `entitlement.dart` | The last entitlement answer the server gave, cached where the routing layer can read it *synchronously*. Deliberately not recomputed on write. |
| `dialer.dart` | Opens the dialer with the number typed in. The dialer, not a direct call — `CALL_PHONE` would trigger Play Store review friction for no gain. |

## `analytics/` (7)

| File | What it does |
|---|---|
| `analytics_events.dart` | **The event and property vocabulary — `Ev.*` and `P.*`.** Never type a name at a call site: Mixpanel has no schema and no rename, so one typo is a permanent second event. |
| `analytics.dart` | The `Analytics` interface. Narrow and synchronous where it can be — a `track` sits inside button handlers and payment callbacks, neither of which may wait. `MultiAnalytics` fans out; `NoopAnalytics` is the default. |
| `mixpanel_analytics.dart` | The real sink, with a queue in front. The queue exists because the project token is a Supabase `app_config` row, not a compiled-in constant, so events can be produced before the token arrives. |
| `facebook_analytics.dart` | Conversion reporting for Facebook Ads. The app is bought through Facebook Ads, and an optimiser that only sees installs buys installs that never pay. **Both apps in this build report to the same Facebook app**, and `registerSuper` is a no-op here — Facebook's parameters are per-event — so `contentId` (from `AppVariant.fbContentId`) is the only thing telling the two products apart on that side. |
| `analytics_context.dart` | Device and app facts gathered once and attached as super properties. The header documents what is deliberately **not** collected. |
| `analytics_session.dart` | Sessions, app lifecycle, and the round trip out to a UPI app and back. |
| `att_consent.dart` | The iOS ATT prompt, once per install. |

`analyticsSink<T>(analytics)` looks *inside* the `MultiAnalytics` fan-out — a plain
`analytics is MixpanelAnalytics` test is false in production and will silently leave a sink
unstarted.

## `supabase/` (6)

| File | What it does |
|---|---|
| `edge_functions.dart` | The call wrapper + `EdgeFunctionException`, whose stable `code` strings (`invalid_otp`, `otp_expired`, `throttled`, `unauthorized`…) are what the app maps onto its exception types. |
| `session_store.dart` | The `verify-otp` bearer token, in Keychain/Keystore via `flutter_secure_storage`. The cached user beside it is only a convenience. |
| `supabase_auth_repository.dart` | Calls Edge Functions, never tables — `users` has RLS on with **no policies**, so the anon key can do nothing with it. `verify-otp` also carries `app`, which stamps a brand new row's `signup_app`. Attribution only: it is the one thing here a modified client could choose, and choosing it buys nothing, because both apps open the same mandate on the same plan. |
| `supabase_family_repository.dart` | `people` / `add-person` / `respond-request`. **Polls rather than using Realtime**: the app authenticates with its own opaque token, not a Supabase JWT, so there is no `auth.uid()` for Realtime's RLS to key off. |
| `supabase_subscription_repository.dart` | The payment functions. Cashfree is never called from the device, and the client sends no amount, plan id or status — only its session token. |
| `supabase_app_config_repository.dart` | Reads `app_config` with a disk cache in front. The splash waits on this, so it serves cached-when-fresh and stale-on-failure rather than ever hanging. Under both sits `appConfigFallbacks()` — the `APP_CONFIG_*` env lines over `defaultAppConfig` — so a device that has never reached Supabase still runs on real values. |

## `repositories/` (7) — the interfaces

`auth_repository.dart` (+ `InvalidOtpException`), `family_repository.dart` (people and requests
arrive as one value, from one call, so they can never disagree for a tick),
`subscription_repository.dart` (+ `SubscriptionException`, message already safe to show),
`app_config_repository.dart` (also the typed reads, `defaultAppConfig`, and `appConfigFallbacks()`
— the four-rung ladder is fetch → cache → `assets/env/app.env` → `defaultAppConfig`, so Supabase
always outranks a value shipped in the build), `invite_repository.dart` (deliberately separate from
`FamilyRepository.addPerson` — an invite stays pending), `profile_repository.dart`,
`emergency_repository.dart`.

## `models/` (6)

| File | What it does |
|---|---|
| `app_user.dart` | `AppUser`, `PaymentType` (mirrors the `public.payment_status` enum — the database owns the spelling) and the separate "why is a live subscription unhappy" state. |
| `tracked_person.dart` | `ShareStatus` — three states share one row because that is how the screen presents them, but only `sharing` ever carries a position. |
| `upi_app.dart` | A UPI app as reported by the Cashfree SDK. The SDK answers `getupiapps` differently per platform, so the parsing lives here and only here. |
| `subscription_offer.dart` | Paywall display copy only. The amounts actually charged live in the Cashfree plan and private `app_config` rows. |
| `invite_link.dart` | An invite carried in by a deeplink. |
| `emergency_contact.dart` | 18 lines. |

## The rest

- **`fake/` (7)** — `fake_session.dart` is the shared in-memory store every other fake reads, so
  screens stay consistent for the length of a run. `fake_family_repository.dart` nudges positions
  every few seconds and walks the real `pending -> sharing` state machine, so it exercises the
  same shapes the Supabase poll does. `fake_subscription_repository.dart` grants the trial the
  way the real path does, by setting a `trialEndsAt`. Then the thin ones:
  `fake_auth_repository.dart` (any code passes), `fake_profile_repository.dart`,
  `fake_emergency_repository.dart`, `fake_invite_repository.dart` (13 lines).
- **`fast2sms/` (3)** — `fast2sms_client.dart` (`baseUrl` and auth header injected, not
  hardcoded), `fast2sms_auth_repository.dart`, `fast2sms_exception.dart` (carries two messages on
  purpose: `userMessage` is safe on screen, `developerDetail` names the real cause and only
  reaches the debug log).
- **`cashfree/` (2)** — `cashfree_checkout.dart` (the SDK, plus a fake; note that `verified` means
  the UPI app handed control back, **not** that money moved — only the server can answer that) and
  `upi_app_preference.dart` (SharedPreferences, not the Keychain — it is cosmetic).
- **`location/location_controller.dart`** — owns this device's side of sharing and is the only
  place that decides. The thing that actually runs is the native tracker, via
  `lib/location_service.dart`.
- **`push/push_messaging.dart`** — all FCM handling. Nothing here runs at boot: the notification
  permission prompt is a one-shot irreversible ask on both platforms.
