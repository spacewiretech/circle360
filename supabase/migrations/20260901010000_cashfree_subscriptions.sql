-- Cashfree UPI Autopay: ₹3 authorisation opens a 2-day trial, then ₹499/month recurs.
--
-- Security model is unchanged from the init migration: every table here is RLS-on with zero
-- policies, so the anon key that ships inside the app cannot read or write any of it. Only the
-- Edge Functions, holding service_role, touch these rows — which is the whole point, because
-- a client that can write `payment_type` is a client that never has to pay.
--
-- Entitlement is deliberately NOT stored as a boolean. It is derived from `payment_type` plus
-- two timestamps, so a stalled webhook expires an account by the clock rather than leaving it
-- entitled forever, and so a successful renewal is just a date moving forward.

-- ---------------------------------------------------------------- users

alter table public.users
  -- Null means "the trial has not started". A brand new row is `trial` with a null date, which
  -- reads as NOT entitled — the clock only starts once Cashfree captures the ₹3.
  add column if not exists trial_ends_at          timestamptz,

  -- Set from the last successful recurring debit. When a renewal fails this simply stops
  -- moving, and the account lapses on its own. No failure branch has to remember to do it.
  add column if not exists current_period_end     timestamptz,

  -- Denormalised pointer to the live mandate, so `me` stays a single-row read on the hot path.
  add column if not exists active_subscription_id text;

comment on column public.users.trial_ends_at is
  'Null until Cashfree captures the authorisation amount. Set to authorization_time + trial days.';
comment on column public.users.current_period_end is
  'End of the paid period from the last successful recurring debit.';

-- The reconcile sweep looks for trials that should have converted by now.
create index if not exists users_trial_ends_at_idx
  on public.users (trial_ends_at)
  where payment_type = 'trial';

-- ---------------------------------------------------------------- subscriptions

-- One row per mandate attempt, including the ones the user abandoned at the UPI sheet.
-- Keeping the failures is what makes "why did this user never get charged" answerable.
create table if not exists public.subscriptions (
  id                      uuid primary key default gen_random_uuid(),
  user_id                 uuid not null references public.users(user_id) on delete cascade,

  -- Ours, sent to Cashfree as `subscription_id`. Also used as the idempotency key on create.
  subscription_id         text not null unique,
  -- Cashfree's own reference, returned by the create call.
  cf_subscription_id      text unique,

  plan_id                 text not null,

  -- Free text on purpose. A CHECK here would make an unrecognised Cashfree status fail the
  -- webhook closed, which is exactly backwards: an unknown status must still be recorded so it
  -- can be seen, not rejected. Known values: INITIALIZED, PENDING_AUTHORIZATION, ACTIVE,
  -- ON_HOLD, PAUSED, CANCELLED, COMPLETED, plus the local-only ABANDONED and FAILED_TO_CREATE.
  status                  text not null default 'INITIALIZED',

  -- The checkout token handed to the SDK, and when it stops working. Short-lived and already
  -- visible to the client, so there is nothing to protect here — it is stored so a double-tap
  -- or a backgrounded checkout can resume instead of minting a second mandate.
  session_id              text,
  session_expiry          timestamptz,

  authorization_amount    numeric(10,2),
  recurring_amount        numeric(10,2),

  first_charge_time       timestamptz,
  next_schedule_date      timestamptz,
  authorized_at           timestamptz,
  cancelled_at            timestamptz,

  last_payment_at         timestamptz,
  last_payment_status     text,
  failure_reason          text,

  -- The last full snapshot fetched from Cashfree. Cheap insurance: when a payment is disputed
  -- months later, this is the only record of what the gateway actually said at the time.
  raw                     jsonb,

  created_at              timestamptz not null default now(),
  updated_at              timestamptz not null default now()
);

-- The invariant that stops double billing. A user may accumulate any number of abandoned or
-- cancelled mandates, but never two live ones — so a retry can never leave two UPI mandates
-- debiting ₹499 in parallel.
create unique index if not exists subscriptions_one_active_per_user
  on public.subscriptions (user_id)
  where status = 'ACTIVE';

create index if not exists subscriptions_user_created_idx
  on public.subscriptions (user_id, created_at desc);

-- Driven by the nightly reconcile, which looks for schedules that should have fired.
create index if not exists subscriptions_next_schedule_idx
  on public.subscriptions (next_schedule_date)
  where status in ('ACTIVE', 'ON_HOLD', 'PENDING_AUTHORIZATION');

alter table public.subscriptions enable row level security;

create trigger subscriptions_touch_updated_at
  before update on public.subscriptions
  for each row execute function public.touch_updated_at();

comment on table public.subscriptions is
  'One row per Cashfree mandate attempt. Written only by Edge Functions (service_role).';

-- ---------------------------------------------------------------- payments

