# Circle360 (Loc360) — Mixpanel Tracking Plan

**Product:** Circle360 / Loc360 (family & friends live location sharing)
**Platforms:** Flutter app (Android + iOS) + Supabase Edge Functions (server)
**SDK:** `mixpanel_flutter` (app) · Mixpanel HTTP Track/Engage API (server)
**`distinct_id`:** `users.user_id` — the database primary key. Never a phone number.
**Last updated:** 10 September 2026

---

## 1. Overview

| Source | Live events | What it answers |
|--------|-------------|-----------------|
| **Flutter app** | 99 | Everything the user does in front of the screen: onboarding, paywall, payments, location permission, the map, people, invites |
| **Supabase Edge Functions** | 9 | Everything that happens while the app is closed: webhook deliveries, recurring UPI debits, mandate holds, cancellations, refunds, disputes |
| **Total live** | **108** | |

**Every name declared in `analytics_events.dart` is emitted by something.** There is no
declared-but-dead column in this project — worth re-checking whenever a constant is added, because
an unused constant is a report someone will eventually build on nothing.

**Two rules that shape the whole plan:**

1. **Event names are Title Case, past tense** (`Payment Completed`, not `complete_payment`).
   Property keys are `snake_case`. Every name lives as a constant in
   [analytics_events.dart](lib/data/analytics/analytics_events.dart), never as a string literal at
   the call site — a typo in an event name does not fail, it *forks* into a second half-populated
   column, and a funnel built on the wrong one silently under-counts.
2. **No event names the screen it happened on.** The navigator observer stamps `screen` onto every
   event as it is recorded. A screen added next month is instrumented the moment it is routable.

---

## 2. How the plumbing works

```
ViewModel / widget
      │  analytics.track("Event Name", {...})
  MultiAnalytics  ──────────────┬──────────────────┐
      │                         │                  │
  MixpanelAnalytics       FacebookAnalytics   (NoopAnalytics in tests / web)
      │  queue → SDK           │  4 events only
   Mixpanel                Meta Ads

  FirebaseAnalyticsObserver ── attached to the router, NOT to MultiAnalytics
```

Four things a PM should know about this:

- **The Mixpanel token lives in Supabase `app_config`, not in the build.** It can be rotated or
  switched off without shipping a new app version — clearing the row is the off switch, and the app
  falls back to `NoopAnalytics` and behaves exactly as it did before analytics existed. Because the
  token is not in hand at launch, the first events (`App Launched`, `Session Started`, the first
  screen views) are **queued** and sent once the token arrives, each carrying `queued_lag_ms` so a
  delayed event is never mistaken for a slow user. Queue caps: 300 events / 5 minutes.
