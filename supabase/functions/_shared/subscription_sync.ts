/**
 * Reconciles one subscription against Cashfree and writes the result to `subscriptions` and
 * `users`. Every state transition in the system goes through here.
 *
 * The rule this module exists to enforce: **Cashfree is the authority, its webhook payloads are
 * only a hint.** A webhook tells us *that* something changed; this then asks Cashfree *what* the
 * state is now and writes that. So a duplicate delivery writes the same answer twice, an
 * out-of-order delivery still converges on the current truth, and a delivery we never received
 * is repaired by the next poll or the nightly sweep. None of those need their own code path.
 */

import { SupabaseClient } from "jsr:@supabase/supabase-js@2";

import {
  addMonths,
  cancelledBy,
  cancelSubscription,
  CashfreeSettings,
  fetchSubscription,
  fetchSubscriptionPayments,
  isCancelledStatus,
  isDisputeLost,
  isExpiredStatus,
  isLiveStatus,
  isPausedStatus,
  snapshotOf,
  SubscriptionSnapshot,
  WebhookDispute,
  WebhookPayment,
  WebhookRefund,
} from "./cashfree.ts";
import { asUserRow, USER_COLUMNS, UserRow } from "./entitlement.ts";
import { setProfile, trackServer } from "./mixpanel.ts";

export interface SubscriptionRow {
  id: string;
  user_id: string;
  subscription_id: string;
  cf_subscription_id: string | null;
  plan_id: string;
  status: string;
  session_id: string | null;
  session_expiry: string | null;
  authorized_at: string | null;
  next_schedule_date: string | null;
  current_period_end?: string | null;
}

export const SUBSCRIPTION_COLUMNS =
  "id, user_id, subscription_id, cf_subscription_id, plan_id, status, session_id, " +
  "session_expiry, authorized_at, next_schedule_date";

/** See [asUserRow] — supabase-js cannot infer a row type from a non-literal select string. */
export function asSubscriptionRow(row: unknown): SubscriptionRow {
  return row as SubscriptionRow;
}

/** Postgres unique-violation. Surfaces when two mandates race to become the live one. */
const UNIQUE_VIOLATION = "23505";

function laterOf(a: string | null, b: string | null): string | null {
  if (!a) return b;
  if (!b) return a;
  return new Date(a).getTime() >= new Date(b).getTime() ? a : b;
}

// ---------------------------------------------------------------- users

/**
 * Maps a Cashfree subscription state onto the `users` entitlement columns.
 *
 * Only ever moves state forward. `trial_ends_at` is set once and never extended, so a
 * reconcile that runs twice cannot hand out a second trial; `current_period_end` only ever
 * takes the later of the two values, so a redelivered older payment cannot claw back access.
 */
export function userUpdatesFor(
  user: UserRow,
  snapshot: SubscriptionSnapshot,
  settings: CashfreeSettings,
): Record<string, unknown> {
  const updates: Record<string, unknown> = {};

  // Written as if/else rather than a switch on the status word, because the states that matter
  // most here come in customer- and merchant-initiated pairs — `CUSTOMER_CANCELLED` alongside
  // `CANCELLED` — and a switch is exactly what let one half of each pair fall through to
  // `default:` and leave a cancelled account fully entitled.
  if (snapshot.status === "ACTIVE") {
    updates.active_subscription_id = snapshot.subscriptionId;

    // The trial clock starts at the instant Cashfree captured the ₹3, not at the instant we
    // heard about it — otherwise a webhook that took an hour to arrive gives an hour of free
    // trial, and the debit Cashfree scheduled would fire before our own date said it should.
    if (!user.trial_ends_at && snapshot.authorizedAt) {
      const endsAt = new Date(
        new Date(snapshot.authorizedAt).getTime() +
          settings.trialDays * 24 * 60 * 60 * 1000,
      );
      updates.trial_ends_at = endsAt.toISOString();
    }

    // An account that had lapsed and has now re-authorised goes back to trial-or-active
    // rather than staying expired. The recurring payment below is what promotes it further.
    if (user.payment_type === "expired" || user.payment_type === "cancelled") {
      updates.payment_type = user.current_period_end &&
          new Date(user.current_period_end).getTime() > Date.now()
        ? "active"
        : "trial";
    }
  } else if (isCancelledStatus(snapshot.status)) {
    // Paid time is honoured: current_period_end is deliberately left alone so the user keeps
    // what they already paid for.
    updates.payment_type = "cancelled";
  } else if (isExpiredStatus(snapshot.status)) {
    updates.payment_type = "expired";
  }

  // ON_HOLD, PAUSED, INITIALIZED, PENDING_AUTHORIZATION and anything Cashfree adds later need no
  // *entitlement* write. The dates simply stop advancing and access lapses on its own, which is
  // the correct behaviour for every one of them.

  // Mandate health, recorded separately from entitlement so it can be acted on before the
  // clock runs out. Previously ON_HOLD and PAUSED left no trace at all: a user whose UPI
  // mandate had stalled looked completely healthy right up to the moment they were locked out,
  // with nothing anywhere to prompt them to fix it.
  updates.billing_state = snapshot.status === "ON_HOLD"
    ? "on_hold"
    : isPausedStatus(snapshot.status)
    ? "paused"
    : null;

  // Dates worth having on the row rather than behind a join.
  if (snapshot.authorizedAt) {
    updates.trial_started_at = user.trial_started_at ?? snapshot.authorizedAt;
    updates.subscription_started_at = user.subscription_started_at ?? snapshot.authorizedAt;
  }
  updates.next_billing_at = snapshot.nextScheduleDate;
  if (isCancelledStatus(snapshot.status) && !user.cancelled_at) {
    updates.cancelled_at = new Date().toISOString();
  }

  return updates;
}

