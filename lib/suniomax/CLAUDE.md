# `lib/suniomax/` — the second app in this build

SunioMax: a voice-controlled phone-lock app, shown **only** to installs that arrived through a
paid campaign. Everyone else gets Circle360, unchanged.

One APK, two products. `bootMobileApp()` resolves which one a device runs and builds either
`Loc360App` or `SunioMaxApp`. Nothing below that line knows the other app exists.

## The gate, first

The single most load-bearing thing here. [data/app_variant.dart](data/app_variant.dart) decides,
once per install, from the Play install referrer:

| Step | What happens |
|---|---|
| 1 | A pinned verdict wins outright. Written when a user verifies their OTP, so no later rule change moves somebody mid-funnel or mid-subscription. |
| 2 | **The upgrade guard.** If `loc360.analytics_install_id` exists and this device has never been judged, it ran the app *before* the gate existed → pin Circle360 and stop. |
| 3 | A stored referrer is re-evaluated against the current rule, so the allowlist stays a dashboard decision. |
| 4 | Otherwise ask Play, with a 3s budget. An answer is stored forever; no answer stores nothing and is retried next launch. |

**Step 2 is not optional.** Circle360 is itself bought through Facebook Ads, so its own users'
referrers carry `utm_source=facebook` — exactly what a SunioMax campaign carries. Without the
guard, the release that introduced this gate would move every ad-acquired Circle360 subscriber
into a different app. `loc360.gate_seen` is what stops a timed-out first launch being mistaken
for an upgrade on its second.

Every uncertain path answers Circle360. A user who should have seen SunioMax and did not is a
worse campaign; the reverse is a broken app.

The rule lives in three **public** `app_config` rows — `suniomax_enabled`,
`suniomax_utm_sources`, `suniomax_utm_campaigns` — read from the config cache or the bundled
`APP_CONFIG_SUNIOMAX_*` lines, never from a fetch. A device's *first* launch predates any
successful fetch, so a brand new install is judged by what shipped in `assets/env/app.env`;
dashboard changes reach it from its second launch.

## What is shared, and what is not

**Reused from Circle360 unchanged** — and this is most of the app. Both products verify the same
numbers through the same Edge Functions and open the same Cashfree mandate on the same plan, so
`authRepositoryProvider`, `subscriptionRepositoryProvider`, `cashfreeCheckoutProvider`,
`sessionStoreProvider`, `appConfigProvider`, `entitlementProvider`, `EntitlementGate`, `OtpField`
and **all three of `OnboardingViewModel` / `SubscriptionViewModel` / `PaymentStatusViewModel`**
are the same code. Only the views differ.

**SunioMax's own:** the gate, the theme, the widgets, the router, the language picker, and the
voice lock — which is the only thing in this build with a native half of its own.

## Files

### `app/`

| File | What it does |
|---|---|
| `app.dart` | `SunioMaxApp`. Mirrors `Loc360App` minus the deeplink listener — the `loc360://` links belong to the other app. |
| `router.dart` | `sunioRouter`, a second top-level `final GoRouter`. Carries the **same** `Firebase.apps.isNotEmpty` guard as `lib/app/router.dart:76`, for the same reason. Also `SplashDestinationSunioRoute`, which translates Circle360's `SplashDestination` — its member is `sunioRoute`, not `route`, so it cannot collide with the extension in `lib/app/router.dart`. |
| `routes.dart` | `SxRoutes`. Split out so `EntitlementGate` can have a path without importing every SunioMax screen. |
| `assets.dart` | `SxImg`. None of these files are in the repo yet — see `assets/suniomax/README.md`. |
| `theme/sx_colors.dart` | `SxColors`. Brand `#2C6AA2`. Separate from `AppColors`: the two apps share a codebase, not a brand. |
| `theme/sx_typography.dart` | `SxText`. Poppins throughout, where Circle360 pairs Poppins with Inter. |
| `theme/sx_theme.dart` | `SxShape` + `buildSunioTheme()`. Light only, like Circle360's. |

**Every path is namespaced under `/sx`.** Both apps share one `analyticsObserver`, which keys
screen names off the route *pattern* — two routers both claiming `/phone` would report one screen
name for two unrelated screens and merge the funnels permanently.

### `data/`

