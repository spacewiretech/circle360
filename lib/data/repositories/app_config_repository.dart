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

/// Values the app falls back to when config has never been fetched and there is no network.
///
/// A cold start must never block on the network, so these have to be good enough to run on.
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
};

/// Typed reads over the raw key/value map, so a bad or missing value can never crash a screen.
extension AppConfigValues on Map<String, String> {
  String configString(String key) =>
      this[key] ?? defaultAppConfig[key] ?? '';

  int configInt(String key) =>
      int.tryParse(configString(key)) ??
      int.tryParse(defaultAppConfig[key] ?? '') ??
      0;

  bool configFlag(String key) => configString(key).toLowerCase() == 'true';

  double configDouble(String key) =>
      double.tryParse(configString(key)) ??
      double.tryParse(defaultAppConfig[key] ?? '') ??
      0;
}