/** Promotes trial to active and rolls the paid period forward. Only called on a real debit. */
function updatesForRecurringSuccess(
  user: UserRow,
  paymentTime: string | null,
): Record<string, unknown> {
  const paidAt = paymentTime ? new Date(paymentTime) : new Date();
  const periodEnd = addMonths(paidAt, 1).toISOString();

  return {
    payment_type: "active",
    current_period_end: laterOf(user.current_period_end, periodEnd),
  };
}

// ---------------------------------------------------------------- payments

/**
 * A name for the transition, so reports do not have to pattern-match pairs of Cashfree strings.
 *
 * Only the transitions anyone would act on get a name; everything else is `other`, which is
 * deliberately still counted — an unnamed transition showing up in volume is how a status
 * Cashfree added after this was written gets noticed.
 */
export function transitionName(from: string, to: string): string {
  if (to === "ACTIVE" && from !== "ACTIVE") {
    return from === "ON_HOLD" || isPausedStatus(from) ? "recovered" : "activated";
  }
  if (to === "ON_HOLD") return "mandate_on_hold";
  if (isPausedStatus(to)) return "paused";
  if (isCancelledStatus(to)) return "cancelled";
  if (isExpiredStatus(to)) return "expired";
  return "other";
}

// ---------------------------------------------------------------- cancellation

/** Who ended the mandate, which is the property every churn report breaks down by. */
export type CancelInitiator = "customer" | "merchant" | "user_in_app" | "system";

export interface CancellationFacts {
  userId: string;
  subscriptionId: string;
  /**
   * `customer` is the UPI app; `user_in_app` is our own cancel screen; `merchant` is a cancel we
   * made on Cashfree's API for some other reason; `system` is housekeeping — a duplicate or
   * stale mandate the user never knew existed.
   */
  cancelledBy: CancelInitiator;
  /** Cashfree's own word, kept because `CUSTOMER_CANCELLED` and `CANCELLED` mean different things. */
  cfStatus?: string | null;
  fromStatus?: string | null;
  reason?: string | null;
  wasInTrial?: boolean | null;
  /** Paid time already bought. A cancellation is not a lapse: access usually runs on past it. */
  entitledUntil?: string | null;
  recurringAmount?: number | null;
  /** For `days_subscribed`, computed here so no report has to do date arithmetic. */
  startedAt?: string | null;
}

/**
 * The event `Subscription Status Changed` was never going to answer on its own.
 *
 * Four separate places end a mandate — this module's sync, the duplicate-mandate resolver,
 * `subscription-start`'s stale-mandate cleanup and the `subscription-cancel` endpoint — and
 * before this only the first of them emitted anything at all, under a name that said nothing
 * about churn.
 *
 * `$insert_id` is `cancel:<subscription id>` with no time bucket, which is the whole point: a
 * subscription is cancelled exactly once, so the webhook, the reconcile sweep that replays it an
 * hour later and the endpoint that requested it all collapse onto one event in Mixpanel. Without
 * that, the reconcile alone would re-report every cancellation it ever swept.
 */