| File | What it does |
|---|---|
| `app_variant.dart` | The gate. See above. |
| `install_referrer.dart` | The `circle360/referrer` channel, plus `parseReferrer` — a free function, so the matching rules are testable without a platform channel. |
| `providers.dart` | SunioMax's bindings. A sibling of `lib/data/providers.dart`, not a replacement: only what is SunioMax's alone lives here. `appVariantProvider` is **not** one of them — it sits in the shared file because `authRepositoryProvider` depends on it. |
| `language_preference.dart` | `SxLanguage` (the nine from the design) and its store. The UI is not translated; the choice is persisted and is what the recogniser uses for its language tag. |
| `onboarding_audio.dart` | The spoken prompts on the four onboarding screens. `SxAudioClip` (which screen reads which `app_config` row), `audioUrlFor`, `sunioPaywallVideoUrl`, the persisted mute, and `OnboardingAudioController` — which is **single-slot**, because the screens outlive each other. |
| `repositories/voice_lock_repository.dart` | The interface, plus `VoiceLockSettings` and `VoiceLockPermissions`. Three grants are reported separately, not as one "ready" flag: a user with the microphone but no overlay has a listener that hears the phrase and then cannot draw anything. |
| `channel_voice_lock_repository.dart` | The real one, on Android. Deliberately thin — every decision is made in Kotlin, because the service outlives the Flutter engine. |
| `local/local_voice_lock_repository.dart` | Settings only, and honest that nothing is listening. What runs on iOS, on web and in every test. |

### `features/`

`splash/`, `language/`, `onboarding/` (phone, OTP, name + `sx_onboarding_scaffold.dart`),
`subscription/`, `payment_status/`, `settings/`, and `home/` — which is `voice_lock_view.dart`,
`voice_lock/voice_lock_viewmodel.dart`, `widgets/sx_prompt_sheet.dart` and
`widgets/sx_phrase_capture_sheet.dart`.

**`settings/` carries only the rows that do something.** The frame also lists a Sunio response
language, a command history, and a Find Phone section — none of which exist in this build. A
settings screen whose controls change nothing is worse than a shorter one, because the user cannot
tell which half is real.

**The home screen is the voice lock and nothing else.** The three-tab bar from the original frames
is gone: the other two tabs were a voice-command surface and a clap-to-find setting, neither of
which exists, and a bar with two dead tabs is worse than no bar.

The onboarding, paywall and payment-status **views are new; their ViewModels are Circle360's**.

### `widgets/`

`sx_wordmark.dart`, `sx_primary_button.dart`, `sx_sheet_surface.dart` (+ `SxTermsFooter`),
`sx_otp_field.dart` (+ `SxPhoneField`, `SxTextFieldBox`), `sx_settings_row.dart`,
`sx_toggle_card.dart`, `sx_mic_blob.dart`, `sx_audio_button.dart`.

Every widget that loads an image passes an `errorBuilder` and falls back to a drawn stand-in, so
the flow is walkable before the Figma exports land.

## Gotchas

- **The OTP screen renders six boxes, not the four in the frame.** Codes are six digits
  (`app_config.otp_length`, and the Fast2SMS template behind it). Four would be a screen a user
  cannot finish. The circular styling is the design's; the count is the backend's.
- **The paywall shows the prices actually charged**, read from `trial_price_label` /
  `plan_price_label` — the same rows Circle360 reads, because it is the same plan. The Figma frame
  reads "₹99 ₹299", which this plan does not debit. Stating one amount while authorising another
  breaks UPI Autopay mandate consent, so the numbers come from config rather than the mockup.
- **The switch comes first, and permissions are the only thing that can refuse it.** Turn Voice
  Lock on → grant the microphone and the overlay → *then* record the phrases and set a passcode.
  Everything below the switch is `IgnorePointer`-inert until it is on. Requiring the configuration
  first made the switch impossible to turn on and the setup rows impossible to reach, which is
  exactly backwards.
  What prevents a lock-out is not the switch but `VoiceLockService.lock()`, which **refuses to put
  the overlay up until a backup passcode exists**. That guard sits at the moment of locking, so it
  costs the setup flow nothing and cannot be reordered away. Arming with no phrase is harmless —
  the service matches nothing against an empty phrase.
- **The lock is real, and its limits are real too.** `LockOverlay` is a `TYPE_APPLICATION_OVERLAY`
  window, not an Activity, so Home cannot dismiss it and Back is swallowed. **The notification
  shade can still be pulled down over it** — those are system windows, no API blocks them, and the
  only thing that ever could was an `AccessibilityService`, which Play does not permit for
  screen-lock apps. The Voice Lock screen says so on screen rather than letting a user discover it.
