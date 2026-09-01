import '../models/app_user.dart';
import '../models/subscription_offer.dart';
import '../repositories/app_config_repository.dart';
import '../repositories/subscription_repository.dart';
import 'edge_functions.dart';
import 'session_store.dart';

/// Talks to the payment Edge Functions. Cashfree itself is never called from the device.
///
/// The client sends no amounts, no plan id and no status — only its session token. Everything
/// that decides what a user is charged, and whether they are entitled, is resolved server-side
/// from `app_config` and from Cashfree. The anon key ships inside the app, so anything the app
/// could assert about its own subscription would be assertable by anyone.
class SupabaseSubscriptionRepository implements SubscriptionRepository {
  SupabaseSubscriptionRepository(this._functions, this._sessions, this._config);

  final EdgeFunctions _functions;
  final SessionStore _sessions;

  /// Serves the public `app_config` rows the paywall quotes. Read lazily rather than injected
  /// as a map, so this provider does not have to be constructed after the config future.
  final AppConfigRepository _config;

  @override
  Future<SubscriptionOffer> offer() async {
    // The typed reads fall back to the bundled defaults, so an unreachable config table shows
    // the right prices rather than an empty paywall.
    final config = await _config.load();
    final days = config.configInt('cashfree_trial_days');

    return SubscriptionOffer(
      trialPrice: config.configString('trial_price_label'),
      planPrice: config.configString('plan_price_label'),
      trialDays: days > 0 ? days : 2,
    );
  }

  @override
  Future<SubscriptionStart> start() async {
    final data = await _call('subscription-start');
    // The server refuses to open a second mandate for someone already inside a trial or a paid
    // month, and hands back their entitlement instead. Cache it so the next screen agrees.
    if (data['status'] == 'entitled') {
      final user = AppUser.fromServer(data['user']);
      if (user != null) await _sessions.cacheUser(user);
      return const SubscriptionStart.entitled();
    }

    final subscriptionId = data['subscription_id'] as String?;
    final sessionId = data['subscription_session_id'] as String?;
    if (subscriptionId == null || sessionId == null) {
      throw const SubscriptionException(
        'Could not start the payment. Please try again.',
      );
    }

    return SubscriptionStart.pending(
      subscriptionId: subscriptionId,
      sessionId: sessionId,
      environment: data['environment'] as String? ?? 'production',
    );
  }

  @override
  Future<AppUser?> refreshStatus() async {
    final data = await _call('subscription-status');
    final user = AppUser.fromServer(data['user']);
    if (user != null) await _sessions.cacheUser(user);
    return user;
  }

  @override
  Future<AppUser?> cancel() async {
    final data = await _call('subscription-cancel');
    final user = AppUser.fromServer(data['user']);
    if (user != null) await _sessions.cacheUser(user);
    return user;
  }

  Future<Map<String, dynamic>> _call(String name) async {
    final token = await _sessions.readToken();
    if (token == null) {
      throw const SubscriptionException('Please sign in again.');
    }

    try {
      return await _functions.call(name, bearerToken: token);
    } on EdgeError catch (e) {
      throw SubscriptionException(switch (e.code) {
        'unauthorized' => 'Please sign in again.',
        // The function's own message is already user-safe and more specific than anything
        // that could be written here — it names the actual refusal.
        'payment_failed' || 'throttled' || 'invalid_request' => e.message,
        _ => 'Could not complete the payment. Please try again.',
      });
    }
  }
}