export async function trackCancellation(facts: CancellationFacts): Promise<void> {
  const started = facts.startedAt ? new Date(facts.startedAt).getTime() : null;
  const daysSubscribed = started !== null && Number.isFinite(started)
    ? Math.max(0, Math.floor((Date.now() - started) / 86_400_000))
    : null;

  await trackServer({
    event: "Subscription Cancelled",
    distinctId: facts.userId,
    insertId: `cancel:${facts.subscriptionId}`,
    properties: {
      subscription_id: facts.subscriptionId,
      cancelled_by: facts.cancelledBy,
      cf_status: facts.cfStatus ?? null,
      from_status: facts.fromStatus ?? null,
      reason: facts.reason ?? null,
      was_in_trial: facts.wasInTrial ?? null,
      entitled_until: facts.entitledUntil ?? null,
      recurring_amount: facts.recurringAmount ?? null,
      days_subscribed: daysSubscribed,
    },
  });
}

export type PaymentKind = "AUTH" | "RECURRING" | "UNKNOWN";

/**
 * Classifies a charge, most trustworthy signal first: Cashfree's own label, then the event
 * type, then the amount.
 *
 * Returns UNKNOWN rather than guessing when none of them can be read. RECURRING used to be the
 * fallback, which meant a SUCCESS payload whose type and amount both failed to parse credited
 * the user a paid month they had not been billed for.
 */
export function paymentKind(
  eventType: string | null,
  amount: number | null,
  settings: CashfreeSettings,
  kindHint: string | null = null,
): PaymentKind {
  if (kindHint === "AUTH" || kindHint === "RECURRING") return kindHint;
  if (eventType === "SUBSCRIPTION_AUTH_STATUS") return "AUTH";
  if (amount !== null && amount <= settings.trialAmount) return "AUTH";
  if (amount !== null) return "RECURRING";
  return "UNKNOWN";
}

/**
 * Records a charge attempt and, when it is a successful recurring debit, moves the user to
 * `active`. Idempotent on `cf_payment_id`, which is the only guard that actually matters:
 * everything else can be replayed, but crediting a month twice cannot.
 */
export async function recordPayment(
  db: SupabaseClient,
  settings: CashfreeSettings,
  subscription: SubscriptionRow,
  payment: WebhookPayment,
  eventType: string | null,
): Promise<void> {
  const kind = paymentKind(eventType, payment.amount, settings, payment.kindHint);

  // Read before the upsert: the upsert itself cannot say whether this charge was already
  // known, and "already known and already SUCCESS" is the only thing standing between a
  // redelivered webhook and a second free month.
  const { data: prior } = await db
    .from("subscription_payments")
    .select("status, payment_time, created_at")
    .eq("cf_payment_id", payment.cfPaymentId)
    .maybeSingle();

  const alreadyCredited = prior?.status === "SUCCESS";

  const { error } = await db.from("subscription_payments").upsert({
    subscription_pk: subscription.id,
    user_id: subscription.user_id,
    cf_payment_id: payment.cfPaymentId,
    kind,
    amount: payment.amount,
    currency: payment.currency,
    status: payment.status,
    payment_time: payment.paymentTime,
    failure_reason: payment.failureReason,
    raw: payment.raw,
  }, { onConflict: "cf_payment_id" });

  if (error) throw new Error(`subscription_payments upsert failed: ${error.message}`);

  // Every charge attempt, successful or not. A failed renewal is the single most actionable
  // event this system produces — it is the moment a paying customer starts silently churning —
  // and until now it existed only as a column nobody was watching.
  const failed = isFailedCharge(payment.status);
  await trackServer({
    event: failed
      ? "Subscription Payment Failed"
      : payment.status === "SUCCESS"
      ? (kind === "AUTH" ? "Mandate Authorised" : "Subscription Renewed")
      : "Subscription Payment Pending",
    distinctId: subscription.user_id,
    // Keyed on the charge and its status, not on the delivery: Cashfree redelivers the same
    // payment webhook freely and the reconcile sweep replays it hourly. Without this one
    // renewal would be counted every hour, for a month.
    insertId: `pay:${payment.cfPaymentId}:${payment.status}`,
    time: payment.paymentTime,
    properties: {
      cf_event_type: eventType,
      cf_payment_id: payment.cfPaymentId,
      subscription_id: subscription.subscription_id,
      kind,
      amount: payment.amount,
      currency: payment.currency,
      payment_status: payment.status,
      failure_reason: payment.failureReason,
      // True when this charge had already been credited — so a redelivery that changed nothing
      // is distinguishable from a genuine first-time renewal even before Mixpanel dedupes.
      already_credited: alreadyCredited,
      trigger: eventType ?? "reconcile",
    },
  });

  await db.from("subscriptions").update({
    last_payment_at: payment.paymentTime,
    last_payment_status: payment.status,
    failure_reason: payment.failureReason,
  }).eq("id", subscription.id);

  // Reporting columns follow every attempt, including the failures — a declined renewal is
  // exactly what someone looking at this row needs to see.
  await refreshPaymentTotals(db, subscription.user_id);

  // UNKNOWN never credits: it means we could not tell an authorisation from a renewal, and
  // guessing in the user's favour is how an unreadable payload becomes a free month.
  if (kind !== "RECURRING" || payment.status !== "SUCCESS") return;

  // A charge that has already been counted must not be counted again. Without this, a webhook
  // whose first attempt failed after the upsert — or any redelivery Cashfree retries — pushed
  // current_period_end another month forward every time it ran.
  if (alreadyCredited) return;

  const { data: user } = await db
    .from("users")
    .select(USER_COLUMNS)
    .eq("user_id", subscription.user_id)
    .maybeSingle();

  if (!user) return;

  // Anchored to when the money actually moved. Falling back to "now" on a payload with no
  // payment_time is only safe because the guard above means this runs at most once per charge.
  const paidAt = payment.paymentTime ??
    (prior?.payment_time as string | null) ??
    (prior?.created_at as string | null);

  const updates = updatesForRecurringSuccess(asUserRow(user), paidAt);
  await db
    .from("users")
    .update(updates)
    .eq("user_id", subscription.user_id);

  // The profile has to move too, or a segment like "active subscribers" is stale until the user
  // next opens the app — which for a happily-renewing customer might be never.
  await setProfile(subscription.user_id, {
    payment_type: updates.payment_type,
    current_period_end: updates.current_period_end,
    entitled: true,
    in_trial: false,
    has_ever_subscribed: true,
    last_payment_at: payment.paymentTime,
    last_payment_status: payment.status,
  });
}

