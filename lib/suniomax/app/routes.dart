import '../../features/payment_status/payment_outcome.dart';

/// SunioMax's route paths.
///
/// Split out of `router.dart` so that anything needing only a path — `EntitlementGate`, which is
/// shared between the two apps and has to know where to evict a SunioMax user to — can have one
/// without importing the router, and so without dragging in every SunioMax screen.
///
/// **Every path is namespaced under `/sx`.** Both apps share one `analyticsObserver`, and that
/// observer maps route *patterns* to screen names — two routers both claiming `/phone` would
/// report one screen name for two unrelated screens and silently merge the funnels.
abstract final class SxRoutes {
  static const splash = '/sx';
  static const language = '/sx/language';
  static const phone = '/sx/phone';
  static const otp = '/sx/otp';
  static const name = '/sx/name';
  static const subscribe = '/sx/subscribe';

  /// `:outcome` is a [PaymentOutcome] slug — the same three the Circle360 flow uses, because the
  /// payment behind them is the same mandate on the same plan.
  static const paymentStatus = '/sx/payment-status/:outcome';
  static const home = '/sx/home';
  static const settings = '/sx/settings';

  static String paymentStatusFor(PaymentOutcome outcome) =>
      '/sx/payment-status/${outcome.slug}';
}
