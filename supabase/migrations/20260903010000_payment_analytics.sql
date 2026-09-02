-- Payment history on the user row, plus somewhere to put refunds and disputes.
--
-- Everything a user has been charged already exists in `subscription_payments`, but only as a
-- ledger: answering "how many times has ₹499 come out of this account" meant an aggregate, and
-- `me` and `subscription-status` are single-row reads on the hot path. These columns are
-- denormalised for the same reason `active_subscription_id` already is, and the reconcile sweep
-- recomputes them so drift repairs itself.
--
-- Strictly additive. No existing column changes type, gains NOT NULL, or gains a CHECK; nothing
-- touches payment_type, trial_ends_at, current_period_end or active_subscription_id, which are
-- the four columns entitlement is derived from. Live trial users are unaffected.

-- ---------------------------------------------------------------- users

alter table public.users
  -- How many ₹499 debits have actually succeeded, and what they add up to. The AUTH ₹3 counts
  -- toward total_paid_amount but never toward successful_charge_count: it bought the trial, not
  -- a month, and conflating them makes the first renewal look like the second.
  add column if not exists successful_charge_count integer       not null default 0,
  add column if not exists failed_charge_count     integer       not null default 0,
  add column if not exists total_paid_amount       numeric(12,2) not null default 0,

  -- Billing dates. trial_started_at is the interesting one: it was previously impossible to
  -- reconstruct, because trial_ends_at is computed once from a config value that may since
  -- have changed.
  add column if not exists trial_started_at        timestamptz,
  add column if not exists subscription_started_at timestamptz,
  add column if not exists first_paid_at           timestamptz,
  add column if not exists next_billing_at         timestamptz,
  add column if not exists cancelled_at            timestamptz,

  -- The last charge, so support can answer "did it go through" without a join.
  add column if not exists last_payment_at         timestamptz,
  add column if not exists last_payment_amount     numeric(10,2),
  add column if not exists last_payment_status     text,

  -- Informational only, and deliberately NOT a new payment_status enum value. isEntitled ends
  -- in `default: return false`, so adding ON_HOLD or PAUSED to that enum would instantly
  -- revoke access from exactly the users we want to warn. Entitlement stays derived from
  -- payment_type plus the two dates; this just says why the mandate is unhappy.
  add column if not exists billing_state           text;

comment on column public.users.successful_charge_count is
  'Successful RECURRING debits. Excludes the ₹3 authorisation.';
comment on column public.users.total_paid_amount is
  'Every successful charge including the ₹3 authorisation, less refunds.';
comment on column public.users.billing_state is
  'on_hold | paused | dunning | disputed. Informational: never consulted for entitlement.';

-- Finding everyone whose mandate needs attention, for a dunning sweep or a support view.
create index if not exists users_billing_state_idx
  on public.users (billing_state)
  where billing_state is not null;

-- ---------------------------------------------------------------- refunds

-- Refund webhooks are currently recorded in payment_events and then dropped, because a refund
-- payload names no subscription. It does name a payment, though, and that resolves to a user.
create table if not exists public.subscription_refunds (
  id             uuid primary key default gen_random_uuid(),

  -- Set null rather than cascade: a refund is a financial record and must outlive the rows it
  -- points at, for the same reason the payment ledger now does.
  payment_pk     uuid references public.subscription_payments(id) on delete set null,
  user_id        uuid references public.users(user_id) on delete set null,

  -- The idempotency guard, mirroring subscription_payments.cf_payment_id. A redelivered
  -- refund webhook upserts one row rather than clawing back two months.
  cf_refund_id   text not null unique,
  cf_payment_id  text,

  amount         numeric(10,2),
  currency       text not null default 'INR',
  status         text not null,
  reason         text,
  refund_time    timestamptz,
  raw            jsonb,

  created_at     timestamptz not null default now()
);

create index if not exists subscription_refunds_user_idx
  on public.subscription_refunds (user_id, refund_time desc);
create index if not exists subscription_refunds_payment_idx
  on public.subscription_refunds (cf_payment_id);

alter table public.subscription_refunds enable row level security;

comment on table public.subscription_refunds is
  'Cashfree refunds, unique on cf_refund_id. Written only by Edge Functions (service_role).';

-- ---------------------------------------------------------------- disputes

create table if not exists public.payment_disputes (
  id             uuid primary key default gen_random_uuid(),
  user_id        uuid references public.users(user_id) on delete set null,

  cf_dispute_id  text not null unique,
  cf_payment_id  text,

  amount         numeric(10,2),
  currency       text not null default 'INR',

  -- Free text for the same reason subscriptions.status is: an unrecognised dispute state must
  -- be recorded so it can be seen, not rejected.
  status         text not null,
  dispute_type   text,
  reason         text,
  respond_by     timestamptz,
  raw            jsonb,

  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now()
);

create index if not exists payment_disputes_user_idx
  on public.payment_disputes (user_id, created_at desc);

alter table public.payment_disputes enable row level security;

create trigger payment_disputes_touch_updated_at
  before update on public.payment_disputes
  for each row execute function public.touch_updated_at();

comment on table public.payment_disputes is
  'Chargebacks and disputes. Opening one does not revoke access; losing one does.';

-- ---------------------------------------------------------------- backfill

-- Derived from the rows that already exist, so users who predate these columns get real
-- numbers rather than zeros. Idempotent: it recomputes from the ledger rather than adding to
-- whatever is already there, which is also exactly what the reconcile sweep does later.
with ledger as (
  select
    user_id,
    count(*) filter (where kind = 'RECURRING' and status = 'SUCCESS')  as ok_count,
    count(*) filter (where status not in ('SUCCESS', 'PENDING'))       as bad_count,
    coalesce(sum(amount) filter (where status = 'SUCCESS'), 0)         as paid,
    min(payment_time) filter (where kind = 'RECURRING' and status = 'SUCCESS') as first_paid,
    max(payment_time)                                                  as last_at
  from public.subscription_payments
  group by user_id
)
update public.users u set
  successful_charge_count = coalesce(l.ok_count, 0),
  failed_charge_count     = coalesce(l.bad_count, 0),
  total_paid_amount       = coalesce(l.paid, 0),
  first_paid_at           = l.first_paid,
  last_payment_at         = l.last_at
from ledger l
where l.user_id = u.user_id;

-- The last charge's amount and status, which the aggregate above cannot carry.
update public.users u set
  last_payment_amount = p.amount,
  last_payment_status = p.status
from public.subscription_payments p
where p.user_id = u.user_id
  and p.payment_time is not distinct from u.last_payment_at
  and u.last_payment_at is not null;

-- Dates come off the mandate. authorized_at is when Cashfree captured the ₹3, which is both
-- when the trial started and when the subscription did.
update public.users u set
  trial_started_at        = s.authorized_at,
  subscription_started_at = s.authorized_at,
  next_billing_at         = s.next_schedule_date,
  cancelled_at            = s.cancelled_at
from public.subscriptions s
where s.subscription_id = u.active_subscription_id;
