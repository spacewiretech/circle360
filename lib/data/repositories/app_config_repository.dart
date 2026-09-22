import '../../app/env.dart';

/// Runtime configuration served from the backend rather than baked into the build.
///
/// Everything that is not a credential lives here — environment name, base URLs, limits —
/// so it can be changed without shipping a new app version.
abstract interface class AppConfigRepository {
  Future<Map<String, String>> load();
}

/// The Mixpanel project token, served as a config row rather than compiled in.
///
/// Deliberately absent from [defaultAppConfig]: no row means no token, no token means the app
/// runs on `NoopAnalytics`, and that is the correct behaviour for a checkout that has not been
/// pointed at a Mixpanel project. A default here would instead send every developer's traffic to
/// whichever project the constant named.
const mixpanelTokenKey = 'mixpanel_token';

/// The Facebook app the SDK reports conversions to, and the switch that silences it.
///
/// Unlike [mixpanelTokenKey] these are not the values the SDK initialises from — both native SDKs
/// read the App ID and Client Token out of the manifest and plist at process start, before Dart
/// runs. They are here so that reporting can be switched off, or pointed at a different Facebook
/// app during a campaign migration, without shipping a release. A blank [facebookAppIdKey] or a
/// false [facebookEnabledKey] leaves the sink dormant.
///
/// The Facebook **app secret** is deliberately absent, here and everywhere else in this repo. It
/// is a server-side Conversions API credential, the client SDK has no use for it, and
/// `app_config_secrets_stay_private` would refuse to publish it in any case.
const facebookAppIdKey = 'facebook_app_id';
const facebookEnabledKey = 'facebook_events_enabled';

/// The rule deciding which install runs SunioMax instead of Circle360.
///
/// Config rows rather than constants because the whole point is to be able to widen, narrow or
/// kill the second app's audience from the dashboard, without a release and without a review.
/// [sunioMaxEnabledKey] is the master switch; [sunioMaxUtmSourcesKey] is a comma-separated
/// allowlist of `utm_source` values, and [sunioMaxUtmCampaignsKey] narrows that to named
/// campaigns — blank meaning any campaign from an allowed source.
///
/// Public rows, and safe to be: they describe who sees which app, not how anything is paid for.
/// None of the three trips `app_config_secrets_stay_private` or [Env.parseAppConfig]'s matching
/// refusal — which is worth keeping true if these are ever renamed.
const sunioMaxEnabledKey = 'suniomax_enabled';
const sunioMaxUtmSourcesKey = 'suniomax_utm_sources';
const sunioMaxUtmCampaignsKey = 'suniomax_utm_campaigns';

/// SunioMax's spoken onboarding prompts, and its own paywall promo.
///
/// The four audio rows exist because SunioMax is sold to people who may not read English
/// comfortably — a voice-controlled product, bought through Hindi-language campaigns, whose
/// picker offers nine Indian languages. Config rows rather than bundled assets so a clip can be
/// recut, re-recorded in another language or withdrawn without shipping a release, which is the
/// same argument `paywall_video_url` is here for.
///
/// [sunioMaxPaywallVideoKey] splits footage the two apps were sharing. Read *first*, falling back
/// to `paywall_video_url` when blank — so the row can ship empty and change nothing.
///
/// Constants rather than literals at the call sites, unlike `paywall_video_url`, which has none
/// and is typed out at each of its two readers. Five keys read from four places is where that
/// stops being tolerable.
///
/// Public rows, and safe to be: marketing assets on a CDN, not credentials. None of the five trips
/// `app_config_secrets_stay_private` or [Env.parseAppConfig]'s matching refusal — they end in
/// `_url`, which matches none of its patterns. Worth keeping true if they are ever renamed,
/// because a refused key is dropped with a `debugPrint` rather than an exception: nothing would
/// fail, the clip would simply never play.
const sunioMaxAudioLanguageKey = 'suniomax_audio_language_url';
const sunioMaxAudioPhoneKey = 'suniomax_audio_phone_url';
const sunioMaxAudioOtpKey = 'suniomax_audio_otp_url';
const sunioMaxAudioNameKey = 'suniomax_audio_name_url';
const sunioMaxPaywallVideoKey = 'suniomax_paywall_video_url';

