import 'package:flutter/foundation.dart';

/// Mirrors the `public.payment_status` enum. The database is the authority on the spelling.
enum PaymentType {
  trial,
  active,
  expired,
  cancelled;

  static PaymentType parse(Object? raw) {
    return switch (raw) {
      'active' => PaymentType.active,
      'expired' => PaymentType.expired,
      'cancelled' => PaymentType.cancelled,
      // Anything unrecognised — a value added server-side that this build predates — is treated
      // as trial, which grants nothing on its own. Failing towards the paywall is the safe way
      // to be wrong.
      _ => PaymentType.trial,
    };
  }
}

@immutable
class AppUser {
  const AppUser({
    required this.id,
    required this.phone,
    this.name = '',
    this.avatarAsset,
    this.avatarUrl,
    this.paymentType = PaymentType.trial,
    this.trialEndsAt,
    this.currentPeriodEnd,
    this.entitled = false,
  });

  final String id;

  /// E.164 without the country code, e.g. `9931145610`.
  final String phone;
  final String name;

  /// Bundled placeholder while there is no upload backend.
  final String? avatarAsset;
  final String? avatarUrl;

  final PaymentType paymentType;

  /// When the paid trial runs out. Null until Cashfree captures the ₹3 — a null here is what
  /// makes a brand new account land on the paywall rather than inside the app.
  final DateTime? trialEndsAt;

  /// End of the month covered by the last successful ₹499 debit.
  final DateTime? currentPeriodEnd;

  /// Computed by the server. The client never decides this while it is online — see
  /// [recomputeOffline] for the one case where it has to derive the answer itself.
  final bool entitled;

  bool get hasName => name.trim().isNotEmpty;

  /// Kept so the screens that only ask "can this user get in" read unchanged.
  bool get isSubscribed => entitled;

  /// True while inside the paid trial, so the paywall can tell a first-time subscriber apart
  /// from someone whose trial lapsed.
  bool get inTrial => paymentType == PaymentType.trial && entitled;

  /// False only for an account that has never authorised a mandate — the ₹3 offer applies.
  bool get hasEverSubscribed => trialEndsAt != null || currentPeriodEnd != null;

  /// The instant access lapses if nothing else changes, before any grace.
  ///
  /// Used to schedule the mid-session re-check: a two-day trial can perfectly well run out
  /// while the app is open, and without this nothing would notice until the next cold start.
  DateTime? get entitlementExpiresAt => switch (paymentType) {
        PaymentType.trial => trialEndsAt,
        PaymentType.active || PaymentType.cancelled => currentPeriodEnd,
        PaymentType.expired => null,
      };

  /// Grace window matching `app_config.entitlement_grace_hours`.
  ///
  /// Only used offline. Being generous here costs at most half a day of access to someone who
  /// stopped paying; being strict would lock out a paid-up user whose device has no signal and
  /// who therefore cannot reach the paywall to fix it either. The lenient failure is cheaper.
  static const _offlineGrace = Duration(hours: 12);

  /// Re-derives [entitled] from the stored dates.
  ///
  /// A cached `entitled: true` is a fact about the moment it was written, not about now. Trust
  /// it as-is and a trial that ended overnight still opens the app until the network returns.
  AppUser recomputeOffline([DateTime? asOf]) {
    final now = asOf ?? DateTime.now();
    bool future(DateTime? at, Duration grace) =>
        at != null && now.isBefore(at.add(grace));

    final derived = switch (paymentType) {
      PaymentType.active =>
        currentPeriodEnd == null || future(currentPeriodEnd, _offlineGrace),
      PaymentType.trial => future(trialEndsAt, _offlineGrace),
      // No grace: a cancelled mandate has no in-flight debit to wait for.
      PaymentType.cancelled => future(currentPeriodEnd, Duration.zero),
      PaymentType.expired => false,
    };

    return derived == entitled ? this : copyWith(entitled: derived);
  }

  /// Parses the user object every Edge Function returns.
  ///
  /// Returns null rather than throwing on a malformed payload: a shape this build does not
  /// recognise must land the caller on sign-in, not crash the splash screen.
  static AppUser? fromServer(Object? raw) {
    if (raw is! Map) return null;
    final id = raw['user_id'];
    if (id is! String) return null;

    return AppUser(
      id: id,
      phone: raw['mobile_no'] as String? ?? '',
      name: raw['name'] as String? ?? '',
      paymentType: PaymentType.parse(raw['payment_type']),
      trialEndsAt: _parseDate(raw['trial_ends_at']),
      currentPeriodEnd: _parseDate(raw['current_period_end']),
      entitled: raw['entitled'] == true,
    );
  }

  static DateTime? _parseDate(Object? raw) {
    if (raw is! String || raw.isEmpty) return null;
    return DateTime.tryParse(raw)?.toLocal();
  }

  AppUser copyWith({
    String? name,
    String? avatarAsset,
    String? avatarUrl,
    PaymentType? paymentType,
    DateTime? trialEndsAt,
    DateTime? currentPeriodEnd,
    bool? entitled,
  }) {
    return AppUser(
      id: id,
      phone: phone,
      name: name ?? this.name,
      avatarAsset: avatarAsset ?? this.avatarAsset,
      avatarUrl: avatarUrl ?? this.avatarUrl,
      paymentType: paymentType ?? this.paymentType,
      trialEndsAt: trialEndsAt ?? this.trialEndsAt,
      currentPeriodEnd: currentPeriodEnd ?? this.currentPeriodEnd,
      entitled: entitled ?? this.entitled,
    );
  }
}
