# `supabase/functions/` — Edge Functions (Deno)

**Schema, the security model and deploy steps are in [../README.md](../README.md).** Read that
first; this file is only the per-function index.

The one-line version: the app verifies phones with Fast2SMS, not Supabase Auth, so there is no
`auth.uid()` to write RLS against. `users`, `user_sessions` and `otp_throttle` have **RLS on with
no policies** — the anon key can do nothing. Everything goes through a function holding the
service_role key.

> **The payment logic is not in the `index.ts` handlers.** It is in `_shared/subscription_sync.ts`
> (990 lines) and `_shared/cashfree.ts` (727). The handlers are thin.

## Handlers

| Function | What it does |
|---|---|
| `send-otp` | Sends a code. The review-account check runs *before* the dev bypass, and its response is byte-for-byte a normal success — probing must not reveal which number is the review account. |
| `resend-otp` | Resend, sharing `send-otp`'s quota and bypass rules. |
| `verify-otp` | **The one place a `users` row is created.** Verification hits Fast2SMS first, so a row can only exist for a number whose owner received the code. Also stamps `signup_app` — which of the two apps in the build the account was created in — on **insert only**, which is why it asks whether the row exists first. That extra query runs for SunioMax sign-ins alone, so the Circle360 path is unchanged. |
| `me` | Resolves a stored token back to its user, so a relaunch restores the session — and so a revoked token is actually rejected rather than trusted from the device's cache. |
| `update-profile` | Sets the name from the post-OTP step. The user id comes from the token, never the body, or anyone could rename any account by guessing a uuid. |
| `people` | The single read Home makes, polled every 10s: connected people with positions, not-yet-accepted people, unclaimed invites, and inbound requests, all in one call. |
| `add-person` | Connect to a number, or invite it. **The consent rule lives here and nowhere else:** adding someone starts YOUR location flowing to them immediately (you agreed by adding them) and leaves THEIRS pending. |
| `respond-request` | Answer a request, or end a connection. `accept` only ever flips the caller's own outbound row — no request shape lets one account turn on another's sharing. |
| `ingest-location` | Where every position lands. Called from Kotlin/Swift every 10s per device, so it stays thin: authenticate, check entitlement, upsert one row. |
| `subscription-start` | Opens a Cashfree UPI Autopay mandate, in one of two shapes. |
| `subscription-status` | Re-reads from Cashfree. Two jobs: what the app polls after checkout (the SDK callback proves only that the sheet closed, not that money moved), and the self-heal for a missed webhook. |
| `subscription-cancel` | Cancels the mandate. Access is deliberately **not** revoked — `current_period_end` is left alone so the user keeps the month they paid for. |
| `cashfree-webhook` | The only path by which an account becomes paid, so also the only one worth attacking. Three rules hold it together — read the header. |
| `subscription-reconcile` | The safety net under the webhook. Scheduled hourly via `pg_cron`; the exact statement is in the header. |

## `_shared/`

| File | What it does |
|---|---|
| `subscription_sync.ts` | Reconciles one subscription against Cashfree and writes to `subscriptions` + `users`. **Every state transition goes through here.** Enforces: Cashfree is the authority. 990 lines. |
| `cashfree.ts` | The Subscriptions API, with the client secret server-side. The secret both authenticates calls and signs webhooks. 727 lines. |
| `entitlement.ts` | **The single place "is this account allowed in" is decided.** `me`, `subscription-status`, `subscription-start` and the webhook all call it — split it and the paywall and the billing sweep will eventually disagree. |
| `sharing.ts` | The shape Home renders, and the queries that build it. Shared by `people` and `add-person` so a freshly added person is byte-identical to the same person on the next poll. |
| `mixpanel.ts` | Server-side events, for the half of the lifecycle the app never sees — a recurring debit happens on Cashfree's schedule, weeks after anyone opened the app. |
| `fast2sms.ts` | OTP endpoints, API key server-side. This is the whole point of proxying OTP through functions. |
| `config.ts` | Runtime config from `app_config` **including private rows**, read with the service-role client. Never return this map to a caller — it holds the Fast2SMS credentials. |
| `db.ts` | The service-role client. The only thing that can touch `users` / `user_sessions` / `otp_throttle`. |
| `cors.ts` | Preflight plus the error shape the Flutter client maps onto its exception types — stable `code`, user-safe `message`. |
| `review_account.ts` | One fixed-code sign-in for Play/App Store reviewers, who cannot receive an Indian SMS. Deliberately **not** `devOtpEnabled`, which accepts a fixed code for every number. |
| `dev_otp.ts` | Development stand-in for Fast2SMS. Two independent conditions must hold, so it cannot switch itself on in production. |

## Tests

`deno test --allow-env supabase/functions/tests/`

- `payments_test.ts` (706) — the payment logic with no DB or network in it. An entitlement rule
  off by an hour locks out paying customers; a subtly wrong signature check lets anyone in.
- `mixpanel_test.ts` (231) — swaps `fetch` for a recorder.
- `review_account_test.ts` (97) — pins down when the fixed credential is *off*.
