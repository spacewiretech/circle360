# Loc360 backend

Schema and Edge Functions for project `symwrytqyhyxlcjaubru`.

## Security model in one paragraph

The app verifies phone numbers with Fast2SMS, not Supabase Auth, so there is no `auth.uid()`
to write RLS policies against. The anon key ships inside the app and is extractable, so any
policy permissive enough to let the app write its own row would also let anyone dump every
phone number in `users`. Instead **`users`, `user_sessions` and `otp_throttle` have RLS on with
no policies at all** — the anon key can do nothing with them. Every read and write goes through
an Edge Function using the service_role key, which bypasses RLS. The only thing the anon key
can read is `app_config` rows flagged `is_public`.

That also keeps the Fast2SMS credentials off the device: they live in **private** `app_config`
rows that only the functions can read.

## Deploy

```bash
supabase login
supabase link --project-ref symwrytqyhyxlcjaubru

# 1. Schema
supabase db push

# 2. Fast2SMS credentials go in app_config as PRIVATE rows — see below, no secrets needed.

# 3. Functions
supabase functions deploy send-otp resend-otp verify-otp me update-profile \
  subscription-start subscription-status subscription-cancel \
  cashfree-webhook subscription-reconcile \
  people add-person respond-request ingest-location
```

`fast2sms_otp_id` is an **OTP Template ID created in the Fast2SMS dashboard**. It is not the
DLT Sender ID, PE ID or TE ID — those are bound to the template inside the dashboard and are
not request parameters on the OTP route. Without it, `/dev/otp/send` returns `Invalid OTP ID`.

`SUPABASE_URL` and `SUPABASE_SERVICE_ROLE_KEY` are injected into every function automatically,
so those are the only environment variables the functions rely on.

### Credentials live in `app_config`, not in secrets

The functions read Fast2SMS credentials from **private `app_config` rows** via service_role, so
no `supabase secrets set` is needed. Set these in the dashboard:

| key | value | is_public |
|---|---|---|
| `fast2sms_api_key` | your Dev API key | **false** |
| `fast2sms_otp_id` | OTP Template ID, or blank | **false** |
| `allow_dev_otp` | `true` while there is no template | **false** |

`is_public` **must** be false. The anon key that reads public rows ships inside the app, so a
public credential is a published credential. A CHECK constraint now refuses to mark any key
matching `^fast2sms`, `_key`, `_secret`, `_token`, `password` or `credential` as public, so
this cannot be done by accident.

Values are cached in each function instance for 60s, so a dashboard edit takes effect within a
minute without redeploying. Placeholder text (`-`, `n/a`, `none`, `tbd`, …) counts as unset, so
a `-` in `fast2sms_otp_id` correctly reads as "no template" rather than being sent to Fast2SMS.

## Cashfree subscriptions

₹3 authorises a UPI Autopay mandate and opens a 2-day trial; ₹499 is auto-debited on day 2 and
monthly thereafter. Nothing about that is decided on the device — the app sends no amounts, no
plan id and no status, only its session token.

### 1. Credentials and knobs — private `app_config` rows

| key | value | is_public |
|---|---|---|
| `cashfree_app_id` | `x-client-id` from the Cashfree dashboard | **false** |
| `cashfree_secret_key` | `x-client-secret` — **also the webhook HMAC key** | **false** |
| `cashfree_env` | `production` or `sandbox` | false |
| `cashfree_api_version` | `2025-01-01` | false |
| `cashfree_plan_id` | `id_circle360_499` | false |
| `cashfree_trial_amount` | `3` | false |
| `cashfree_recurring_amount` | `499` | false |
| `cashfree_trial_days` | `2` | **true** (the paywall quotes it) |
| `entitlement_grace_hours` | `12` | false |
| `reconcile_secret` | `select encode(gen_random_bytes(32), 'hex')` | **false** |
| `trial_price_label` / `plan_price_label` | `₹3` / `₹499` | true |

While `cashfree_secret_key` is empty every payment function fails closed — `subscription-start`
returns 503 and the webhook refuses to process anything. That is deliberate: a webhook that
cannot be verified must never be believed.

The plan named by `cashfree_plan_id` must already exist in the Cashfree dashboard as a
**PERIODIC / MONTH / ₹499** plan, with UPI Autopay enabled on the account.

### 2. Webhook

Register `https://symwrytqyhyxlcjaubru.supabase.co/functions/v1/cashfree-webhook` in the
Cashfree dashboard, subscribed to all `SUBSCRIPTION_*` events. Confirm it is reachable without
a Supabase apikey header — Cashfree cannot send one:

```bash
curl -i -X POST https://symwrytqyhyxlcjaubru.supabase.co/functions/v1/cashfree-webhook -d '{}'
# want: 401 invalid signature   (the function ran and rejected it)
# not:  401 Missing authorization header   (the gateway blocked it — check verify_jwt)
```

### 3. Reconcile sweep

Webhooks get lost. Without this, a user whose ₹499 was debited during an outage would sit in
`trial` until it expired and then be asked to pay again.

```sql
select cron.schedule('reconcile-subscriptions', '0 * * * *', $$
  select net.http_post(
    url     := 'https://symwrytqyhyxlcjaubru.supabase.co/functions/v1/subscription-reconcile',
    headers := '{"x-reconcile-secret":"<app_config.reconcile_secret>"}'::jsonb
  ) $$);
```

### How entitlement is decided

One function, `_shared/entitlement.ts`, and nothing else:

```
active    -> current_period_end is null OR now < current_period_end + grace
trial     -> trial_ends_at is not null AND now < trial_ends_at + grace
cancelled -> now < current_period_end          (no grace: nothing is in flight)
expired   -> false
```

It is derived, never stored, so a stalled webhook expires an account by the clock rather than
leaving it entitled forever — and a failed renewal needs no code of its own, it is just a
`current_period_end` that stops moving forward.

`trial_ends_at` is null for every new signup. That is what puts a fresh account on the paywall:
the row exists from the moment the OTP is verified, but the trial clock only starts when
Cashfree captures the ₹3.

### Why the webhook re-fetches instead of reading the payload

Payload shapes differ per event type and per API version. The webhook verifies the signature,
records the delivery under a unique dedupe key, and then asks Cashfree what the subscription
looks like *now* — writing that. Duplicate and out-of-order deliveries therefore converge on
the same answer without any special handling, and a delivery that never arrives is repaired by
the next status poll or the nightly sweep.

Signature: `base64(HMAC-SHA256(x-webhook-timestamp + rawBody, cashfree_secret_key))`, over the
raw bytes. Re-serialising the parsed JSON reorders keys and the signature silently stops
matching.

### Tests

```bash
deno test supabase/functions/tests/payments_test.ts
```

Covers the entitlement rules at their boundaries, signature verification against tampering and
replay, the payload shapes, and the IST/month-end date arithmetic.

### No OTP template yet

Leave `fast2sms_otp_id` blank and set `allow_dev_otp` to `true`, then:

```bash
supabase functions deploy send-otp resend-otp verify-otp me update-profile \
  subscription-start subscription-status subscription-cancel \
  cashfree-webhook subscription-reconcile
```

`send-otp` then sends no SMS, and `verify-otp` accepts **`000000`** for any number — but
everything past that check is the real path, so you get a genuine `users` row and session
token and can exercise the whole flow including the name step.

It is gated on two independent conditions: `fast2sms_otp_id` unset **and** `allow_dev_otp`
explicitly `true`. Gating on the missing template alone would mean a deployment that lost its
credentials silently started accepting a fixed code for every number. Adding the template
disables the bypass on its own — there is no flag to remember to unset — and every request it
handles logs a warning.

## Functions

| Function | Auth | Does |
|---|---|---|
| `send-otp` | anon | quota check → Fast2SMS send |
| `resend-otp` | anon | quota check → Fast2SMS resend, reissuing a new code once the 10-minute window closes |
| `verify-otp` | anon | Fast2SMS verify → upsert `users` row → issue a session token |
| `me` | bearer | resolve token → user + entitlement; `DELETE` signs out |
| `update-profile` | bearer | set `name` on the caller's own row |
| `subscription-start` | bearer | open a Cashfree mandate, return the checkout session |
| `subscription-status` | bearer | reconcile against Cashfree, return entitlement |
| `subscription-cancel` | bearer | stop future debits, keep the paid period |
| `cashfree-webhook` | **HMAC signature** | Cashfree's notifications; the only path to `active` |
| `subscription-reconcile` | `x-reconcile-secret` | hourly sweep for lost webhooks |

Errors come back as `{"error": {"code", "message"}}`. `code` is one of `invalid_request`,
`invalid_otp`, `otp_expired`, `throttled`, `unauthorized`, `send_failed`, `server_error`,
`payment_failed`, `already_subscribed`; the Flutter client maps those onto its existing
exception types. `message` is always safe to show — the real cause of an account or credential
failure only ever reaches the function logs.

The user object returned by `verify-otp`, `update-profile`, `me`, `subscription-status` and
`subscription-cancel` is identical: `user_id`, `mobile_no`, `name`, `payment_type`,
`trial_ends_at`, `current_period_end`, `entitled`, `in_trial`.

## Session tokens

