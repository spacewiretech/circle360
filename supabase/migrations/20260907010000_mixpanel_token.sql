-- The Mixpanel project token, served to the app as a public config row.
--
-- Two things have to happen here, and the second is the interesting one.

-- ---------------------------------------------------------------- guardrail

-- `app_config_secrets_stay_private` refuses to mark any key matching `_token$` as public, which
-- would reject `mixpanel_token` outright. That constraint is doing its job — the anon key that
-- reads public rows ships inside the app, so a public credential is a published credential — but
-- a Mixpanel *project token* is not a credential in that sense. It is a write-only ingestion
-- identifier that every Mixpanel client SDK is designed to embed, the same category as the
-- Supabase anon key already in `app.env`. It cannot read data, cannot export, and cannot
-- administer anything; the Service Account credentials that can are separate and stay off the
-- device entirely.
--
-- So the exception is named explicitly rather than the rule being loosened. Every other `_token`
-- key is still refused, and the next person to add one gets the same error this one did.
alter table public.app_config
  drop constraint if exists app_config_secrets_stay_private;

alter table public.app_config
  add constraint app_config_secrets_stay_private
  check (
    is_public = false
    or key = 'mixpanel_token'
    or key !~ '(^fast2sms|_key$|_secret$|_token$|password|credential)'
  );

comment on constraint app_config_secrets_stay_private on public.app_config is
  'Secret-looking keys cannot be marked public. The anon key that reads public rows ships '
  'inside the app, so a public credential is a published credential. `mixpanel_token` is the '
  'one exception: a Mixpanel project token is write-only by design and is meant to ship in '
  'the client, exactly like the Supabase anon key.';

-- ---------------------------------------------------------------- the row

-- Seeded empty, following the convention the Cashfree rows set: the value is pasted into the
-- dashboard rather than carried in git history. While it is empty the app runs on
-- `NoopAnalytics` and behaves exactly as it did before analytics existed, so shipping this
-- migration ahead of the value is safe.
insert into public.app_config (key, value, is_public, description) values
  ('mixpanel_token', '', true,
   'Mixpanel project token. Public by design — it is write-only and ships in the client. '
   'Blank disables analytics entirely; clearing it is the off switch, no release required.')
on conflict (key) do nothing;
