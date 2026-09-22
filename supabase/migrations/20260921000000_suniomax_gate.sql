-- SunioMax: which app an account signed up in, and the rule deciding who sees it.
--
-- One APK ships two products. Circle360 is what every install gets; SunioMax is shown only to
-- devices that arrived through a paid campaign, identified by the Play install referrer. The
-- client reads that referrer, matches it against the three public config rows below, and runs one
-- app or the other — see lib/suniomax/data/app_variant.dart.
--
-- Nothing here changes what anyone is charged. Both apps open the same Cashfree mandate on the
-- same plan, through the same `subscription-start`, and entitlement is the same answer from the
-- same function. `signup_app` is attribution, not authorisation.

-- Which app this account was created in.
--
-- Deliberately NOT part of a uniqueness rule: `users.mobile_no` stays globally unique, so one
-- number is one account across both apps. That follows from the shared plan — making it
-- `(signup_app, mobile_no)` would let the same person hold two rows and be billed twice for one
-- subscription, which is a refund request, not a feature.
--
-- The consequence worth knowing: a Circle360 subscriber who later installs SunioMax signs in to
-- the account they already have, is already entitled, and walks past the paywall. That is the
-- correct behaviour for one subscription covering both apps.
alter table public.users
  -- Every row that existed before this migration was created in Circle360, which is what the
  -- default asserts. Only `verify-otp` ever writes it, and only on insert.
  add column if not exists signup_app text not null default 'circle360';

alter table public.users
  drop constraint if exists users_signup_app_known;

alter table public.users
  -- A closed set rather than free text: this column's whole job is to split a funnel in two, and
  -- a typo'd third value would quietly produce a third cohort nobody is looking at.
  add constraint users_signup_app_known
  check (signup_app in ('circle360', 'suniomax'));

comment on column public.users.signup_app is
  'Which of the two apps in the build this account was created in. Attribution only — it never '
  'affects entitlement, pricing or which Cashfree plan is used, and it is set once, on insert, '
  'by verify-otp. Existing rows are circle360 by default.';

-- Reporting: `where signup_app = 'suniomax'` is the first clause of every SunioMax funnel query,
-- and the column is low-cardinality, so this earns its keep only alongside the dates already
-- indexed. Partial, on the smaller side of a very lopsided split.
create index if not exists users_signup_app_idx
  on public.users (signup_app)
  where signup_app <> 'circle360';

-- The gate rule.
--
-- Public rows, and safe to be: they describe who sees which app, not how anything is paid for.
-- None of the three trips `app_config_secrets_stay_private`, and none matches the refusal regex
-- in Env.parseAppConfig — worth keeping true if they are ever renamed.
--
-- These are read by the CLIENT, not by any Edge Function. A device's first launch happens before
-- any fetch has succeeded, so a brand new install is judged by the APP_CONFIG_SUNIOMAX_* lines
-- bundled in assets/env/app.env; these rows take over from its second launch onward. Keep the
-- bundled rule broad and use these to narrow, or to kill the experiment outright.
insert into public.app_config (key, value, is_public, description) values
  (
    'suniomax_enabled',
    'false',
    true,
    'Master switch for the SunioMax experiment. False and no install sees it, whatever referrer '
    'it carries. Off here so that applying this migration alone changes nothing.'
  ),
  (
    'suniomax_utm_sources',
    'facebook',
    true,
    'Comma-separated allowlist of utm_source values that route an install into SunioMax. EMPTY '
    'MATCHES NOTHING, not everything.'
  ),
  (
    'suniomax_utm_campaigns',
    '',
    true,
    'Comma-separated allowlist of utm_campaign values, narrowing suniomax_utm_sources. Blank '
    'means any campaign from an allowed source.'
  )
on conflict (key) do nothing;
