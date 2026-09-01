import '../cashfree/cashfree_checkout.dart';
import '../models/app_user.dart';
import '../models/subscription_offer.dart';
import '../models/upi_app.dart';
import '../repositories/subscription_repository.dart';
import 'fake_session.dart';

/// Stands in for the payment stack when Supabase is not configured, so the onboarding flow
/// stays walkable on a fresh checkout.
///
/// It grants the trial the same way the real path does — by setting a `trialEndsAt` and letting
/// entitlement be derived from it — rather than flipping a boolean. A fake that took a shortcut
/// the real one cannot would hide exactly the bugs this flow needs to surface.
class FakeSubscriptionRepository implements SubscriptionRepository {
  FakeSubscriptionRepository(this._session);

  final FakeSession _session;

  static const _trialDays = 2;

  @override
  Future<SubscriptionOffer> offer() async {
    await FakeSession.latency(300);
    return const SubscriptionOffer(
      trialPrice: '₹3',
      planPrice: '₹499',
      trialDays: _trialDays,
    );
  }

  @override
  Future<SubscriptionStart> start() async {
    await FakeSession.latency(600);
    final user = _session.user;
    if (user != null && user.entitled) return const SubscriptionStart.entitled();

    return const SubscriptionStart.pending(
      subscriptionId: 'fake_subscription',
      sessionId: 'fake_session',
      environment: 'sandbox',
    );
  }

  @override
  Future<AppUser?> refreshStatus() async {
    await FakeSession.latency(400);
    // The fake checkout always "succeeds", so this is where the trial is granted.
    final user = _session.user;
    if (user == null) return null;

    if (!user.entitled) {
      _session.user = user.copyWith(
        paymentType: PaymentType.trial,
        trialEndsAt: DateTime.now().add(const Duration(days: _trialDays)),
        entitled: true,
      );
    }
    return _session.user;
  }

  @override
  Future<AppUser?> cancel() async {
    await FakeSession.latency(400);
    final user = _session.user;
    if (user == null) return null;
    _session.user = user.copyWith(paymentType: PaymentType.cancelled, entitled: false);
    return _session.user;
  }
}

/// Skips the UPI handoff and reports success, so the paywall can be exercised on a simulator.
///
/// It reports two installed apps even though the simulator has none, because otherwise the app
/// picker — the part of this screen most likely to be wrong — could never be seen without a
/// real device and a real ₹3.
class FakeCashfreeCheckout implements CashfreeCheckout {
  const FakeCashfreeCheckout();

  @override
  Future<List<UpiApp>> installedApps() async {
    await FakeSession.latency(200);
    // No icons: the real ones arrive as base64 from the SDK, and the UI has to render a
    // sensible placeholder when one is missing anyway.
    return const [
      UpiApp(id: 'fake.gpay', displayName: 'Google Pay'),
      UpiApp(id: 'fake.paytm', displayName: 'Paytm'),
    ];
  }

  @override
  Future<CheckoutResult> openWithApp({
    required String subscriptionId,
    required String sessionId,
    required String environment,
    required String upiAppId,
  }) async {
    await FakeSession.latency(1200);
    return const CheckoutResult(CheckoutOutcome.verified);
  }

  @override
  Future<CheckoutResult> open({
    required String subscriptionId,
    required String sessionId,
    required String environment,
  }) async {
    await FakeSession.latency(1200);
    return const CheckoutResult(CheckoutOutcome.verified);
  }
}
