-- ---------------------------------------------------------------- store review account
--
-- Google Play and App Store reviewers need a working sign-in, and neither can receive an
-- Indian SMS. `allow_dev_otp` cannot serve that: it accepts a fixed code for every number and
-- only stays off because a real template is configured. These two rows instead open exactly
-- one number, so they are safe to leave set while the app is live.
--
-- Both must hold a well-formed value or the account is off entirely — see reviewAccount() in
-- supabase/functions/_shared/review_account.ts. Private, like every other operational row:
-- the anon key ships inside the app, and a public review code is a published review code.

insert into public.app_config (key, value, is_public, description) values
  ('review_mobile', '', false,
   'Ten-digit number the store reviewers sign in with. While set, this number skips Fast2SMS '
   'and accepts review_otp instead. Clear it once the app is out of review.'),
  ('review_otp', '', false,
   'The fixed 4-10 digit code review_mobile signs in with. Ignored unless review_mobile is '
   'also set. Verify attempts are capped at 10/hour for that number.')
on conflict (key) do nothing;