-- One row per charge attempt, authorisation and recurring alike.
create table if not exists public.subscription_payments (
  id              uuid primary key default gen_random_uuid(),
  subscription_pk uuid references public.subscriptions(id) on delete cascade,
  user_id         uuid references public.users(user_id) on delete cascade,

  -- The real idempotency guard for money. A webhook redelivered three times upserts one row.
  cf_payment_id   text not null unique,

  -- AUTH is the ₹3 that opens the trial; RECURRING is each ₹499 debit.
  kind            text not null default 'RECURRING',

  amount          numeric(10,2),
  currency        text not null default 'INR',
  status          text not null,
  payment_time    timestamptz,
  failure_reason  text,
  raw             jsonb,

  created_at      timestamptz not null default now()
);

create index if not exists subscription_payments_user_idx
  on public.subscription_payments (user_id, payment_time desc);

alter table public.subscription_payments enable row level security;

comment on table public.subscription_payments is
  'Ledger of Cashfree charge attempts, unique on cf_payment_id so redelivery cannot double-count.';

-- ---------------------------------------------------------------- webhook audit

-- Every delivery lands here before anything is acted on, verified or not. A forged call that
-- fails the signature check is still worth having a record of.
create table if not exists public.payment_events (
  id                 bigserial primary key,
  event_type         text,

  -- sha256(event_type | x-webhook-timestamp | raw body). The unique constraint is what makes a
  -- redelivered webhook a no-op rather than a second state transition.
  dedupe_key         text not null unique,

  signature_ok       boolean not null default false,
  header_timestamp   text,
  -- Recorded, never enforced: Cashfree retries may carry the original timestamp, so rejecting
  -- on skew would drop legitimate retries. Replay is already neutralised by dedupe_key and by
  -- the unique cf_payment_id, so a replayed event can only re-assert state we already hold.
  skew_seconds       integer,

  cf_subscription_id text,
  subscription_id    text,
  payload            jsonb,

  received_at        timestamptz not null default now(),
  processed_at       timestamptz,
  process_error      text
);

create index if not exists payment_events_subscription_idx
  on public.payment_events (subscription_id, received_at desc);

create index if not exists payment_events_unprocessed_idx
  on public.payment_events (received_at)
  where processed_at is null;

alter table public.payment_events enable row level security;

comment on table public.payment_events is
  'Raw Cashfree webhook deliveries. Unique dedupe_key makes redelivery idempotent.';

-- ---------------------------------------------------------------- config

-- Every amount, plan id and credential the payment functions need. All private: the CHECK
-- constraint from the previous migration already forces `_key$`/`_secret$` names to
-- is_public = false, and the rest are private simply because a device has no use for them.
--
-- Values are seeded empty where they are secrets, so they can be pasted into the dashboard
-- without a migration carrying a credential in git history.
insert into public.app_config (key, value, is_public, description) values
  ('cashfree_app_id', '1318136a7b8f98dbef169d1a6d56318131', false,
   'Cashfree x-client-id. Read only by Edge Functions via service_role.'),
  ('cashfree_secret_key', '', false,
   'Cashfree x-client-secret. Also the HMAC key for webhook signatures. Paste from the '
   'Cashfree dashboard; while empty every payment function fails closed.'),
  ('cashfree_env', 'production', false,
   'production -> api.cashfree.com, sandbox -> sandbox.cashfree.com. One-cell switch.'),
  ('cashfree_api_version', '2025-01-01', false,
   'Sent as x-api-version. Payload shapes change between versions.'),
  ('cashfree_plan_id', 'id_circle360_499', false,
   'Pre-created PERIODIC plan in the Cashfree dashboard.'),
  ('cashfree_plan_name', 'name_circle360_499', false,
   'Display name of the Cashfree plan, for diagnostics only.'),
  ('cashfree_trial_amount', '3', false,
   'Authorisation amount in INR, captured and kept. This is the trial fee.'),
  ('cashfree_recurring_amount', '499', false,
   'Recurring amount in INR. Must match the plan configured at Cashfree.'),
  -- Public because the paywall has to state it, and because one row read by both sides cannot
  -- drift: a private copy would eventually promise two days while the server billed after three.
  -- Nothing is exposed by it, and app_config is read-only to the anon key.
  ('cashfree_trial_days', '2', true,
   'Days between authorisation and the first recurring debit. Also the paywall copy.'),
  ('entitlement_grace_hours', '12', false,
   'How long access survives past trial_ends_at / current_period_end while a debit settles. '
   'Without it a user whose ₹499 was already taken sees a paywall until the webhook lands.'),
  ('reconcile_secret', '', false,
   'Shared secret for subscription-reconcile, sent as x-reconcile-secret by the cron job. '
   'Generate with: select encode(gen_random_bytes(32), ''hex''). Empty means the endpoint '
   'refuses every call, which is the safe default.'),
  ('trial_price_label', '₹3', true,
   'Paywall copy only. Never used to compute a charge.'),
  ('plan_price_label', '₹499', true,
   'Paywall copy only. Never used to compute a charge.')
on conflict (key) do nothing;
