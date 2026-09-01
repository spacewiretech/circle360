-- Location sharing: who may see whose position, who has been invited, and the latest fix.
--
-- Same security model as the rest of the schema — RLS on with no policies, so the anon key
-- shipping inside the app can do nothing here. Every read and write goes through an Edge
-- Function holding service_role.
--
-- The share model is DIRECTED and consent is per-direction. Adding someone creates two rows:
-- your location starts flowing to them immediately (you consented by adding), and a pending
-- row asks them to share back. Nobody's position is ever exposed without their own action.

-- ---------------------------------------------------------------- types

create type public.share_status as enum ('pending', 'active');

comment on type public.share_status is
  'pending = the sharer has not agreed yet; active = their location is visible to the viewer.';

-- ---------------------------------------------------------------- shares

create table public.location_shares (
  id         uuid primary key default gen_random_uuid(),

  -- Whose location flows.
  sharer_id  uuid not null references public.users(user_id) on delete cascade,
  -- Who gets to see it.
  viewer_id  uuid not null references public.users(user_id) on delete cascade,

  status     public.share_status not null default 'pending',

  -- Which side asked. Kept so the UI can word the pending state from both ends ("waiting for
  -- Mom" vs "Mom wants to see you") without a second lookup.
  created_by uuid not null references public.users(user_id) on delete cascade,

  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),

  constraint location_shares_not_self check (sharer_id <> viewer_id),

  -- Makes add-person idempotent: two people adding each other at the same moment converge on
  -- one row per direction instead of racing to duplicates.
  unique (sharer_id, viewer_id)
);

-- The `people` function's hot path: everything this account is allowed to see.
create index location_shares_viewer_idx on public.location_shares (viewer_id);

-- Requests waiting on me. Partial, because the active rows are the overwhelming majority.
create index location_shares_sharer_pending_idx
  on public.location_shares (sharer_id) where status = 'pending';

alter table public.location_shares enable row level security;
-- Deliberately no policies; see the header.

create trigger location_shares_touch_updated_at
  before update on public.location_shares
  for each row execute function public.touch_updated_at();

comment on table public.location_shares is
  'Directed permission: sharer_id''s location is visible to viewer_id once status is active. '
  'A mutual connection is two rows.';

-- ---------------------------------------------------------------- invites

-- A number that is not on Loc360 yet. Claimed by verify-otp when that number signs in, which
-- is what makes the connection form by itself after an install.
create table public.pending_invites (
  id           uuid primary key default gen_random_uuid(),
  inviter_id   uuid not null references public.users(user_id) on delete cascade,

  -- Same CHECK as users.mobile_no, so an invite cannot exist for a number that could never
  -- become an account.
  mobile_no    text not null check (mobile_no ~ '^[6-9][0-9]{9}$'),

  -- What the inviter typed. Lets their card show a name before the invitee ever signs up.
  invited_name text check (invited_name is null or char_length(btrim(invited_name)) between 1 and 80),

  created_at   timestamptz not null default now(),
  claimed_at   timestamptz,

  unique (inviter_id, mobile_no)
);

-- The claim lookup on every single sign-in. Partial: claimed rows are never searched again.
create index pending_invites_open_idx
  on public.pending_invites (mobile_no) where claimed_at is null;

alter table public.pending_invites enable row level security;

comment on table public.pending_invites is
  'An invite to a number with no account yet. claim_pending_invites turns these into shares.';

-- ---------------------------------------------------------------- latest position

-- Latest fix only — no history. One upserted row per user keeps the write path cheap enough
-- to take every device's 10-second heartbeat without a retention job.
create table public.user_locations (
  user_id    uuid primary key references public.users(user_id) on delete cascade,

  latitude   double precision not null check (latitude between -90 and 90),
  longitude  double precision not null check (longitude between -180 and 180),
  accuracy   double precision,
  speed      double precision,
  altitude   double precision,
  platform   text check (platform is null or platform in ('android', 'ios')),

  -- The device's own clock, kept for diagnostics only.
  fixed_at   timestamptz not null,

  -- The server clock, and the ONLY thing freshness is judged on. Device clocks are wrong often
  -- enough — and are trivially spoofable — that "is this person online" cannot depend on one.
  updated_at timestamptz not null default now()
);

alter table public.user_locations enable row level security;

comment on table public.user_locations is
  'Latest known position per user, upserted by ingest-location. No history is kept.';

-- ---------------------------------------------------------------- invite claiming

-- Turns every open invite for a number into a real connection, at the moment that number
-- first verifies an OTP.
--
-- One call rather than a webhook: the whole point is that it happens inside the same request
-- that creates the user, so a half-linked state — an account that exists but whose inviter
-- cannot see it — is not reachable.
create or replace function public.claim_pending_invites(
  p_user_id uuid,
  p_mobile  text
) returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  v_claimed integer;
begin
  -- The UPDATE claims first and returns exactly the rows this call won. Two concurrent
  -- sign-ins for the same number therefore cannot both claim the same invite: row locking
  -- makes the loser see claimed_at already set and return nothing.
  with claimed as (
    update public.pending_invites
       set claimed_at = now()
     where mobile_no = p_mobile
       and claimed_at is null
       -- A user cannot be connected to themselves, and an invite sent to your own number
       -- before you signed up would otherwise try exactly that.
       and inviter_id <> p_user_id
    returning inviter_id
  ),
  -- The inviter's location starts flowing immediately: they consented when they invited.
  outbound as (
    insert into public.location_shares (sharer_id, viewer_id, status, created_by)
    select inviter_id, p_user_id, 'active', inviter_id from claimed
    on conflict (sharer_id, viewer_id) do nothing
    returning 1
  ),
  -- The new user's own location does NOT start flowing. They have agreed to nothing yet, so
  -- this waits for an explicit accept in the app.
  inbound as (
    insert into public.location_shares (sharer_id, viewer_id, status, created_by)
    select p_user_id, inviter_id, 'pending', inviter_id from claimed
    on conflict (sharer_id, viewer_id) do nothing
    returning 1
  )
  select count(*) into v_claimed from claimed;

  return v_claimed;
end;
$$;

revoke all on function public.claim_pending_invites(uuid, text) from public, anon, authenticated;

comment on function public.claim_pending_invites(uuid, text) is
  'Called by verify-otp. Converts open invites for a number into shares and stamps them claimed.';

-- ---------------------------------------------------------------- seed config

insert into public.app_config (key, value, is_public, description) values
  ('invite_url_base', 'https://loc360.app/invite', true,
   'Prefix for invite links. The link is attribution only — the connection is made by the '
   'mobile-number claim, so it still forms if the invitee installs straight from the store.')
on conflict (key) do nothing;
