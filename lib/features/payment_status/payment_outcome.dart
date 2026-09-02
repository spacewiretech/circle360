/// How a checkout ended, as far as the server could tell.
///
/// Deliberately three-valued rather than a bool. "The UPI app handed control back" and "the
/// money moved" are different claims, and the gap between them is a real state a user can sit
/// in — a mandate that confirms after our poll window has run out. Collapsing that into
/// "failed" is what used to leave a paying user staring at an error on the paywall.
enum PaymentOutcome {
  success,
  pending,
  failed;

  /// The `:outcome` path segment. Round-trips with [parse].
  String get slug => name;

  /// Unknown values resolve to [pending], never to a terminal answer: an unrecognised slug is
  /// our bug, and the safe reading of "we do not know" is that the payment might still land.
  /// [pending] then polls and corrects itself, where [failed] would tell a paying user to pay
  /// again and [success] would let a non-payer through.
  static PaymentOutcome parse(String? value) => switch (value) {
        'success' => PaymentOutcome.success,
        'failed' => PaymentOutcome.failed,
        _ => PaymentOutcome.pending,
      };
}
