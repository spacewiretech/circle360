-- Loc360 initial schema: users, app config, sessions and OTP throttling.
--
-- Security model: the app authenticates with Fast2SMS, not Supabase Auth, so there is no
-- auth.uid() to write RLS policies against. The anon key ships inside the app and is
-- extractable, so every table holding user data is closed to it entirely — all writes go
-- through Edge Functions using the service_role key, which bypasses RLS.
--
-- The only thing the anon key can read is app_config rows flagged public.

-- ---------------------------------------------------------------- types

create type public.payment_status as enum ('trial', 'active', 'expired', 'cancelled');

comment on type public.payment_status is
  'Subscription state. New users start on trial; the payment integration will move them.';

-- ---------------------------------------------------------------- users

create table public.users (
  user_id       uuid primary key default gen_random_uuid(),

  -- The login key. Unique index here is the hot path for every OTP verification.
  -- CHECK mirrors the app's Indian-mobile rule so bad data cannot arrive by any route.
  mobile_no     text not null unique
                check (mobile_no ~ '^[6-9][0-9]{9}$'),

  -- Collected on a later screen, so it is null between OTP and the name step.
  name          text check (name is null or char_length(btrim(name)) between 1 and 80),

  creation_time timestamptz not null default now(),
  updated_at    timestamptz not null default now(),

  payment_type  public.payment_status not null default 'trial'
);

-- Reporting and billing sweeps filter on these two; without the indexes both become
-- sequential scans once the table is large.
create index users_payment_type_idx  on public.users (payment_type);
create index users_creation_time_idx on public.users (creation_time desc);

alter table public.users enable row level security;
-- Deliberately no policies. RLS with zero policies denies anon and authenticated outright,
-- while service_role bypasses RLS, so only the Edge Functions can touch this table.

comment on table public.users is
  'One row per verified mobile number. Written only by Edge Functions (service_role).';

-- ---------------------------------------------------------------- app config

create table public.app_config (
  key         text primary key,
  value       text not null,

  -- Without this flag the first secret anyone adds here would be silently readable by every
  -- installed app, since the anon key is public.
  is_public   boolean not null default true,

  description text,
  updated_at  timestamptz not null default now()
);

alter table public.app_config enable row level security;

create policy "public config is world readable"
  on public.app_config
  for select
  to anon, authenticated
  using (is_public);

comment on table public.app_config is
  'Runtime key/value config. Only is_public rows are readable with the anon key; private rows '
  'are for Edge Functions via service_role.';

-- ---------------------------------------------------------------- sessions

-- Proves who the caller is on requests after OTP verification, e.g. setting the name.
-- Tokens are stored hashed so a table dump cannot be replayed against the API.
create table public.user_sessions (
  token_hash   text primary key,
  user_id      uuid not null references public.users(user_id) on delete cascade,
  created_at   timestamptz not null default now(),
  expires_at   timestamptz not null default (now() + interval '90 days'),
  last_seen_at timestamptz
);

create index user_sessions_user_id_idx    on public.user_sessions (user_id);
create index user_sessions_expires_at_idx on public.user_sessions (expires_at);

alter table public.user_sessions enable row level security;

-- ---------------------------------------------------------------- OTP throttling

-- Every send costs money. Without a server-side cap, anyone holding the anon key could drain
-- the Fast2SMS wallet by hammering the send function.
create table public.otp_throttle (
  mobile_no    text primary key,
  window_start timestamptz not null default now(),
  send_count   integer not null default 0,
  last_send_at timestamptz
);

alter table public.otp_throttle enable row level security;

-- Claims one send against the caller's quota and reports whether it was allowed. Done in a
-- single upsert so concurrent requests cannot both slip past the cap.
create or replace function public.consume_otp_quota(
  p_mobile text,
  p_max    integer  default 10,
  p_window interval default interval '1 hour'
) returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare
  v_count integer;
begin
  insert into public.otp_throttle as t (mobile_no, window_start, send_count, last_send_at)
  values (p_mobile, now(), 1, now())
  on conflict (mobile_no) do update
    set window_start = case when now() - t.window_start > p_window then now()
                            else t.window_start end,
        -- t.* is the pre-update row, so this restarts the window rather than accumulating.
        send_count   = case when now() - t.window_start > p_window then 1
                            else t.send_count + 1 end,
        last_send_at = now()
  returning send_count into v_count;

  return v_count <= p_max;
end;
$$;

revoke all on function public.consume_otp_quota(text, integer, interval) from public, anon, authenticated;

-- ---------------------------------------------------------------- housekeeping

create or replace function public.touch_updated_at() returns trigger
language plpgsql
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

create trigger users_touch_updated_at
  before update on public.users
  for each row execute function public.touch_updated_at();

create trigger app_config_touch_updated_at
  before update on public.app_config
  for each row execute function public.touch_updated_at();

-- Both tables below grow without bound otherwise. Schedule with pg_cron once the app is live:
--   select cron.schedule('purge-expired', '0 3 * * *', 'select public.purge_expired()');
create or replace function public.purge_expired() returns void
language sql
security definer
set search_path = public
as $$
  delete from public.user_sessions where expires_at < now();
  delete from public.otp_throttle  where last_send_at < now() - interval '7 days';
$$;

revoke all on function public.purge_expired() from public, anon, authenticated;

-- ---------------------------------------------------------------- seed config

insert into public.app_config (key, value, is_public, description) values
  ('env',                 'production', true, 'Deployment environment name shown in diagnostics.'),
  ('api_base_url',        'https://symwrytqyhyxlcjaubru.supabase.co', true, 'Base URL the app talks to.'),
  ('min_supported_version', '1.0.0',    true, 'Below this the app should prompt to update.'),
  ('otp_length',          '6',          true, 'Digits in the OTP; must match the Fast2SMS template.'),
  ('otp_expiry_minutes',  '5',          true, 'How long a code stays valid.'),
  ('otp_resend_cooldown_seconds', '30', true, 'Client-side wait before resend unlocks.'),
  ('max_tracked_people',  '3',          true, 'Cap on people a single account can track.')
on conflict (key) do nothing;
