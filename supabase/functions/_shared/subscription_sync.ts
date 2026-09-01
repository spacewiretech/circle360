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
  cancelSubscription,
  CashfreeSettings,
  fetchSubscription,
  isLiveStatus,
  snapshotOf,
  SubscriptionSnapshot,
  WebhookPayment,
} from "./cashfree.ts";
import { asUserRow, USER_COLUMNS, UserRow } from "./entitlement.ts";

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
function userUpdatesFor(
  user: UserRow,
  snapshot: SubscriptionSnapshot,
  settings: CashfreeSettings,
): Record<string, unknown> {
  const updates: Record<string, unknown> = {};

  switch (snapshot.status) {
    case "ACTIVE": {
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
      break;
    }

    case "CANCELLED":
      // Paid time is honoured: current_period_end is deliberately left alone so the user keeps
      // what they already paid for.
      updates.payment_type = "cancelled";
      break;

    case "COMPLETED":
    case "EXPIRED":
      updates.payment_type = "expired";
      break;

    // ON_HOLD, PAUSED, INITIALIZED, PENDING_AUTHORIZATION and anything Cashfree adds later
    // need no user-level write. The dates simply stop advancing and entitlement lapses on its
    // own, which is the correct behaviour for every one of them.
    default:
      break;
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
 * Classifies a charge. The event type is trusted first because it is unambiguous; the amount
 * is the fallback for a redelivery whose type we could not read.
 */
export function paymentKind(
  eventType: string | null,
  amount: number | null,
  settings: CashfreeSettings,
): "AUTH" | "RECURRING" {
  if (eventType === "SUBSCRIPTION_AUTH_STATUS") return "AUTH";
  if (amount !== null && amount <= settings.trialAmount) return "AUTH";
  return "RECURRING";
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
  const kind = paymentKind(eventType, payment.amount, settings);

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

  await db.from("subscriptions").update({
    last_payment_at: payment.paymentTime,
    last_payment_status: payment.status,
    failure_reason: payment.failureReason,
  }).eq("id", subscription.id);

  if (kind !== "RECURRING" || payment.status !== "SUCCESS") return;

  const { data: user } = await db
    .from("users")
    .select(USER_COLUMNS)
    .eq("user_id", subscription.user_id)
    .maybeSingle();

  if (!user) return;

  await db
    .from("users")
    .update(updatesForRecurringSuccess(asUserRow(user), payment.paymentTime))
    .eq("user_id", subscription.user_id);
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
  if (snapshot.status === "CANCELLED") patch.cancelled_at = new Date().toISOString();

  const { error: writeError } = await db
    .from("subscriptions")
    .update(patch)
    .eq("id", row.id);

  if (writeError) {
    // The one-live-mandate index fired: this user already has a different ACTIVE row.
    if (writeError.code === UNIQUE_VIOLATION && depth === 0) {
      return await resolveDuplicateActive(db, settings, row, subscriptionId);
    }
    throw new Error(`subscriptions update failed: ${writeError.message}`);
  }

  const { data: userRow, error: userError } = await db
    .from("users")
    .select(USER_COLUMNS)
    .eq("user_id", row.user_id)
    .single();

  if (userError || !userRow) throw new Error(`user read failed: ${userError?.message}`);

  const user = asUserRow(userRow);
  const updates = userUpdatesFor(user, snapshot, settings);

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
      return await syncSubscription(db, settings, subscriptionId, 1);
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
  }

  return await syncSubscription(db, settings, subscriptionId, 1);
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