/**
 * Recomputes the denormalised payment columns on `users` from the ledger.
 *
 * Recompute rather than increment. An increment has to be applied exactly once, which means
 * every caller has to know whether it is replaying history or seeing something new — and the
 * reconcile sweep, whose whole job is replaying history, would inflate the totals every hour.
 * Recomputing is idempotent by construction, so it is safe from anywhere and repairs drift
 * rather than adding to it.
 *
 * Best-effort: these columns are reporting, not entitlement. A failure here must never abort
 * the charge handling it hangs off.
 */
/**
 * Whether a charge actually failed, as opposed to not having happened yet.
 *
 * An allowlist, not "anything that is not SUCCESS". Cashfree reports several non-terminal
 * states — INITIALIZED for a debit it has merely scheduled, PENDING and BANK_APPROVAL_PENDING
 * while one settles — and counting those as failures told a user their payment had been
 * declined when it had not yet been attempted. An unrecognised status is likewise not called a
 * failure: being wrong in that direction is the one that alarms people over nothing.
 */
export function isFailedCharge(status: string): boolean {
  return ["FAILED", "CANCELLED", "DROPPED", "USER_DROPPED", "VOID", "EXPIRED"]
    .includes((status ?? "").toUpperCase());
}

export async function refreshPaymentTotals(
  db: SupabaseClient,
  userId: string,
): Promise<void> {
  try {
    const { data: rows } = await db
      .from("subscription_payments")
      .select("kind, amount, status, payment_time, created_at")
      .eq("user_id", userId);

    if (!rows) return;

    // Refunded money is not money the user paid, so it comes back off the total.
    const { data: refunds } = await db
      .from("subscription_refunds")
      .select("amount, status")
      .eq("user_id", userId);

    const succeeded = rows.filter((r) => r.status === "SUCCESS");
    const recurring = succeeded.filter((r) => r.kind === "RECURRING");
    const times = recurring
      .map((r) => (r.payment_time ?? r.created_at) as string | null)
      .filter((t): t is string => t !== null)
      .sort();

    const paid = succeeded.reduce((sum, r) => sum + Number(r.amount ?? 0), 0);
    const refunded = (refunds ?? [])
      .filter((r) => r.status === "SUCCESS")
      .reduce((sum, r) => sum + Number(r.amount ?? 0), 0);

    // The most recent attempt of any kind, successful or not — "did my payment go through"
    // is a question about the last thing that happened, not the last thing that worked.
    const latest = rows
      .slice()
      .sort((a, b) =>
        new Date((b.payment_time ?? b.created_at) as string).getTime() -
        new Date((a.payment_time ?? a.created_at) as string).getTime()
      )[0];

    await db.from("users").update({
      successful_charge_count: recurring.length,
      failed_charge_count: rows.filter((r) => isFailedCharge(r.status as string)).length,
      total_paid_amount: Math.max(0, paid - refunded),
      first_paid_at: times[0] ?? null,
      last_payment_at: latest ? (latest.payment_time ?? latest.created_at) : null,
      last_payment_amount: latest?.amount ?? null,
      last_payment_status: latest?.status ?? null,
    }).eq("user_id", userId);
  } catch (error) {
    console.error(`could not refresh payment totals for ${userId}: ${error}`);
  }
}

