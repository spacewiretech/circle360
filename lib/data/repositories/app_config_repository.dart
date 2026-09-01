/// Runtime configuration served from the backend rather than baked into the build.
///
/// Everything that is not a credential lives here — environment name, base URLs, limits —
/// so it can be changed without shipping a new app version.
abstract interface class AppConfigRepository {
  Future<Map<String, String>> load();
}

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
}
