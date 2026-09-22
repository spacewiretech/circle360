# `test/` — 18 suites

`flutter test`. Edge Function tests are separate — `deno test` in
[../supabase/functions/tests/](../supabase/functions/tests/).

| File | Covers |
|---|---|
| `subscription_test.dart` (687) | The payment surface: `SdkCashfreeCheckout.installedApps`, offline entitlement, trial eligibility, routing, `PaymentOutcome.parse`, `UpiApp.fromChannel`, `SubscriptionViewModel` incl. UPI app selection. |
| `fast2sms_test.dart` (450) | `Fast2SmsClient` send / verify / transport failures, `Fast2SmsAuthRepository`, and the OTP rules in `OnboardingViewModel`. |
| `analytics_test.dart` (347) | Mixpanel buffering (events produced before the token arrives), people properties, screen names, the navigator observer, tap tracking. |
| `promo_video_warmup_test.dart` (302) | Claiming, rows that warrant no player, lifecycle. |
| `supabase_test.dart` (272) | App config caching and `SupabaseAuthRepository.currentUser`. |
| `facebook_analytics_test.dart` (261) | The off switch, the allowlist, purchases, identity. |
| `widget_test.dart` (212) | The native tracking bridge: `TrackingStatus.fromMap`, upload credentials, `LocationPermission`, `TrackingDiagnosticsScreen`. |
| `viewmodel_test.dart` (200) | `OnboardingViewModel`, `HomeViewModel`, `EmergencyViewModel`. |
| `sharing_test.dart` (187) | `TrackedPerson.fromServer` and `LocationState`. |
| `invite_test.dart` (180) | `parseInvite`, `splashDestinationProvider`, `InviteViewModel`. |
| `website_test.dart` (162) | Home page, policy routes, invite landing — and that the `site_copy.dart` placeholders are still flagged as placeholders. |
| `sign_out_test.dart` (141) | `signOutProvider` — the ordering that each step depends on. |
| `otp_field_test.dart` (140) | The single-field OTP box, especially paste and autofill, which is why it is one `TextField` and not six. |
| `app_variant_test.dart` (34 tests) | **The SunioMax gate** — referrer parsing, the `app_config` matching rule, and `AppVariant.resolve`. Most of it is about the ways the gate must answer Circle360: no channel, a timeout, a throw, and above all an **upgrade**, since Circle360 is itself bought through Facebook Ads and its own users carry the same `utm_source`. |
| `suniomax_test.dart` (19 tests) | SunioMax's routing table, that no `/sx` path collides with a Circle360 one, that `sunioRouter` builds with no Firebase app, the screen-name prefixes, and the language store. |
| `suniomax_audio_test.dart` (17 tests) | SunioMax's onboarding voice-over: which `app_config` row each screen reads, everything that counts as "nothing to play" (missing, blank, `http://`, not a URL), the paywall fallback to `paywall_video_url`, and that the mute preference defaults to **unmuted** — the accessibility affordance must fail towards playing. The controller itself is not covered: it opens a real `VideoPlayerController`, which needs a platform. |
| `voice_lock_test.dart` | The voice lock's Dart half, and mostly its **refusals** — a lock that arms with no way back in is a phone its owner cannot open. `VoiceLockSettings`, `phrasesConflict`, `VoiceLockPermissions`, turning the lock on, and `LocalVoiceLockRepository` incl. that the passcode never reaches storage in plaintext. The matching and the overlay live in Kotlin and are not reachable from here. |
| `dialer_test.dart` (32) | `sanitiseForDialling`. |

## Notes

- **Tests import `appRouter` directly** (`analytics_test.dart`, `subscription_test.dart`) without
  booting Firebase. That is why [../lib/app/router.dart](../lib/app/router.dart) guards its
  `FirebaseAnalyticsObserver` behind `Firebase.apps.isNotEmpty` — remove the guard and both suites
  fail at import time with `[core/no-app]`.
- Tests run on the **fake** rung by default (no `app.env`), so `FakeSession` is the store behind
  most viewmodel tests.
- **Every suite runs as Circle360.** `appVariantProvider` defaults to `AppVariant.circle360`, and
  in a test process there is no `circle360/referrer` channel, so `AppVariant.resolve()` catches
  `MissingPluginException` and answers Circle360. Nothing in the existing suites had to change for
  the second app to exist.
- `suniomax_test.dart` is the one suite that **reads** `sunioRouter`. That matters: a top-level
  `final` is built on first read, not on import, so this is what actually exercises the
  `Firebase.apps.isNotEmpty` guard in `lib/suniomax/app/router.dart`.