/// The row [sunioMaxPaywallVideoKey] falls back to. Circle360's promo, and the one both apps
/// showed before the split.
const paywallVideoKey = 'paywall_video_url';

/// The last resort, for a checkout with no env file at all.
///
/// A cold start must never block on the network, so these have to be good enough to run on. They
/// are no longer the only build-time answer though: `assets/env/app.env` carries an
/// `APP_CONFIG_*` line per public row and is layered over this by [appConfigFallbacks], which is
/// what lets a fallback value be corrected without editing Dart. Keep this map anyway — it is
/// what a fresh clone, and every test, runs on.
const defaultAppConfig = <String, String>{
  'env': 'production',
  'min_supported_version': '1.0.0',
  'otp_length': '6',
  'otp_expiry_minutes': '5',
  'otp_resend_cooldown_seconds': '30',
  'max_tracked_people': '3',
  // Paywall copy. The amounts that are actually charged come from the Cashfree plan and from
  // private config rows — these only decide what the screen says.
  'trial_price_label': '₹3',
  'plan_price_label': '₹499',
  'cashfree_trial_days': '2',
  // The same two prices as numbers, for the ad networks. Facebook's Purchase event bids against
  // a value and a currency code, and neither can be had from the labels above without parsing a
  // rupee sign off marketing copy — which breaks the first time a label reads '₹3 only' or the
  // app is sold outside India.
  //
  // Still not authoritative for billing: what is actually charged comes from the Cashfree plan.
  // A wrong number here misreports ROAS to Facebook; it cannot take anybody's money.
  'trial_price_amount': '3',
  'plan_price_amount': '499',
  'currency_code': 'INR',
  // Blank by design, exactly as [mixpanelTokenKey] is absent by design: no app id means the
  // Facebook sink never starts, which is correct for any build not pointed at a Facebook app.
  // The real value is served from `app_config` — see 20260909010000_facebook.sql.
  facebookAppIdKey: '',
  facebookEnabledKey: 'true',
  // The SunioMax gate. Off here on purpose, and in the same spirit as the two above: a fresh
  // clone, every test and any build whose env file says nothing runs Circle360 and only
  // Circle360. Turning the second app on is something a build or a dashboard row has to say
  // out loud. See lib/suniomax/data/app_variant.dart.
  sunioMaxEnabledKey: 'false',
  sunioMaxUtmSourcesKey: '',
  sunioMaxUtmCampaignsKey: '',
};

/// [defaultAppConfig] with the `APP_CONFIG_*` entries from `assets/env/app.env` layered on top.
///
/// The rung between Supabase and the compiled constants: a fetched or cached answer still wins,
/// so a dashboard change is never shadowed, but a build now carries a complete and editable set
/// of values for the device that has never reached Supabase at all. [defaultAppConfig] stays
/// underneath as the answer for a checkout with no env file.
///
/// A function rather than a constant because [Env.appConfig] is only populated once `Env.load()`
/// has run, which is after every `const` in this file is already fixed.
Map<String, String> appConfigFallbacks() => {
  ...defaultAppConfig,
  ...Env.appConfig,
};

/// The same precedence as [appConfigFallbacks], resolved one key at a time.
///
/// The typed reads below sit inside build methods, so they take this rather than merging two
/// maps to read a single string out of the result.
String _fallback(String key) =>
    Env.appConfig[key] ?? defaultAppConfig[key] ?? '';

/// Typed reads over the raw key/value map, so a bad or missing value can never crash a screen.
extension AppConfigValues on Map<String, String> {
  String configString(String key) => this[key] ?? _fallback(key);

  int configInt(String key) =>
      int.tryParse(configString(key)) ?? int.tryParse(_fallback(key)) ?? 0;

  bool configFlag(String key) => configString(key).toLowerCase() == 'true';

  double configDouble(String key) =>
      double.tryParse(configString(key)) ??
      double.tryParse(_fallback(key)) ??
      0;
}
