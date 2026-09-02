-- Turn the reconciliation safety net on.
--
-- Everything below existed as a commented-out suggestion and was never actually set up, so in
-- practice none of it was running: pg_cron was not installed, and `reconcile_secret` was still
-- the empty string it was seeded with, which makes `subscription-reconcile` refuse every call
-- by design. The result was that the only path from "Cashfree charged ₹499" to "this user is
-- still entitled" was the webhook, with nothing behind it.

create extension if not exists pg_cron;
create extension if not exists pg_net;

-- ---------------------------------------------------------------- secret

-- Generated in the database so the value never passes through a migration file, a shell history
-- or a code review. Only filled when still empty, so re-running this cannot rotate a secret out
-- from under a scheduled job that is already using it.
-- Schema-qualified: pgcrypto lives in `extensions` on Supabase and is not on the search_path
-- a migration runs with, so the bare name resolves to nothing.
update public.app_config
   set value = encode(extensions.gen_random_bytes(32), 'hex')
 where key = 'reconcile_secret'
   and (value is null or value = '');

-- ---------------------------------------------------------------- schedule

-- Unscheduled first so re-running the migration replaces the job rather than erroring on the
-- duplicate name.
do $$
begin
  if exists (select 1 from cron.job where jobname = 'subscription-reconcile-hourly') then
    perform cron.unschedule('subscription-reconcile-hourly');
  end if;
  if exists (select 1 from cron.job where jobname = 'purge-expired-daily') then
    perform cron.unschedule('purge-expired-daily');
  end if;
end
$$;

-- Hourly, at seven minutes past. Off the hour on purpose: Cashfree's own batches fire on it,
-- and a sweep that runs in the same minute as the debit finds nothing and then waits an hour.
--
-- The secret is read from app_config at run time rather than baked in, so rotating the row is
-- enough and the job never has to be rewritten.
select cron.schedule(
  'subscription-reconcile-hourly',
  '7 * * * *',
  $job$
  select net.http_post(
    url := 'https://symwrytqyhyxlcjaubru.supabase.co/functions/v1/subscription-reconcile',
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'x-reconcile-secret', (select value from public.app_config where key = 'reconcile_secret')
    ),
    body := '{}'::jsonb,
    timeout_milliseconds := 55000
  );
  $job$
);

-- Sessions and OTP throttle rows, plus the webhook audit trail below.
select cron.schedule('purge-expired-daily', '20 3 * * *', $job$select public.purge_expired();$job$);

-- ---------------------------------------------------------------- retention

-- `payment_events` is written before the signature is checked, which is deliberate — a forged
-- call is worth being able to see — but it means anyone who can reach the endpoint can grow the
-- table, and nothing was ever deleting from it. Unverified deliveries are noise after a month;
-- verified ones are the audit trail for a disputed charge and are kept far longer.
create or replace function public.purge_expired()
returns void
language sql
security definer
set search_path = public
as $$
  delete from public.user_sessions where expires_at < now();
  -- Unchanged from the init migration, last_send_at and all.
  delete from public.otp_throttle  where last_send_at < now() - interval '7 days';
  delete from public.payment_events
   where signature_ok = false and received_at < now() - interval '30 days';
  delete from public.payment_events
   where signature_ok and received_at < now() - interval '180 days';
$$;

revoke all on function public.purge_expired() from public, anon, authenticated;

comment on function public.purge_expired is
  'Daily sweep: expired sessions, stale OTP throttle rows, and aged webhook deliveries.';

-- ---------------------------------------------------------------- ledger survival

-- Deleting a user erased their entire financial history, because both foreign keys on
-- subscription_payments cascade. The charge record is what answers "was this person actually
-- billed" months later, and it must outlive the account. user_id is already nullable.
alter table public.subscription_payments
  drop constraint if exists subscription_payments_user_id_fkey;

alter table public.subscription_payments
  add constraint subscription_payments_user_id_fkey
  foreign key (user_id) references public.users(user_id) on delete set null;

alter table public.subscription_payments
  drop constraint if exists subscription_payments_subscription_pk_fkey;

alter table public.subscription_payments
  add constraint subscription_payments_subscription_pk_fkey
  foreign key (subscription_pk) references public.subscriptions(id) on delete set null;