`verify-otp` returns a 256-bit random token, stored **hashed** in `user_sessions` so a table
dump cannot be replayed. The app keeps it in the Keychain/Keystore. If you later want the
client querying PostgREST directly under RLS, swap this for a JWT signed with the project JWT
secret carrying `sub = user_id`; the policies then become the usual `auth.uid() = user_id`.

## Operational notes

- **Throttling.** `consume_otp_quota` caps sends at 10 per number per hour, counted in a single
  upsert so concurrent requests cannot both slip past. Without it, anyone holding the anon key
  could drain the Fast2SMS wallet.
- **Housekeeping.** `user_sessions` and `otp_throttle` grow without bound. Once live:
  ```sql
  select cron.schedule('purge-expired', '0 3 * * *', 'select public.purge_expired()');
  ```
- **Scale.** `mobile_no` is the unique index every login hits; `payment_type` and
  `creation_time` are indexed for billing sweeps. `gen_random_uuid()` is fine into the tens of
  millions of rows — if write rates ever make index locality a problem, move the primary key to
  a time-ordered UUIDv7.
- **`app_config`.** Add config with `is_public = true`; anything sensitive must be left
  `false`, where only functions can read it.
- **Payment tables.** `subscriptions`, `subscription_payments` and `payment_events` are all
  RLS-on with zero policies, like `users`. `subscription_payments` is unique on `cf_payment_id`
  and `payment_events` on `dedupe_key`, which is what makes webhook redelivery a no-op rather
  than a second charge being credited.
- **One live mandate per user.** Enforced by a partial unique index on
  `subscriptions (user_id) where status = 'ACTIVE'`. `subscription-start` cancels a stale live
  mandate before creating its replacement, so the index is a backstop rather than the mechanism.
- **Auditing a disputed charge.** `subscriptions.raw` holds the last full Cashfree snapshot and
  `payment_events.payload` every raw delivery, so what the gateway actually said is recoverable
  months later.

## Location sharing

Four functions and three tables. No Realtime and no push: the app authenticates with its own
opaque session token rather than a Supabase JWT, so there is no `auth.uid()` for Realtime's RLS
to key off. Home polls `people` every 10s instead, which matches the tracking cadence exactly —
a shorter interval could not surface anything newer.

### The consent rule

Adding someone creates **two** rows in `location_shares`, and the asymmetry is the entire
point:

```
A adds B  ->  (sharer A, viewer B, active)    A consented by adding; A's location flows now
              (sharer B, viewer A, pending)   B has agreed to nothing; waits for B to accept
```

So a person's position is only ever exposed by their own action. `accept` in `respond-request`
is scoped to `sharer_id = <caller>`, which means no request shape exists that could turn on
somebody else's sharing. `decline` deletes **both** rows — refusing a connection must also stop
the inbound half, or you would keep receiving the location of someone you just said no to.

### Invites, without a webhook

A number with no account gets a `pending_invites` row. When that number verifies an OTP,
`verify-otp` calls `claim_pending_invites(user_id, mobile)`, which converts every open invite
into the same two rows — inside the same request that creates the user, so a half-linked state
is not reachable. The invite **link** is attribution only; the connection is made by the number
match, so it still forms if the invitee ignores the link and installs from the store.

### Ingest

`ingest-location` is called from Kotlin/Swift every 10 seconds per device, long after the
Flutter engine is gone. Its two failure codes are the only way that uploader ever learns to
stop:

| status | meaning | native does |
|---|---|---|
| `401 unauthorized` | session revoked or signed out elsewhere | clears its token, stops the service |
| `403 not_entitled`  | subscription lapsed | clears its token, stops the service |

Without them a signed-out or unpaid handset would broadcast its position indefinitely. The
credential reaches native only through `configureUpload` on the `loc360/location` channel —
Dart pushes it at sign-in, because the service cannot call back for one.

`user_locations` keeps the latest fix only, upserted. `updated_at` is the **server** clock and
is what every freshness decision reads; `fixed_at` is the device's own and is diagnostics only,
because a wrong or tampered device clock must not be able to make a stale position look live.

## Verifying RLS actually holds

After `db push`, this must return zero rows — that is the check that the phone numbers are
protected, not just assumed to be:

```bash
curl "https://symwrytqyhyxlcjaubru.supabase.co/rest/v1/users?select=mobile_no" \
  -H "apikey: <anon key>" -H "Authorization: Bearer <anon key>"
```

The same must hold for the sharing tables — a leak here is a live location, not just a number:

```bash
for t in location_shares pending_invites user_locations; do
  curl -s "https://symwrytqyhyxlcjaubru.supabase.co/rest/v1/$t?select=*" \
    -H "apikey: <anon key>" -H "Authorization: Bearer <anon key>"; echo " <- $t"
done
# want: [] for all three
```