/**
 * Replays any charge Cashfree has on record that our ledger is missing.
 *
 * The webhook is otherwise the only way a debit is ever recorded, so a webhook that was never
 * delivered — an endpoint not yet registered, an outage, a signature mismatch — looks exactly
 * like a charge that never happened, and the user is billed and then locked out anyway. This is
 * what makes that recoverable. Idempotent: [recordPayment] ignores charges already counted.
 *
 * Best-effort. A payments endpoint that is unreachable or has changed shape must not take down
 * the status sync it hangs off.
 */
export async function reconcilePayments(
  db: SupabaseClient,
  settings: CashfreeSettings,
  subscription: SubscriptionRow,
): Promise<void> {
  let payments: WebhookPayment[];
  try {
    payments = await fetchSubscriptionPayments(settings, subscription.subscription_id);
  } catch (error) {
    console.error(`could not list payments for ${subscription.subscription_id}: ${error}`);
    return;
  }

  // Oldest first, so a month is credited from the earliest debit forward and `laterOf` in
  // updatesForRecurringSuccess never has to walk backwards.
  payments.sort((a, b) =>
    new Date(a.paymentTime ?? 0).getTime() - new Date(b.paymentTime ?? 0).getTime()
  );

  for (const payment of payments) {
    try {
      await recordPayment(db, settings, subscription, payment, null);
    } catch (error) {
      console.error(`could not record payment ${payment.cfPaymentId}: ${error}`);
    }
  }
}

// ---------------------------------------------------------------- sync

export interface SyncResult {
  snapshot: SubscriptionSnapshot;
  subscription: SubscriptionRow;
  user: UserRow;
}

/**
 * Fetches the live state from Cashfree and writes it through to both tables.
 *
 * [depth] guards the one recursive path below, where a stale local ACTIVE row is re-checked
 * before we conclude that two mandates are genuinely live at once.
 */
