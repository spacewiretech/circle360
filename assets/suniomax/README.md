# `assets/suniomax/` — SunioMax artwork

Exported from the Figma file `Spacewire-Main`, the SunioMax frames. Separate from
`assets/images/` because the two apps in this build share a repo, not a brand — and because a
Circle360-only build should never be asked to ship SunioMax's logo.

**All three files are now present.** The directory is still declared in `pubspec.yaml` as a
directory, and every widget that loads one still passes an `errorBuilder` falling back to a drawn
approximation — so a checkout that loses them keeps building. Do not remove those fallbacks.

The one place a fallback is *not* a Flutter widget is the lock screen: `LockOverlay` renders with
no Flutter engine alive, so its blob is `res/drawable/lock_blob.xml`, drawn separately. Replacing
it with `mic_blob.png` means adding the PNG to `res/drawable/` and pointing the layout at it.

| File | Used by | Figma node |
|---|---|---|
| `wordmark.png` | `SxWordmark` — splash, every onboarding sheet, the paywall, the home header | `13538:15312` |
| `voice_lock_hero.png` | Not currently placed — kept for the Voice Lock screen's empty state | `13511:14745` |
| `mic_blob.png` | `SxMicBlob` — the phrase-capture sheet. **Its caption is painted into the artwork**, so nothing may overlay a label on it. | `13511:14622` |
| `bg_image_1.png` | The phone step's backdrop | `13511:14622` |
| `bg_image_2.png` | The name step's backdrop | `13511:14645` |
| `bg_image_3.png` | The OTP step's backdrop | `13511:14662` |

Export at 3x. `wordmark.png` is trimmed to the glyphs with no surrounding padding, because the
widgets position it by height and centre it themselves; a re-export with padding will look
mis-sized everywhere at once.

## The onboarding voice-over is not here, and must not be

The spoken prompts on the language, phone, OTP and name steps are **CDN URLs in public
`app_config` rows** — `suniomax_audio_language_url`, `_phone_url`, `_otp_url`, `_name_url` — not
files in this directory. Same for `suniomax_paywall_video_url`.

That is deliberate, and it is the same argument `paywall_video_url` is a row for. These clips are
spoken Hindi, and the words are marketing copy read aloud: they will be re-recorded, retimed and
eventually translated into more of the nine languages the picker offers. A bundled asset means a
release and a review for each of those; a row means an UPDATE. Bundling them would also put four
audio files into an APK that Circle360 users download and never play.

All five are seeded blank, and blank is a supported state: no sound, and **no control on screen**,
so a screen with no recording looks exactly as it did before the feature existed. https only —
iOS ATS and Android both refuse cleartext. Keep the clips short; they play while the user is
trying to type a phone number.