- **The onboarding voice-over is one player, not one per screen.** `context.push(SxRoutes.otp)`
  leaves the phone screen **mounted** underneath, so its `dispose` does not run on the way forward
  — a clip owned by each screen would have two voices talking at once. `OnboardingAudioController`
  owns the single player, and a screen may only stop what it still owns (`stopIfCurrent`).
  `PromoVideo` is **not** reusable for this: it rejects a stream whose reported size is zero, which
  is exactly what an audio-only file reports. That guard is load-bearing for video (an HTML error
  page served with a video content type does the same), so audio opens its own controller rather
  than weakening it. **SunioMax's home screen deliberately has no clip** — it is where the
  microphone listens, and a voice-over transcribed by a live `SpeechRecognizer` can match the lock
  phrase and lock the user's phone by itself. All five URLs are public `app_config` rows, seeded
  blank; blank means silence *and* no control on screen, which is how these screens look today.
- **The phrases are spoken, never typed, and that is load-bearing.** `SpeechRecognizer` has its
  own idea of the words: "Hare Krishna" may come back as "hairy krishna" on a given device and
  language, consistently. A phrase the user *typed* would never match what the listener hears, so
  the lock would simply never fire with nothing on screen to explain why. `PhraseCapture` records
  it through the same engine that will later match it, and the capture sheet shows the
  transcription before saving so a bad capture is visible immediately.
- **Phrase matching must stay script-agnostic.** `VoiceLockService.normalise()` strips punctuation
  and symbols; it must never go back to allowlisting characters. An allowlist of
  `[^a-z0-9\u0900-\u097F ]` deleted every character of six of the nine offered languages —
  Telugu, Tamil, Kannada, Malayalam, Odia and Bangla all normalised to the empty string and could
  never match, silently.
- **`restart()` cancels only its own token.** It used to call `removeCallbacksAndMessages(null)`,
  which wiped the `LockOverlay.show` that `lock()` had posted one line earlier in the same
  callback — the phrase matched, the log said so, and the overlay never appeared.
- **`LockOverlay.hide()` clears the persisted `locked` flag before its early return.** With the
  clear after it, a process killed while locked left `locked = true` with nothing able to reset
  it, and the lock phrase became a permanent no-op.
- **`SpeechRecognizer` is the weakest part of this feature.** It handles one utterance at a time,
  so `VoiceLockService` restarts it in a loop with a backoff. Missed phrases are expected. The capture sheet is
  what makes that recoverable: it shows what was heard, so a phrase that will never match is
  caught at setup rather than the first time the user needs the lock.
- **After a reboot the listener does not come back on its own.** Android 14+ refuses to start a
  microphone foreground service from `BOOT_COMPLETED`, with no exemption to apply for, so the user
  has to open the app once.
- **The passcode is hashed, but the Keystore is what protects it.** Four digits is ten thousand
  possibilities — see the note on `_hash` in `local_voice_lock_repository.dart`.
- Analytics names live in `lib/data/analytics/analytics_events.dart` like everything else. The
  language is reported through the existing `P.appLanguage` / `P.appLocale` supers, not a new key.
  **The voice phrase and the passcode are never sent anywhere** — only their shape.
- **Both apps report to the same Facebook app.** One App ID and Client Token in
  `android/facebook.properties`, read from the manifest at process start, so the SDK comes up
  before the variant is even known — which is fine, because it is the same app either way.
  Per-campaign attribution is unaffected: Facebook attributes a conversion to the ad that drove
  the install. But `FacebookAnalytics.registerSuper` is a **no-op** — Facebook's parameters are
  per-event with a fixed catalogue, so there is no `app` super property the way Mixpanel has one.
  `AppVariant.fbContentId` is the only thing separating the two products there, and it is what an
  Events Manager breakdown, a Custom Audience or a value-based lookalike keys off.

## Running SunioMax on a development device

`flutter run` and `adb install` carry no Play referrer, and Play will not attribute one after the
fact, so SunioMax is otherwise unreachable in debug. Two `--dart-define` overrides exist for it,
both behind `kDebugMode` and therefore tree-shaken out of any release build.

**Work on the screens** — skips the gate entirely, needs no config:

```bash
flutter run --dart-define=SUNIOMAX_FORCE=true
```

**Test the gate for real** — seeds the referrer exactly as Play would hand it over and lets the
`app_config` rule judge it. Also needs `APP_CONFIG_SUNIOMAX_ENABLED=true` in `assets/env/app.env`,
because `defaultAppConfig` ships it `false`:

```bash
flutter run --dart-define=SUNIOMAX_REFERRER='utm_source=facebook&utm_medium=paid&utm_campaign=palm_diwali_oct26'
```

Use the second before spending money on a campaign: it is what proves that campaign's referrer
actually matches the allowlist. Neither override is a substitute for `test/app_variant_test.dart`,
which is where the gate's behaviour is actually pinned down.

Circle360 is what you get with no define, which is also what every existing developer command
already does.