export async function syncSubscription(
  db: SupabaseClient,
  settings: CashfreeSettings,
  subscriptionId: string,
  depth = 0,
  withPayments = false,
): Promise<SyncResult> {
  const cf = await fetchSubscription(settings, subscriptionId);
  const snapshot = snapshotOf(cf);

  const { data: existing, error: readError } = await db
    .from("subscriptions")
    .select(SUBSCRIPTION_COLUMNS)
    .eq("subscription_id", subscriptionId)
    .maybeSingle();

  if (readError) throw new Error(`subscriptions read failed: ${readError.message}`);
  if (!existing) {
    // Cashfree knows about a subscription we do not. That means our create call succeeded and
    // the row write did not, so there is a real mandate with no local owner — loud, not silent.
    throw new Error(`no local row for subscription ${subscriptionId}`);
  }

  const row = asSubscriptionRow(existing);

  const patch: Record<string, unknown> = {
    cf_subscription_id: snapshot.cfSubscriptionId ?? row.cf_subscription_id,
    status: snapshot.status,
    authorization_amount: snapshot.authorizationAmount,
    recurring_amount: snapshot.recurringAmount,
    first_charge_time: snapshot.firstChargeTime,
    next_schedule_date: snapshot.nextScheduleDate,
    authorized_at: snapshot.authorizedAt ?? row.authorized_at,
    raw: snapshot.raw,
  };
  if (isCancelledStatus(snapshot.status)) patch.cancelled_at = new Date().toISOString();

  const { error: writeError } = await db
    .from("subscriptions")
    .update(patch)
    .eq("id", row.id);

  if (writeError) {
    // The one-live-mandate index fired: this user already has a different ACTIVE row.
    if (writeError.code === UNIQUE_VIOLATION && depth === 0) {
      return await resolveDuplicateActive(db, settings, row, subscriptionId, withPayments);
    }
    throw new Error(`subscriptions update failed: ${writeError.message}`);
  }

  // Before the user is read, so a debit recovered here is already reflected in the row that
  // userUpdatesFor then reasons about.
  if (withPayments) {
    await reconcilePayments(db, settings, { ...row, ...patch } as SubscriptionRow);
  }

  const { data: userRow, error: userError } = await db
    .from("users")
    .select(USER_COLUMNS)
    .eq("user_id", row.user_id)
    .single();

  if (userError || !userRow) throw new Error(`user read failed: ${userError?.message}`);

  const user = asUserRow(userRow);
  const updates = userUpdatesFor(user, snapshot, settings);

  // Only when Cashfree disagrees with what we had. After the write above the two match, so the
  // hourly reconcile sweep replaying the same subscription emits nothing — the local row is the
  // natural dedupe, and a genuine flip back to ON_HOLD later is correctly counted again.
  if (row.status !== snapshot.status) {
    await trackServer({
      event: "Subscription Status Changed",
      distinctId: row.user_id,
      // Bucketed to the minute so a burst of webhook retries that all failed before the write
      // above collapses into one event rather than one per attempt.
      insertId: `sub:${subscriptionId}:${row.status}:${snapshot.status}:` +
        `${Math.floor(Date.now() / 60_000)}`,
      properties: {
        subscription_id: subscriptionId,
        from_status: row.status,
        to_status: snapshot.status,
        // The named transitions worth alerting on, pre-computed so nobody has to reconstruct
        // them from a pair of strings in every report.
        transition: transitionName(row.status, snapshot.status),
        billing_state: updates.billing_state ?? null,
        payment_type: updates.payment_type ?? user.payment_type,
        recurring_amount: snapshot.recurringAmount,
        next_billing_at: snapshot.nextScheduleDate,
        authorized_at: snapshot.authorizedAt,
      },
    });

    // The one transition that ends the relationship gets its own event as well as the generic
    // one. Not a duplicate: `Subscription Status Changed` is what makes every transition
    // countable in one place, and a churn report should not have to know that a cancellation is
    // spelled as a property of it — nor that it arrives under two different Cashfree words.
    if (isCancelledStatus(snapshot.status)) {
      await trackCancellation({
        userId: row.user_id,
        subscriptionId,
        cancelledBy: cancelledBy(snapshot.status),
        cfStatus: snapshot.status,
        fromStatus: row.status,
        wasInTrial: user.payment_type === "trial",
        entitledUntil: user.current_period_end,
        recurringAmount: snapshot.recurringAmount,
        startedAt: user.subscription_started_at ?? snapshot.authorizedAt,
      });
    }

    await setProfile(row.user_id, {
      subscription_status: snapshot.status,
      billing_state: updates.billing_state ?? null,
      next_billing_at: snapshot.nextScheduleDate,
      ...(updates.payment_type ? { payment_type: updates.payment_type } : {}),
      ...(isCancelledStatus(snapshot.status)
        ? {
          cancelled_at: updates.cancelled_at ?? user.cancelled_at,
          cancelled_by: cancelledBy(snapshot.status),
        }
        : {}),
    });
  }

  if (Object.keys(updates).length > 0) {
    const { error } = await db.from("users").update(updates).eq("user_id", user.user_id);
    if (error) throw new Error(`users update failed: ${error.message}`);
    Object.assign(user, updates);
  }

  return { snapshot, subscription: { ...row, ...patch } as SubscriptionRow, user };
}

/**
 * Two mandates cannot both be live for one user, or the account is billed ₹499 twice a month.
 *
 * The incumbent is checked against Cashfree first, because the common cause is simply a stale
 * local row — a mandate that Cashfree cancelled while a webhook went missing. Only when the
 * incumbent really is still active do we cancel the newcomer, keeping the one the user's
 * entitlement already points at. Its authorisation amount becomes a manual refund.
 */
