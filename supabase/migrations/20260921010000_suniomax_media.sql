-- --------------------------------------------- SunioMax onboarding audio + its own paywall video
--
-- SunioMax is sold to people who may not read English comfortably: it is a voice-controlled
-- product, bought through Hindi-language paid campaigns, and its language picker offers nine
-- Indian languages. Every instruction in its onboarding is written text. These four rows give the
-- four onboarding steps a short spoken clip, so the screen can be *heard* rather than only read.
--
-- The fifth row splits the paywall footage. Both apps in this build have been showing the same
-- `paywall_video_url`, which is Circle360's promo — a map, a family, a location pin, none of which
-- SunioMax sells. `suniomax_paywall_video_url` is read first and falls back to `paywall_video_url`
-- when blank, so this migration changes nothing until somebody pastes a URL in.
--
-- Public by design, the same argument as `paywall_video_url` itself: these are marketing assets on
-- a CDN, not credentials, and the anon key that reads public rows already ships inside the app.
-- `app_config_secrets_stay_private` is deliberately untouched — none of these five matches any of
-- its patterns, and rewriting the constraint to "make room" would silently drop the
-- `mixpanel_token` exception carried in its definition. Worth keeping true if they are renamed:
-- `Env.parseAppConfig` enforces the same rule client-side and *drops* a refused key with a
-- `debugPrint`, so a rename that trips it fails silently.
--
-- Seeded empty, following `paywall_video_url` and `mixpanel_token`: the values are pasted into the
-- dashboard rather than carried in git history. Empty is not a degraded state — a blank row means
-- the screen renders no control at all and makes no sound, which is exactly how these four screens
-- look today. So this ships safely weeks ahead of the recordings, and blanking a row is the off
-- switch, no release required.
--
-- Must be https. iOS App Transport Security and Android's default `usesCleartextTraffic = false`
-- both refuse plain http, so an `http://` value would fail on every device rather than on some of
-- them; the client treats a non-https value as unset rather than spending twelve seconds
-- discovering that. Keep the clips short — they play while the user is trying to type a phone
-- number, and a voice-over that outlives the screen is worse than none.
--
-- Deliberately **not** extended to SunioMax's home screen. That is where the microphone listens:
-- audio played into a live `SpeechRecognizer` can transcribe into the lock phrase and lock the
-- user's phone by itself. Not a risk worth taking for a voice-over.
insert into public.app_config (key, value, is_public, description) values
  ('suniomax_audio_language_url', '', true,
   'https URL of the spoken prompt on the SunioMax language picker. Public — a marketing asset, '
   'not a credential. Blank means no audio and no control on screen, which is the correct state '
   'when there is nothing to play.'),
  ('suniomax_audio_phone_url', '', true,
   'https URL of the spoken prompt on the SunioMax phone number step. Blank means silence.'),
  ('suniomax_audio_otp_url', '', true,
   'https URL of the spoken prompt on the SunioMax verification code step. Blank means silence.'),
  ('suniomax_audio_name_url', '', true,
   'https URL of the spoken prompt on the SunioMax name step. Blank means silence.'),
  ('suniomax_paywall_video_url', '', true,
   'https URL of the looping promo on the SunioMax paywall. Blank falls back to '
   'paywall_video_url, which is Circle360''s promo — set this once there is SunioMax footage, '
   'because the two products sell different things.')
on conflict (key) do nothing;
