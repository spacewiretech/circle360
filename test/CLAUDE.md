# `test/` — 14 suites

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
| `dialer_test.dart` (32) | `sanitiseForDialling`. |

## Notes

- **Tests import `appRouter` directly** (`analytics_test.dart`, `subscription_test.dart`) without
  booting Firebase. That is why [../lib/app/router.dart](../lib/app/router.dart) guards its
  `FirebaseAnalyticsObserver` behind `Firebase.apps.isNotEmpty` — remove the guard and both suites
  fail at import time with `[core/no-app]`.
- Tests run on the **fake** rung by default (no `app.env`), so `FakeSession` is the store behind
  most viewmodel tests.