async function resolveDuplicateActive(
  db: SupabaseClient,
  settings: CashfreeSettings,
  row: SubscriptionRow,
  subscriptionId: string,
  withPayments: boolean,
): Promise<SyncResult> {
  // limit(1), not maybeSingle() alone: the partial unique index should make more than one
  // impossible, but this is the recovery path for exactly the case where an invariant broke.
  const { data: incumbent } = await db
    .from("subscriptions")
    .select(SUBSCRIPTION_COLUMNS)
    .eq("user_id", row.user_id)
    .eq("status", "ACTIVE")
    .neq("id", row.id)
    .order("created_at", { ascending: true })
    .limit(1)
    .maybeSingle();

  if (incumbent) {
    const other = asSubscriptionRow(incumbent);
    const refreshed = snapshotOf(await fetchSubscription(settings, other.subscription_id));

    if (refreshed.status !== "ACTIVE") {
      // Stale row. Correct it and let the original sync proceed.
      await db
        .from("subscriptions")
        .update({ status: refreshed.status, raw: refreshed.raw })
        .eq("id", other.id);
      return await syncSubscription(db, settings, subscriptionId, 1, withPayments);
    }

    console.error(
      `duplicate live mandate for user ${row.user_id}: keeping ${other.subscription_id}, ` +
        `cancelling ${subscriptionId} — its authorisation amount needs a manual refund`,
    );

    try {
      await cancelSubscription(settings, subscriptionId);
    } catch (error) {
      console.error(`could not cancel duplicate ${subscriptionId}: ${error}`);
    }

    await db
      .from("subscriptions")
      .update({
        status: "CANCELLED",
        cancelled_at: new Date().toISOString(),
        failure_reason: `duplicate of ${other.subscription_id}`,
      })
      .eq("id", row.id);

    // A real cancellation of a real mandate, and one the user never asked for. It leaves an
    // authorisation amount needing a manual refund, so it has to be countable rather than only
    // sitting in a log line — a run of these is a bug in checkout, not routine housekeeping.
    await trackCancellation({
      userId: row.user_id,
      subscriptionId,
      cancelledBy: "system",
      cfStatus: "CANCELLED",
      fromStatus: row.status,
      reason: "duplicate_mandate",
    });
  }

  return await syncSubscription(db, settings, subscriptionId, 1, withPayments);
}

/** The user's most recent mandate attempt, live or not. Null for a user who never started one. */
export async function latestSubscription(
  db: SupabaseClient,
  userId: string,
): Promise<SubscriptionRow | null> {
  const { data } = await db
    .from("subscriptions")
    .select(SUBSCRIPTION_COLUMNS)
    .eq("user_id", userId)
    .order("created_at", { ascending: false })
    .limit(1)
    .maybeSingle();

  return data === null ? null : asSubscriptionRow(data);
}

/** A pending checkout whose session token is still usable, so a retry can resume it. */
export function isResumable(row: SubscriptionRow): boolean {
  if (!row.session_id || !row.session_expiry) return false;
  if (!isLiveStatus(row.status) || row.status === "ACTIVE") return false;
  return new Date(row.session_expiry).getTime() > Date.now();
}

// ---------------------------------------------------------------- refunds & disputes

/**
 * Finds the subscription a payment-scoped event belongs to.
 *
 * Refunds and disputes name a *payment*, never a subscription, which is why they used to be
 * recorded and then dropped. The ledger already ties every charge to its mandate, so the link
 * is one lookup away.
 */
export async function subscriptionForPayment(
  db: SupabaseClient,
  cfPaymentId: string,
): Promise<{ subscriptionPk: string | null; userId: string | null } | null> {
  const { data } = await db
    .from("subscription_payments")
    .select("id, subscription_pk, user_id")
    .eq("cf_payment_id", cfPaymentId)
    .maybeSingle();

  if (!data) return null;
  return {
    subscriptionPk: (data.subscription_pk as string | null) ?? null,
    userId: (data.user_id as string | null) ?? null,
  };
}

/**
 * Records a refund and, when money actually went back, re-derives the paid period.
 *
 * Recomputed from the remaining un-refunded charges rather than subtracting a month. Subtraction
 * has to be applied exactly once and cannot survive a redelivery or an out-of-order arrival;
 * recomputation converges on the same answer however many times it runs, which is the same rule
 * the rest of this module follows.
 */
export async function recordRefund(
  db: SupabaseClient,
  refund: WebhookRefund,
): Promise<void> {
  const link = refund.cfPaymentId
    ? await subscriptionForPayment(db, refund.cfPaymentId)
    : null;

  const { error } = await db.from("subscription_refunds").upsert({
    payment_pk: link?.subscriptionPk ?? null,
    user_id: link?.userId ?? null,
    cf_refund_id: refund.cfRefundId,
    cf_payment_id: refund.cfPaymentId,
    amount: refund.amount,
    currency: refund.currency,
    status: refund.status,
    reason: refund.reason,
    refund_time: refund.refundTime,
    raw: refund.raw,
  }, { onConflict: "cf_refund_id" });

  if (error) throw new Error(`subscription_refunds upsert failed: ${error.message}`);

  const userId = link?.userId;

  await trackServer({
    event: "Refund Recorded",
    distinctId: userId ?? null,
    insertId: `refund:${refund.cfRefundId}:${refund.status}`,
    time: refund.refundTime,
    properties: {
      cf_refund_id: refund.cfRefundId,
      cf_payment_id: refund.cfPaymentId,
      amount: refund.amount,
      currency: refund.currency,
      refund_status: refund.status,
      refund_reason: refund.reason,
      // A refund we cannot tie to a subscription still needs counting — it usually means the
      // charge it reverses was never recorded, which is a reconciliation gap worth seeing.
      attributed: Boolean(userId),
    },
  });

  if (!userId || refund.status !== "SUCCESS") return;

  await recomputePaidPeriod(db, userId);
  await refreshPaymentTotals(db, userId);
}