- **Facebook only ever receives 4 of the 99 events** (see [§10](#10-facebook-ads-conversions)).
  Mixpanel answers product questions and needs everything; an ad optimiser needs a handful of
  conversions.
- **Firebase Analytics is not a third sink in the fan-out.** It is attached to the router as a
  `FirebaseAnalyticsObserver` and is only ever wanted for the automatic events (`first_open`,
  `session_start`, `app_update`) that Google Ads and Play Console read. The hand-curated funnel is
  Mixpanel's alone — routing it into Firebase as well would mean maintaining a third event
  vocabulary for no question anyone is asking.
- **Server events never delay a payment.** Mixpanel sends from the webhook run on
  `EdgeRuntime.waitUntil` with a 4-second timeout, and every failure is logged and swallowed. An
  unreachable Mixpanel costs us analytics, never someone's subscription.

**Code map**

| Component | Location |
|-----------|----------|
| Event & property name constants | [analytics_events.dart](lib/data/analytics/analytics_events.dart) |
| Mixpanel sink (queue, identify, super properties) | [mixpanel_analytics.dart](lib/data/analytics/mixpanel_analytics.dart) |
| Fan-out to multiple sinks, `trackedTap` | [analytics.dart](lib/data/analytics/analytics.dart) |
| Device/app context (super properties) | [analytics_context.dart](lib/data/analytics/analytics_context.dart) |
| Sessions, lifecycle, UPI hand-off | [analytics_session.dart](lib/data/analytics/analytics_session.dart) |
| Screen views & the ambient `screen` property | [analytics_observer.dart](lib/app/analytics_observer.dart) |
| iOS ATT consent | [att_consent.dart](lib/data/analytics/att_consent.dart) |
| Facebook Ads sink | [facebook_analytics.dart](lib/data/analytics/facebook_analytics.dart) |
| Boot wiring & crash handlers | [mobile_boot_io.dart](lib/boot/mobile_boot_io.dart) |
| Server Mixpanel helper | [mixpanel.ts](supabase/functions/_shared/mixpanel.ts) |
| Server subscription/payment events | [subscription_sync.ts](supabase/functions/_shared/subscription_sync.ts) |
| Webhook entry point | [cashfree-webhook/index.ts](supabase/functions/cashfree-webhook/index.ts) |

---

## 3. Super properties — attached to every app event

Gathered once at boot and merged into every event, so no call site has to pass them.

| Property | Type | Value |
|----------|------|-------|
| `screen` | string | The screen the user was on when the event fired — filled in by the navigator observer. **This is why no event has to name its own screen.** |
| `is_modal` | boolean | Present only when the current surface is a sheet or dialog |
| `session_id` | string | Survives a process death inside the 30-minute idle window |
| `install_id` | string | Stable per installation, **survives sign-out** (unlike Mixpanel's `$device_id`). This is what makes "two accounts on one handset" answerable |
| `days_since_install` | number | |
| `is_new_user` | boolean | True on the very first launch |
| `previous_version` | string | Present only on the first launch after an upgrade |
| `app_version`, `build_number` | string | |
| `build_mode` | string | `release` / `profile` / `debug` — **filter `build_mode = release` in every report** |
| `env` | string | From `app_config` |
| `backend_mode` | string | `supabase` / `fast2sms` / `fake` — a developer running against the fake repositories would otherwise pollute production funnels with free subscriptions |
| `app_language`, `app_locale` | string | The language the app is *rendering* in. A Hindi speaker and an English speaker in the same city are the same row without this, and they are not the same user |
| `utc_offset_minutes` | number | India is UTC+5:30 and the backend stores UTC |
| `queued_lag_ms` | number | Present only when the event waited for the Mixpanel token |
| `preferred_upi_app` | string | Registered once a UPI app is preselected or changed on the paywall — which app a user pays with predicts whether the mandate succeeds |

**Identity super properties** (added on `identify`, **dropped on sign-out** so the next user of the
handset does not inherit the last one's account): `is_signed_in`, `payment_type`, `entitled`,
`in_trial`, `has_ever_subscribed`, `billing_state`.

**Deliberately absent:** device model, manufacturer, OS version, screen size, carrier, library
version, and the city/region/country Mixpanel derives from the request IP. The native SDK already
attaches all of these. Adding them here would not add a field — it would add a *second* field under
a non-standard name, invisible to every built-in Mixpanel report.

---

## 4. Core funnels

```
App Launched
   → Screen Viewed (Phone)
   → OTP Requested → OTP Submitted → OTP Verified
   → Name Submitted → Signup Completed
   → Paywall Viewed
   → Subscribe Tapped
   → Mandate Start Succeeded → UPI Intent Launched
   → UPI App Opened → UPI App Returned          ← the 30 seconds we are blind to without these
   → Payment Completed (outcome = success)      ← the one event with money on it
   → Location Permission Requested → Location Permission Result   ← the permission the product needs to work
   → Location Tracking Started
   → Home Viewed
   → Add Person Submitted → Invite Sent → Request Accepted
   ─────────────────────────────────────────────
   ← Mandate Authorised        (server, first charge)
   ← Subscription Renewed      (server, monthly autopay)
   ← Subscription Cancelled    (server, churn)
```

**The six funnels worth building first:**

| # | Funnel | Steps | What it tells you |
|---|--------|-------|-------------------|
| 1 | **Acquisition** | `App Launched` → `OTP Requested` → `OTP Verified` → `Signup Completed` | Where phone auth leaks. Break down by `entry_method` to see whether OTP autofill is working |
| 2 | **Purchase** | `Paywall Viewed` → `Subscribe Tapped` → `Mandate Start Succeeded` → `Payment Completed (outcome=success)` | Break down by `flow` (`intent` vs `cashfree_checkout`) and `app_id`. The Cashfree checkout-screen fallback converts materially worse than a one-tap UPI intent |
| 3 | **Trial vs plan** | Same as #2, broken down by `offer_type` (`trial` / `plan`) | A trial and a full-price purchase convert nothing like each other; a single paywall conversion rate averages them into meaninglessness |
| 4 | **Permission** | `Payment Completed` → `Location Permission Requested` → `Location Permission Result (result = whileInUse\|always)` → `Location Tracking Started` | **The activation funnel for this product.** A paying user who denies location has bought something that cannot work. Break down `Location Permission Result` by `trigger` (`foreground` / `background` / `app_settings`) |
| 5 | **Circle formation** | `Home Viewed` → `Add Person Sheet Opened` → `Add Person Submitted` → `Invite Sent` → `Request Accepted` | Whether a paying user ever gets a second person on the map. Break down `Add Person Submitted` by `is_existing_user` — an existing user connects instantly, a new one has to be invited and install the app |
| 6 | **Retention & churn** | `Mandate Authorised` → `Subscription Renewed` (renewal 1) → `Subscription Renewed` (renewal 2+) · vs `Subscription Cancelled` / `Subscription Payment Failed` | The whole paid relationship. All server-side |

---

## 5. App events — lifecycle, navigation & infrastructure (15)

| Event | Fires when | Where | Key properties |
|-------|-----------|-------|----------------|
| `App Launched` | Cold start, once the session is resolved | `analytics_session.dart` | `is_first_launch`, `cold_start`, `seconds_since_last_open` |
| `Session Started` | A new session begins (first launch, or a foreground after 30+ minutes idle) | `analytics_session.dart` | — |
| `Session Ended` | The idle timeout is crossed, or the app detaches | `analytics_session.dart` | `duration_seconds`, `screens_viewed` |
| `App Foregrounded` | App returns to the foreground | `analytics_session.dart` | `seconds_backgrounded` |
| `App Backgrounded` | App goes to the background. **Everything queued is flushed here** — the process may not survive | `analytics_session.dart` | `session_seconds` |
| `App Terminated` | Best-effort on detach (Android often kills the process without delivering this) | `analytics_session.dart` | `session_seconds` |
| `App Crashed` | An uncaught Flutter or platform error. **Live**, and sent alongside Crashlytics rather than instead of it — Crashlytics gets the full stack and the native crashes, this sits in the same event stream as everything the user did beforehand | `mobile_boot_io.dart` | `error`, `stack_head` (three frames), `fatal` |
| `Tracking Consent Resolved` | iOS ATT status is answered, or was already standing. Asked when the **paywall** opens, or on Home for a user who never sees one | `att_consent.dart` | `status`, `granted`, `prompted` (**false = a standing answer, so the opt-in *rate* can be measured over people actually asked**) |
| `Screen Viewed` | Any route is pushed, replaced, or resurfaced after a back | `analytics_observer.dart` | `screen`, `previous_screen`, `route_path`, `nav_type`, `is_modal`, plus `route_*` params |
| `Screen Exited` | Any route is popped, replaced or removed | `analytics_observer.dart` | `screen`, `route_path`, `exit_type`, `seconds_on_screen` |
| `Back Pressed` | The user goes back — the system gesture, a back button, or a dismissed sheet | `analytics_observer.dart`, plus two explicit `blocked: true` call sites | `screen`, `blocked`, `is_modal`, `outcome` |
| `Element Tapped` | Any tap on a shared widget wrapped in `trackedTap` | `analytics.dart` + call sites | `element_id`, `label`, sometimes `state` / `action` |
| `Deep Link Opened` | An invite link brings the app up, or arrives while it is running | `splash_viewmodel.dart` (`cold_start: true`), `app.dart` (`cold_start: false`) | `link_type`, `code`, `inviter_name`, `cold_start` |
| `Error Shown` | An error message is shown to the user | `onboarding_scaffold.dart`, `home_viewmodel.dart`, `emergency_viewmodel.dart` | `message`, `source` (`add_emergency_contact`, `accept_request`, `decline_request`, or the failing button's id), `code` |
| `Splash Resolved` | The splash decides where to send the user | `splash_viewmodel.dart` | `destination`, `is_signed_in`, `entitled`, `has_name`, `payment_type`, `ms` |

> `Back Pressed` fires with `blocked: true` from two places the user cannot actually leave: the
> **Paywall** and the **Payment Status** screen. A run of blocked back presses on Payment Status is
> a user trying to escape a verdict they do not accept.

**Screen names** reported by `Screen Viewed`: Splash, Invite, Phone, OTP, Name, Paywall, Payment
Status, Location Permission, Home, Emergency, Profile, Settings, Diagnostics.

**Modal names:** UPI App Picker, Add Person Sheet, Invite Confirm Dialog, Remove Person Dialog,
Sign Out Dialog. A `showDialog` given no `routeSettings` arrives as `Unnamed <RouteType>` — countable,
but not identifiable, so name new sheets as they are added.

> Note: `/payment-status/:outcome` reaches the observer with the colon still in it, never with
> `success` substituted. The resolved value comes through `RouteSettings.arguments` and is reported
> as `route_outcome`, so it is one screen with a property rather than three screens.

**`Element Tapped` ids in use:** `phone_continue`, `otp_continue`, `name_continue`, `subscribe`,
`back_button`, `add_person_card`, `person_card_expand` / `person_card_collapse`, `person_action`,
`request_accept` / `request_decline`, `paywall_video_mute`. Anything without an explicit id falls back
to a slug of its label, with digits stripped — so `Subscribe · ₹499/month` and `Start trial · ₹3`
do not become two unrelated columns.

---

## 6. App events — onboarding & sign-out (18)

All in [onboarding_viewmodel.dart](lib/features/onboarding/onboarding_viewmodel.dart) and
[sign_out.dart](lib/features/auth/sign_out.dart).

| Event | Fires when | Key properties |
|-------|-----------|----------------|
| `Phone Entry Started` | First keystroke in the phone field (once per screen) | — |
| `Phone Number Entered` | The phone reaches full length (once per screen) | — |
| `OTP Requested` | "Send OTP" tapped — **including when the validator refused it**. A run of `valid: false` is a broken phone field that would otherwise leave no trace | `valid` |
| `OTP Request Failed` | The provider refused to send | `message`, `trigger` (`resend` when it was a resend) |
| `OTP Entry Started` | First keystroke in the OTP field | — |
| `OTP Resend Requested` | Resend accepted | `resends_used` |
| `OTP Resend Blocked` | Resend refused. Separates "the SMS never arrived and they are out of resends" from "they tapped twice inside the cooldown" | `reason` (`exhausted` / `cooldown`), `seconds_remaining`, `resends_used` |
| `OTP Submitted` | Verify attempt starts | `entry_method` (`button` / `auto_complete`), `attempts_used`, `resends_used` |
| `OTP Verified` | Code accepted | `entry_method`, `attempts_used`, `resends_used`, `is_new_user`, `has_name`, `destination`, `seconds_to_verify` |
| `OTP Verification Failed` | Code rejected, expired or the send failed | `reason`, `attempts_used`, `attempts_left`, `resends_used`, `error`, `seconds_to_verify` |
| `OTP Attempts Exhausted` | The attempt budget runs out | `resends_used` |
| `Name Entry Started` | First keystroke in the name field | — |
| `Name Submitted` | Name screen submitted | `name_length` (the length, never the name) |
| `Name Save Failed` | Server refused the name | `message` |
| **`Signup Completed`** | Name saved — **the end of onboarding and the denominator of everything after it** | `destination` |
| `Sign Out Requested` | The confirmation dialog opens | `source` (`profile` / `settings`) |
| `Sign Out Cancelled` | The dialog is dismissed or "Cancel" is tapped | `source` |
| `Signed Out` | Logout, fired **before** the identity reset so it lands on the account that actually left | `source` |

> **`is_new_user` on `OTP Verified` is the property that separates signup from login.** It is derived
> from `!user.hasName` — a returning user on a wiped device already has a name and must not be
> counted as a signup.

> The three sign-out events exist as a set on purpose. Without `Sign Out Requested` and
> `Sign Out Cancelled`, someone who opens the confirmation dialog and backs out is indistinguishable
> from someone who never reached for it — and the gap between the two is the only measure of whether
> the confirmation step is earning its tap.

---

## 7. App events — paywall & payment (36)

The single most instrumented flow in the app. **Every event in one checkout attempt carries
`payment_attempt_id`** and `attempt_number` — without it, a user who tries three times is one
indistinguishable smear of events.

### 7.1 Paywall (4)

| Event | Fires when | Where | Key properties |
|-------|-----------|-------|----------------|
| `Paywall Viewed` | The paywall paints (once per visit) — **the denominator of the purchase funnel** | `subscription_view.dart` | `trial_available`, `state` (`loading` / `loaded` — **whether `trial_available` is authoritative yet; it defaults to true until the user's history comes back**) |
| `Paywall Offer Loaded` | Offer, user and UPI app list all resolve | `subscription_viewmodel.dart` | `trial_price`, `plan_price`, `trial_days`, `trial_available`, `upi_app_count` (**zero here means Cashfree's own checkout screen stands in for the one-tap intent — a materially worse flow**), `ms` |
| `Paywall Offer Load Failed` | Any of the three fail | `subscription_viewmodel.dart` | `error`, `ms` |
| `Paywall Video Failed` | The promo above the sheet could not be played. The URL is an operator-editable `app_config` row, so a dead link is invisible from every angle except a conversion number that quietly moved | `promo_video.dart`, `promo_video_warmup.dart` | `source` (**the host, never the URL — the row could carry a signed link with a token in the query string**), `error`, `trigger` (`prewarm` = the warm-up failed and the paywall will still try, which costs the user nothing) |

### 7.2 UPI app selection (6)

| Event | Fires when | Where | Key properties |
|-------|-----------|-------|----------------|
| `UPI Apps Discovered` | Cashfree returns the installed UPI apps | `cashfree_checkout.dart` | `count`, `app_ids` (**which apps, not just how many** — mandate success rates differ sharply between PSPs), `ms` |
| `UPI Discovery Failed` | Discovery throws or times out | `cashfree_checkout.dart` | `reason` (`timeout` / `error`), `error`, `ms` |
| `UPI App Preselected` | An app is picked for the user on load. Also registers `preferred_upi_app` as a super property | `subscription_viewmodel.dart` | `app_id`, `source` (`remembered` / `first` / `none`) |
| `UPI Picker Opened` | "Change" tapped | `subscription_view.dart` | `app_id`, `available_count` |
| `UPI Picker Dismissed` | The picker closes without a change | `subscription_view.dart` | `app_id`, `available_count` |
| `UPI App Changed` | A different app is chosen | `subscription_viewmodel.dart` | `from_app_id`, `to_app_id`, `position_in_list`, `available_count` |

### 7.3 Checkout (15)

| Event | Fires when | Where | Key properties |
|-------|-----------|-------|----------------|
| **`Subscribe Tapped`** | The subscribe button is pressed and accepted. **Also starts Mixpanel's stopwatch on `Payment Completed`** | `subscription_viewmodel.dart` | `payment_attempt_id`, `attempt_number`, `app_id`, `offer_type` (`trial` / `plan`), `amount`, `flow` (`intent` / `cashfree_checkout`) |
| `Subscribe Tap Ignored` | The button was tapped while busy or loading. **A run of these means the button looks tappable while it is working** | `subscription_viewmodel.dart` | `reason` (`loading` / `busy`), `attempt_number` |
| `Mandate Start Requested` | The create-subscription call goes out | `subscription_viewmodel.dart` | attempt properties |
| `Mandate Start Succeeded` | Server returns a mandate session | `subscription_viewmodel.dart` | `subscription_id`, `environment`, `ms` |
| `Mandate Start Refused` | Server declined to open a mandate | `subscription_viewmodel.dart` | `code`, `message` |
| `Mandate Already Entitled` | Server refused because the account is already in a trial or paid month. **Nothing was charged** | `subscription_viewmodel.dart` | attempt properties |
| `UPI Intent Launched` | Control is handed to the UPI app (or Cashfree's screen) | `subscription_viewmodel.dart` | `app_id`, `app_name`, `flow`, `subscription_id` |
| `UPI App Opened` | The app backgrounds while a UPI hand-off is outstanding | `analytics_session.dart` | `app_id` (`cashfree_checkout` when no app was named) |
| `UPI App Returned` | The app foregrounds after that hand-off | `analytics_session.dart` | `app_id`, `seconds_in_upi_app` |
| `Checkout Verified Callback` | Cashfree's SDK reports the UPI app handed control back. **Explicitly not proof of payment** | `cashfree_checkout.dart` | `subscription_id`, `seconds_in_checkout` |
| `Checkout Failed Callback` | Cashfree's SDK reports a failure | `cashfree_checkout.dart` | `cf_status`, `cf_code`, `cf_type`, `message`, `seconds_in_checkout` — **the code and type are what separate "our mandates are misconfigured" from "our paywall is unconvincing"** |
| `Checkout Orphan Callback` | A result arrives for an attempt nobody is waiting on (usually the app was killed mid-payment) | `cashfree_checkout.dart` | `outcome` |
| `Checkout Restarted` | A second attempt starts over an unfinished first | `cashfree_checkout.dart` | `app_id` |
| `Checkout Launch Failed` | The SDK could not be launched at all | `cashfree_checkout.dart` | `app_id`, `error` |
| `Checkout Timed Out` | No callback arrived inside the timeout | `cashfree_checkout.dart` | `app_id`, `seconds_in_checkout` |

### 7.4 Confirmation (11)

| Event | Fires when | Where | Key properties |
|-------|-----------|-------|----------------|
| `Entitlement Poll Started` | The app starts asking the server whether money actually moved (**8 attempts if the SDK verified, 3 if not** — approving in Google Pay then swiping back instead of waiting for the redirect is ordinary behaviour and surfaces as a failure on a mandate that succeeded) | `subscription_viewmodel.dart` | `max_attempts`, `sdk_verified` |
| `Entitlement Poll Failed` | One poll round trip failed. **A dropped poll is not a failed payment** | `subscription_viewmodel.dart`, `payment_status_viewmodel.dart` | `attempt`, `error` |
| **`Payment Completed`** | **The single exit from every checkout path** — success, failure and pending all report here with `outcome` as a property, so the funnel has one step to break down. Timed with Mixpanel's own stopwatch, so `$duration` survives the app being backgrounded for the whole UPI hand-off | `subscription_viewmodel.dart` | `outcome` (`success` / `failed` / `pending`), `sdk_verified`, `poll_attempts`, `reason`, `total_seconds`, `$duration`, attempt properties |
| `Payment Status Viewed` | The status screen opens. **The verdict the user was shown, which is not always the verdict that was true** | `payment_status_view.dart` | `outcome`, `payment_attempt_id` |
| `Payment Status Checked` | The status screen re-polls | `payment_status_viewmodel.dart` | `trigger` (`auto` / `manual`), `attempt`, `payment_attempt_id` |
| **`Payment Confirmed Late`** | The entitlement lands *after* the paywall gave up. **Counting these separately is what turns "our checkout is unreliable" into "our webhook is slow"** | `payment_status_viewmodel.dart` | `attempts`, `trigger`, `seconds_since_checkout`, `payment_attempt_id` |
| `Payment Status Exhausted` | The status screen runs out of patience on a payment that may still be real. **These users are the most likely to pay twice or ask for a refund** | `payment_status_viewmodel.dart` | `attempts`, `seconds_since_checkout`, `payment_attempt_id` |
| `Retry Payment Tapped` | "Try again" / "Back to plans" on the status screen | `payment_status_view.dart` | `reason`, `payment_attempt_id` |
| `Entitlement Lapsed` | The gate throws a user out mid-use. **A user evicted mid-session converts very differently from one arriving at the paywall for the first time** — and the screen they were thrown out of is the interesting part | `entitlement_gate.dart` | `reason` (`session_lost` / `not_entitled`), `screen`, `previous_payment_type`, `billing_state` |
| `Billing Issue Shown` | The billing warning banner is displayed on Home — while there is still time to fix the mandate. Reported once per state change, not per rebuild | `home_view.dart` | `billing_state` |
| `Manage Billing Tapped` | The banner's action is tapped. **Only meaningful against `Billing Issue Shown` as its denominator** | `home_view.dart` | `billing_state` |

> **Revenue booking.** `trackCharge` is called from the client on `Payment Completed(success)` —
> **but only when the charge was the full plan price**. The trial's small authorisation is
> deliberately *not* booked: it is an authorisation rather than a subscription payment, and counting
> it would overstate LTV on every account that trials and churns. The amount is parsed out of the
> paywall's display string, which is copy rather than what Cashfree charged, so treat People revenue
> as indicative. **The authoritative amounts are the `amount` properties on the server's
> `Mandate Authorised` and `Subscription Renewed`.**

---

## 8. App events — location permission & tracking (8)

The permission this product cannot work without, and the only part of the funnel the app does not
control. All in [location_controller.dart](lib/data/location/location_controller.dart) except where
noted.

| Event | Fires when | Key properties |
|-------|-----------|----------------|
| `Location Permission Requested` | Just before the OS dialog | `previous_permission`, `trigger` (`foreground` / `background`) |
| `Location Permission Result` | The permission resolves — **the only step of this funnel the app does not control, and the one most likely to end the journey** | `result` (`notRequested` / `denied` / `deniedForever` / `whileInUse` / `always`), `previous_permission`, `trigger` (`foreground` / `background` / `app_settings`) |
| `Location Settings Opened` | The user is sent to the OS settings page | `permission` (as it was going in) |
| `Location Permission Skipped` | The priming screen is passed without granting. **A refusal must not trap the user, so this is a supported path — but it is a paying user whose product does not work** | `permission` |
| `Location Tracking Started` | The native tracker starts uploading | `permission`, `trigger` (`permission_granted` / `resumed_sharing`) |
| `Location Tracking Stopped` | Sharing stops | `reason` (`paused` / `sign_out` — **the credential is only cleared on sign-out, which is what separates a user who paused from one who left**) |
| `Location Tracking Failed` | A permission request or a start/stop threw | `error`, `trigger` (`request_permission` / `request_background_permission` / `stop_tracking`) |
| `Diagnostics Refreshed` | The hidden diagnostics screen re-reads native state. **Someone on this screen is troubleshooting — this is the most useful field report the app can produce without asking them to write one** | `permission`, `tracking_active` |

> `previous_permission` on the result is what makes a re-prompt that changed nothing distinguishable
> from a genuine grant. On Android 11+ the background request only *opens* Settings and answers with
> the pre-Settings status, so the result is read after a refresh — otherwise every upgrade to
> `always` would be reported as a refusal.

---

## 9. App events — home, people, invites & emergency (22)

### 9.1 Home & people (14)

| Event | Fires when | Where | Key properties |
|-------|-----------|-------|----------------|
| `Home Viewed` | Home paints, **after the first snapshot** so it can carry the counts that make it useful (the observer's `Screen Viewed` already covers the bare arrival) | `home_view.dart` | `people_count`, `requests_count`, `state` (`empty` / `list`), `tracking_active`, `permission` |
| `Add Person Sheet Opened` | The add-person sheet opens | `home_view.dart`, `emergency_view.dart` | `source` (`home` / `emergency`) |
| `Add Person Sheet Dismissed` | It closes with nothing entered | same | `source` |
| `Add Person Submitted` | A person is added | `home_view.dart` | `source`, `is_existing_user` (**true = already a Loc360 user and the two are connected instantly; false = an invite is needed and the journey has a long tail**) |
| `Add Person Failed` | The ViewModel refused — a duplicate, the three-person cap, or a failed call | `home_view.dart` | `source`, `message` |
| `Invite Dialog Shown` | The "they aren't on Loc360 yet — send an invite?" confirmation. **The share sheet is never opened unannounced: what it is about to do is message a third party** | `home_view.dart` | — |
| `Invite Dialog Dismissed` | "Not now". **Reaching the invite dialog and declining is a different outcome from never getting there — it is the step where an added person quietly fails to become a connection** | `home_view.dart` | `source` |
| `Person Action Tapped` | A card's action tile is used | `home_viewmodel.dart` | `action` (`beep` / `call` / `shareLive` / `shareCurrent`), `state` (the person's `ShareStatus`) |
| `Person Remove Requested` | Long-press opens the remove confirmation | `person_card.dart` | `state` |
| `Person Removed` | Removal confirmed | `person_card.dart` | `state` |
| `Person Remove Cancelled` | Removal declined | `person_card.dart` | `state` |
| `Request Accepted` | An incoming connection request is accepted | `home_viewmodel.dart` | — |
| `Request Declined` | …or declined | `home_viewmodel.dart` | — |
| `Tracking Banner Tapped` | The "location sharing is off" banner is acted on | `home_view.dart` | `permission` |

> Person cards report expand and collapse as **separate** `Element Tapped` ids
> (`person_card_expand` / `person_card_collapse`) rather than one toggle: how often a card is opened
> is a measure of the actions behind it being wanted, and folding the closes back in would halve it.

### 9.2 Invite screen (3)

The deeplink-only screen someone lands on when they follow an invite link.

| Event | Fires when | Where | Key properties |
|-------|-----------|-------|----------------|
| `Invite Phone Entered` | First keystroke (once per screen) | `invite_viewmodel.dart` | — |
| `Invite Sent` | An invite goes out | `invite_viewmodel.dart`, `home_view.dart` | `source` (`invite_screen` / `home`), `code` (**the code it was sent through, so an invite chain can be followed from the link that brought someone in to the invite they sent on**), `destination` |
| `Invite Failed` | The send threw | `invite_viewmodel.dart` | `error` |

### 9.3 Emergency & account (5)

| Event | Fires when | Where | Key properties |
|-------|-----------|-------|----------------|
| `Emergency Contact Added` | A contact is saved | `emergency_viewmodel.dart` | `count` (after) |
| `Emergency Contact Removed` | A contact is deleted | `emergency_viewmodel.dart` | `count` (after) |
| `Emergency Contact Called` | The dialer is handed the number | `emergency_viewmodel.dart` | — |
| `Terms Tapped` | The Terms of Service link is tapped. **Tracked even though the links go nowhere yet — how many people reach for the terms on the paywall is the argument for wiring them up, and it can only be made with numbers** | `terms_footer.dart` | `label` |
| `Privacy Tapped` | The Privacy Policy link is tapped | `terms_footer.dart` | `label` |

> Hitting the three-contact cap raises `Error Shown` with `source = add_emergency_contact`, not a
> dedicated event. **Users hitting a limit they did not know about is a product decision to revisit,
> not a failure to shrug at** — so it is worth a saved report on that one `source` value.

---

## 10. Server events (9)

Sent from Supabase Edge Functions when Cashfree reports a payment-lifecycle change, or when the
hourly reconcile sweep catches one that never arrived. **Never sent from the app.**

Every server event carries `source: "server"`, `server_function` (which Edge Function raised it:
`cashfree-webhook`, `subscription-reconcile`, `subscription-start`, `subscription-status`,
`subscription-cancel`), and `$ip: "0"` so Mixpanel does not overwrite the user's real city with a
Supabase data centre. An event that names nothing we own gets `distinct_id = unattributed:<insert_id>`
rather than being dropped — **knowing how many webhooks arrive for subscriptions we cannot attribute
is itself worth knowing.**

| Event | Fires when | Dedupe key (`$insert_id`) | Key properties |
|-------|-----------|---------------------------|----------------|
| **`Mandate Authorised`** | A successful **AUTH** charge — the first trial fee, or a returning subscriber's full first month | `pay:{cf_payment_id}:{status}` | `amount`, `currency`, `kind`, `cf_payment_id`, `subscription_id`, `payment_status`, `already_credited`, `cf_event_type`, `trigger` |
| **`Subscription Renewed`** | A successful **RECURRING** monthly debit | `pay:{cf_payment_id}:{status}` | same as above |
| **`Subscription Payment Failed`** | A charge attempt is declined. **The single most actionable event this system produces — the moment a paying customer starts silently churning** | `pay:{cf_payment_id}:{status}` | `failure_reason`, `amount`, `kind`, `cf_event_type`, … |
| `Subscription Payment Pending` | A charge is neither successful nor failed yet | `pay:{cf_payment_id}:{status}` | same |
| `Subscription Status Changed` | Cashfree's mandate status differs from ours (e.g. `ACTIVE → ON_HOLD`) | `sub:{id}:{from}:{to}:{minute}` — **bucketed to the minute so a burst of webhook retries collapses into one event** | `from_status`, `to_status`, `transition` (pre-computed name), `billing_state`, `payment_type`, `recurring_amount`, `next_billing_at`, `authorized_at` |
| **`Subscription Cancelled`** | The mandate ends, from any of four places: Cashfree webhook, reconcile sweep, in-app cancel endpoint, or the stale/duplicate-mandate cleanup | `cancel:{subscription_id}` — no time bucket, because **a subscription is cancelled exactly once** | `cancelled_by`, `cf_status`, `from_status`, `reason`, `was_in_trial`, `entitled_until`, `recurring_amount`, `days_subscribed` |
| `Refund Recorded` | Cashfree reports a refund | `refund:{cf_refund_id}:{status}` | `amount`, `currency`, `refund_status`, `refund_reason`, `attributed` (**false = we cannot tie it to a subscription, which usually means the charge it reverses was never recorded either**) |
| `Dispute Recorded` | Cashfree reports a chargeback/dispute | `dispute:{cf_dispute_id}:{status}` | `amount`, `dispute_status`, `dispute_type`, `dispute_reason`, `respond_by`, `lost`, `attributed` |
| `Webhook Received` | **Every** delivery to the webhook endpoint, exactly once per delivery, whatever happens to it | `wh:{key}:{outcome}` where `key` hashes type + timestamp + body | `outcome`, `cf_event_type`, `signature_ok`, `skew_seconds`, `subscription_id`, `cf_subscription_id`, `header_timestamp`, `body_bytes`, plus per-outcome extras |

**`Webhook Received` outcomes:** `handled`, `duplicate`, `ignored`, `unknown_subscription`,
`signature_rejected`, `not_configured`, `record_failed`, `unrecoverable`, `failed`.

> The outcome is deliberately part of the dedupe key. A redelivery of the same notification is
> reported *again* under `duplicate` — same delivery, different thing happening to it — and
> collapsing the two onto one id would hide the redelivery entirely. `not_configured` is the one to
> alert on: a rotated-away webhook secret stops the only path by which an account becomes paid, and
> used to do it in total silence.

> **⚠️ The distinction that matters most:** `Payment Completed` (app, `outcome = success`) is the app
> *believing* a payment landed. `Mandate Authorised` and `Subscription Renewed` (server) are Cashfree
> confirming money actually moved. **Use the server events for anything revenue-shaped.**

> **Deduplication is load-bearing.** Cashfree redelivers webhooks freely and the reconcile sweep
> replays history hourly. Every `$insert_id` is keyed on the *occurrence* (the charge, the
> cancellation), never on the delivery attempt. Without it, one renewal would be counted every hour
> for a month.

**Server-side People writes** (`$set`, never `$set_once`, and never on an unknown id — see [§12](#12-identity-management)):
on a successful charge (`payment_type`, `current_period_end`, `entitled`, `in_trial`,
`has_ever_subscribed`, `last_payment_at`, `last_payment_status`); on a status change
(`subscription_status`, `billing_state`, `next_billing_at`, `payment_type`, and `cancelled_at` /
`cancelled_by` when it is a cancellation); on a dispute (`billing_state`).

---

## 11. Facebook Ads conversions

Only **4** of the 99 app events are forwarded to Meta, chosen to give the ad optimiser a funnel it can
train on before there are enough weekly purchases to optimise for purchases directly.

| Circle360 event | Facebook event | Value |
|-----------------|----------------|-------|
| `Signup Completed` | `CompletedRegistration` (`phone_otp`) | — |
| `Subscribe Tapped` | `InitiatedCheckout` | Amount for `offer_type`, from `app_config` |
| `Payment Completed` (only when `outcome = success`) | `Purchase` + `StartTrial` | Amount for `offer_type` |
| `Payment Confirmed Late` | `Purchase` + `StartTrial` | Amount for `offer_type` |

Facebook takes its amounts from `app_config`, never from a paywall label. An `offer_type` that is
anything but `plan` — including a missing one — is priced as the trial, so a malformed event
under-reports rather than inflating ROAS.

**The purchase guard is a flag on disk** (`loc360.fb_purchase_reported`), written *before* the SDK
call and never cleared, not even on sign-out. One install reports at most one purchase, ever. A flag
in memory would not hold: the app is routinely killed during the UPI hand-off, so a second attempt is
usually a fresh process, and the server's "already entitled" branch can answer with a success that
charged nothing. Over-reporting teaches the optimiser to buy the wrong people; a lost conversion
after a reinstall costs one row.

**iOS needs ATT.** Without authorisation iOS hands out no IDFA and the conversions arrive
unattributed — they still land, the optimiser just learns nothing from them. The prompt is shown when
the **paywall** opens (or on Home for an already-entitled user), deliberately not at launch: the app's
first screens already ask for location, and the paywall placement is still *before* the purchase, so
a granted IDFA is attached to the conversion rather than arriving a screen too late. Watch
`Tracking Consent Resolved` with `prompted = true` for the real opt-in rate.

---

## 12. Identity management

| Action | When | Behaviour |
|--------|------|-----------|
| **Identify** | Signup, login, app resume while signed in, every entitlement re-resolve | `identify(user.user_id)` + People profile write. **Skipped when nothing changed** — the entitlement gate re-resolves on every resume and on a six-hourly timer, so this runs far more often than the account actually changes. Only `last_seen` is written on a no-op. The comparison is on the *properties*, not the id — the id is exactly what does not change when a trial converts to a paid month |
| **Reset** | Sign-out only (Profile or Settings) | Mints a new anonymous id and **drops the identity super properties**, so the next user of the handset does not inherit the last one's account. Environment-level super properties are re-registered afterwards, because `reset` clears those too |
| **Server identify** | Every payment/status webhook | Same `distinct_id` = `users.user_id`, so a 3am renewal lands on the same profile as the `Subscribe Tapped` that started it |

**Sign-out order (all three steps matter):** `track("Signed Out")` → stop the native tracker and clear
its credential → `signOut()` → `analytics.reset()`. The event goes first or it is attributed to the
anonymous identity that replaces the user rather than to the user who actually left. The tracker is
stopped before the session is dropped, or the previous user keeps broadcasting from a handset they
have already handed back.

---

## 13. People profile properties

| Property | Set by | Notes |
|----------|--------|-------|
| `$name` | App | |
| `$phone` | App | The real number, in E.164 (`+91…`). Support needs to find an account from a call, and it is already the login identifier |
| `$created` | App | `setOnce` |
| `payment_type` | App + server | `trial` / `active` / `expired` / `cancelled` |
| `entitled`, `in_trial`, `has_ever_subscribed` | App + server | |
| `billing_state` | App + server | `onHold` / `paused` / `dunning` / `disputed` |
| `subscription_status` | Server | Cashfree's own status |
| `trial_ends_at` | App | |
| `current_period_end` | App + server | |
| `next_billing_at` | Server | |
| `last_payment_at`, `last_payment_status` | Server | |
| `cancelled_at`, `cancelled_by` | Server | |
| `last_seen` | App | Written on every resume — and excluded from the "has anything changed?" comparison, or that check would never be equal and the whole dedupe would be pointless |

The server never *creates* a profile for someone who has not used the app — `identify()` from the
client owns profile creation, and a server `$set` on an unknown id would mint a bare profile with no
name, phone or device.

---

## 14. Data we intentionally do NOT collect

- **Location coordinates** — no event carries a latitude, longitude or address. The map's own state
  never reaches Mixpanel; only permission state, whether tracking is live, and how many people are on
  it
- **The user's name** — only `name_length`
- **The names and numbers of people in the circle** — only counts, `ShareStatus`, and which action was
  used
- **OTP values**
- **Phone numbers in events** — the number appears only as `$phone` on the People profile
- Device/OS/geo fields the SDK already attaches (never duplicated under a second name)

**Two deliberate exceptions, worth knowing about:** `Deep Link Opened` carries `inviter_name` and
`code`, and `Invite Sent` carries `code`. The code is what makes an invite chain followable — from
the link that brought someone in to the invite they sent on — and it is the one join that cannot be
reconstructed from anything else. `inviter_name` is a real person's display name taken from the
invite URL; if a review ever tightens what leaves the device, that is the first field to drop.

---

## 15. Naming conventions

- **Events:** Title Case, past tense — `Payment Completed`, not `complete_payment`
- **Properties:** `snake_case`
- **Property values:** lowercase where they are enums — `phonepe`, `trial`, `paused`. Dart enum names
  reach Mixpanel as-is, so a few are `camelCase` by inheritance (`whileInUse`, `deniedForever`,
  `shareLive`, `onHold`) — expected, not a bug, but do not "fix" one in isolation or the column forks
- **Nulls are stripped** before sending, on both the app and the server — Mixpanel stores an explicit
  null as a real value and it dirties every breakdown
- **New events must be added as a constant** in `analytics_events.dart`, never as a string literal
- **New modals must pass `RouteSettings(name: …)`** and be added to `_modalNames`, or they arrive as
  `Unnamed <RouteType>`

---

## 16. Verification checklist

1. **Live View** — run a debug build through each flow and confirm events and properties arrive.
   Filter `build_mode = debug` to isolate yourself
2. **Filter production reports on `build_mode = release` and `backend_mode = supabase`** — otherwise
   developer traffic and fake-backend subscriptions land in your funnels
3. **Identity** — signup and login land on the same profile; sign-out starts a fresh anonymous
   session; `install_id` stays constant across both
4. **App vs server** — `Payment Completed` only from the app, `Mandate Authorised` /
   `Subscription Renewed` only from the server. Use the server pair for revenue
5. **Dedupe** — redeliver a Cashfree webhook and confirm the renewal count does not move, and that a
   `Webhook Received` with `outcome = duplicate` *does* appear
6. **Permission funnel** — grant, deny, and deny-forever all produce a `Location Permission Result`
   with the right `result` and `trigger`; the Settings round trip produces one with
   `trigger = app_settings`
7. **Lexicon** — add descriptions for all 108 live events in Mixpanel Data Management
8. **Funnels** — build the six funnels in [§4](#4-core-funnels)

---

## 17. Event count summary

| Category | Live events |
|----------|-------------|
| Lifecycle & sessions | 7 |
| Navigation & infrastructure | 6 |
| Onboarding & sign-out | 18 |
| Paywall & payment | 36 |
| Location permission & tracking | 8 |
| Home & people | 14 |
| Invite | 3 |
| Emergency & account | 5 |
| Ad attribution & splash | 2 |
| **App subtotal** | **99** |
| Server / webhook | 9 |
| **Total live** | **108** |
| Declared but not emitted | **0** |
