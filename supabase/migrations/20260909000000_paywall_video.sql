-- ---------------------------------------------------------------- paywall promo video
--
-- The paywall's hero used to be a live OpenStreetMap render behind the sheet — scenery, and
-- scenery that cost a round of tile fetches on the one screen with no route out except a
-- payment. It is replaced by a looping promo, and the promo's URL lives here rather than in the
-- bundle for the reason every other row here exists: the video can be recut, re-hosted or
-- withdrawn entirely without shipping a release, and an A/B on it costs an UPDATE.
--
-- Public by design. It is a marketing asset on a CDN, not a credential; the anon key that reads
-- public rows already ships inside the app, and the video is served to anyone who reaches the
-- paywall anyway. `app_config_secrets_stay_private` is deliberately untouched —
-- `paywall_video_url` matches none of its patterns, and rewriting the constraint to "make room"
-- would silently drop the `mixpanel_token` exception carried in its definition.
--
-- Seeded empty, following `mixpanel_token` and the Cashfree rows: the value is pasted into the
-- dashboard rather than carried in git history. Empty is not a degraded state — the app renders
-- no card at all and the sheet simply sits higher on the warm page, which is the same frame the
-- onboarding steps use. So this migration is safe to ship weeks ahead of the footage, and
-- blanking the row is the off switch, no release required.
--
-- Must be https. iOS App Transport Security and Android's default `usesCleartextTraffic = false`
-- both refuse plain http, so an `http://` value would fail on every device rather than on some
-- of them; the client treats a non-https value as unset rather than spending twelve seconds
-- discovering that. An MP4 with its moov atom at the front (`-movflags +faststart`) starts
-- visibly sooner than one without, and the clip loops forever, so keep it short and keep it
-- small — this is the screen the user is waiting on to pay.
insert into public.app_config (key, value, is_public, description) values
  ('paywall_video_url', '', true,
   'https URL of the looping promo video on the Location History paywall. Public — a marketing '
   'asset, not a credential. Blank means no video: the paywall renders no card at all, which is '
   'the correct and intended state when there is nothing to show.')
on conflict (key) do nothing;