/**
 * Re-derives `current_period_end` from the charges that still stand.
 *
 * A month of access is owed for each successful recurring charge that has not been refunded,
 * measured from the most recent one. With none left the user keeps whatever the trial gave them
 * and lapses on that clock instead.
 */
async function recomputePaidPeriod(db: SupabaseClient, userId: string): Promise<void> {
  const { data: refunded } = await db
    .from("subscription_refunds")
    .select("cf_payment_id")
    .eq("user_id", userId)
    .eq("status", "SUCCESS");

  const reversed = new Set(
    (refunded ?? []).map((r) => r.cf_payment_id as string).filter(Boolean),
  );

  const { data: charges } = await db
    .from("subscription_payments")
    .select("cf_payment_id, payment_time, created_at")
    .eq("user_id", userId)
    .eq("kind", "RECURRING")
    .eq("status", "SUCCESS");

  const standing = (charges ?? [])
    .filter((c) => !reversed.has(c.cf_payment_id as string))
    .map((c) => (c.payment_time ?? c.created_at) as string)
    .filter(Boolean)
    .sort();

  const latest = standing.at(-1);

  if (!latest) {
    // Every paid month has been given back. Fall back to the trial clock rather than leaving a
    // period end nothing paid for; `expired` is not set here because the trial may still run.
    await db.from("users").update({ current_period_end: null }).eq("user_id", userId);
    return;
  }

  await db
    .from("users")
    .update({ current_period_end: addMonths(new Date(latest), 1).toISOString() })
    .eq("user_id", userId);
}

/**
 * Records a chargeback. Access is taken away only once one is actually lost.
 *
 * An opened dispute is usually a bank's automated query and is often resolved in the merchant's
 * favour; revoking on creation would punish the user for it. Until it settles the account is
 * flagged through `billing_state` and nothing else changes.
 */
export async function recordDispute(
  db: SupabaseClient,
  dispute: WebhookDispute,
): Promise<void> {
  const link = dispute.cfPaymentId
    ? await subscriptionForPayment(db, dispute.cfPaymentId)
    : null;

  const { error } = await db.from("payment_disputes").upsert({
    user_id: link?.userId ?? null,
    cf_dispute_id: dispute.cfDisputeId,
    cf_payment_id: dispute.cfPaymentId,
    amount: dispute.amount,
    currency: dispute.currency,
    status: dispute.status,
    dispute_type: dispute.disputeType,
    reason: dispute.reason,
    respond_by: dispute.respondBy,
    raw: dispute.raw,
  }, { onConflict: "cf_dispute_id" });

  if (error) throw new Error(`payment_disputes upsert failed: ${error.message}`);

  const userId = link?.userId;

  await trackServer({
    event: "Dispute Recorded",
    distinctId: userId ?? null,
    insertId: `dispute:${dispute.cfDisputeId}:${dispute.status}`,
    properties: {
      cf_dispute_id: dispute.cfDisputeId,
      cf_payment_id: dispute.cfPaymentId,
      amount: dispute.amount,
      currency: dispute.currency,
      dispute_status: dispute.status,
      dispute_type: dispute.disputeType,
      dispute_reason: dispute.reason,
      respond_by: dispute.respondBy,
      lost: isDisputeLost(dispute.status),
      attributed: Boolean(userId),
    },
  });

  if (!userId) return;

  if (isDisputeLost(dispute.status)) {
    // The money is gone, so the month it bought is gone with it.
    await db.from("users").update({ billing_state: "disputed" }).eq("user_id", userId);
    await recomputePaidPeriod(db, userId);
    await setProfile(userId, { billing_state: "disputed" });
    return;
  }

  // Still open, or resolved our way. Flag while open; clear the flag once it closes.
  const open = !dispute.status.toUpperCase().includes("WON") &&
    !dispute.status.toUpperCase().includes("CLOSED");

  await db
    .from("users")
    .update({ billing_state: open ? "disputed" : null })
    .eq("user_id", userId);

  await setProfile(userId, { billing_state: open ? "disputed" : null });
}
