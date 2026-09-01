-- Move the Fast2SMS credentials into app_config as PRIVATE rows, and make it structurally
-- hard to expose them again.
--
-- Context: the credentials were briefly added to app_config with is_public = true, which made
-- the live API key readable by anyone holding the anon key — and the anon key ships inside the
-- app. This migration closes that and adds a constraint so a secret-looking key can never be
-- flagged public again, whether by hand in the dashboard or by a future migration.

-- ---------------------------------------------------------------- normalise existing rows

-- A newline was pasted into the key name, so the row reads as "\nFAST2SMS_API_KEY".
update public.app_config
   set key = btrim(regexp_replace(key, '[\r\n\t]', '', 'g'))
 where key <> btrim(regexp_replace(key, '[\r\n\t]', '', 'g'));

-- Settle on lower_snake_case, matching every other key in the table.
update public.app_config set key = lower(key) where key <> lower(key);

-- Anything Fast2SMS-related is a credential or a DLT identifier: none of it belongs on a
-- device, and none of it is needed there.
update public.app_config set is_public = false where key like 'fast2sms%';

-- ---------------------------------------------------------------- guardrail

-- The dangerous mistake is a one-word edit in the dashboard, so it is worth making the
-- database refuse it outright rather than relying on remembering.
alter table public.app_config
  add constraint app_config_secrets_stay_private
  check (
    is_public = false
    or key !~ '(^fast2sms|_key$|_secret$|_token$|password|credential)'
  );

comment on constraint app_config_secrets_stay_private on public.app_config is
  'Secret-looking keys cannot be marked public. The anon key that reads public rows ships '
  'inside the app, so a public credential is a published credential.';

-- ---------------------------------------------------------------- rows the functions read

-- Created empty and private so the values can be filled in from the dashboard without having
-- to remember the is_public flag. An empty fast2sms_otp_id keeps the dev OTP bypass active.
insert into public.app_config (key, value, is_public, description) values
  ('fast2sms_api_key', '', false,
   'Fast2SMS Dev API key. Read only by Edge Functions via service_role.'),
  ('fast2sms_otp_id', '', false,
   'Fast2SMS OTP Template ID. While empty, allow_dev_otp can stand in for real SMS.'),
  ('allow_dev_otp', 'false', false,
   'When true AND fast2sms_otp_id is empty, verify-otp accepts 000000 and no SMS is sent. '
   'Never leave true once a template exists.')
on conflict (key) do nothing;
