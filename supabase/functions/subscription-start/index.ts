import {
  addDays,
  cancelSubscription,
  CashfreeError,
  cashfreeSettings,
  createSubscription,
  snapshotOf,
} from "../_shared/cashfree.ts";
import { loadConfig } from "../_shared/config.ts";
import { fail, json, preflight } from "../_shared/cors.ts";
import { serviceClient, userIdForBearer } from "../_shared/db.ts";
import {
  asUserRow,
  entitlementPayload,
  graceHoursFrom,
  isEntitled,
  USER_COLUMNS,
} from "../_shared/entitlement.ts";
import { isResumable, latestSubscription } from "../_shared/subscription_sync.ts";

/**
 * Opens a Cashfree UPI Autopay mandate: ₹3 now, then ₹499/month starting after the trial.
 *
 * The request body is empty by design. The plan, both amounts and the trial length all come
 * from `app_config`, so there is no parameter a modified client could send to pay less. The
 * only thing the caller supplies is its session token, and the user id is derived from that.
 */

/** Cashfree allows alphanumerics, underscore, dot, hyphen and space, up to 250 characters. */
function newSubscriptionId(userId: string): string {
  return `c360_${userId.replace(/-/g, "")}_${Math.floor(Date.now() / 1000)}`;
}

/** Cashfree requires an email. Nobody reads this one — the notices go out over SMS. */
function syntheticEmail(mobile: string): string {
  return `${mobile}@circle360.app`;
}

/** How long the checkout token stays usable before a retry has to mint a fresh mandate. */
const SESSION_MINUTES = 15;

/** A sane ceiling on mandate attempts per hour, so a retry loop cannot hammer Cashfree. */
const MAX_ATTEMPTS_PER_HOUR = 10;

Deno.serve(async (req) => {
  const cors = preflight(req);
  if (cors) return cors;

  const db = serviceClient();
  const userId = await userIdForBearer(db, req.headers.get("Authorization"));
  if (!userId) return fail("unauthorized", "Please sign in again.", 401);

  const config = await loadConfig(db);
  const graceHours = graceHoursFrom(config);

  let settings;
  try {
    settings = cashfreeSettings(config);
  } catch (error) {
    // Missing credentials are a deployment problem, not something the user can act on.
    console.error("cashfree settings unavailable", error);
    return fail("payment_failed", "Payments are temporarily unavailable.", 503);
  }

  const { data: userRow, error: userError } = await db
    .from("users")
    .select(USER_COLUMNS)
    .eq("user_id", userId)
    .single();

  if (userError || !userRow) {
    console.error("subscription-start user lookup failed", userError);
    return fail("server_error", "Something went wrong. Please try again.", 500);
  }

  const user = asUserRow(userRow);

  // Charging someone who is already inside their trial or their paid month is the one mistake
  // that is genuinely hard to undo, so it is checked before anything else touches Cashfree.
  if (isEntitled(user, graceHours)) {
    return json({
      status: "entitled",
      user: entitlementPayload(user, graceHours),
    });
  }

  if (!user.name || !user.name.trim()) {
    return fail("invalid_request", "Please add your name before subscribing.", 400);
  }

  // Resume rather than duplicate: a double tap, or a checkout the user backgrounded and came
  // back to, must reuse the mandate it already opened.
  const existing = await latestSubscription(db, userId);
  if (existing && isResumable(existing)) {
    return json({
      status: "pending",
      subscription_id: existing.subscription_id,
      subscription_session_id: existing.session_id,
      cf_subscription_id: existing.cf_subscription_id,
      environment: settings.env,
    });
  }

  const hourAgo = new Date(Date.now() - 60 * 60 * 1000).toISOString();
  const { count } = await db
    .from("subscriptions")
    .select("id", { count: "exact", head: true })
    .eq("user_id", userId)
    .gte("created_at", hourAgo);

  if ((count ?? 0) >= MAX_ATTEMPTS_PER_HOUR) {
    return fail("throttled", "Too many attempts. Please try again in a little while.", 429);
  }

  // Anything still open is dead now: a new mandate is about to replace it.
  if (existing && ["INITIALIZED", "PENDING_AUTHORIZATION"].includes(existing.status)) {
    await db
      .from("subscriptions")
      .update({ status: "ABANDONED" })
      .eq("id", existing.id);
  }

  // A mandate that is still live at Cashfree while the user is not entitled is a mandate whose
  // debits are failing. It has to be cancelled *before* the replacement is created, not cleaned
  // up afterwards: leaving it would either trip the one-live-mandate index — losing the new
  // mandate the user just paid ₹3 for, in favour of the broken one — or, worse, leave two UPI
  // mandates both authorised to take ₹499 a month.
  if (existing && ["ACTIVE", "ON_HOLD", "PAUSED"].includes(existing.status)) {
    try {
      await cancelSubscription(settings, existing.subscription_id);
    } catch (error) {
      // Already cancelled at Cashfree, or unreachable. Recording it locally still keeps the
      // index clear; the reconcile sweep will correct the status if this was wrong.
      console.error(`could not cancel stale mandate ${existing.subscription_id}`, error);
    }

    await db
      .from("subscriptions")
      .update({
        status: "CANCELLED",
        cancelled_at: new Date().toISOString(),
        failure_reason: "replaced by a new mandate",
      })
      .eq("id", existing.id);
  }

  const now = new Date();
  const subscriptionId = newSubscriptionId(userId);
  const firstChargeTime = addDays(now, settings.trialDays);
  const sessionExpiry = new Date(now.getTime() + SESSION_MINUTES * 60 * 1000);

  // The local row is written first. If Cashfree then succeeds but our follow-up write fails,
  // there is still a row naming the mandate — an orphaned mandate with no local owner is the
  // one failure mode that cannot be reconciled later.
  const { data: created, error: insertError } = await db
    .from("subscriptions")
    .insert({
      user_id: userId,
      subscription_id: subscriptionId,
      plan_id: settings.planId,
      status: "INITIALIZED",
      authorization_amount: settings.trialAmount,
      recurring_amount: settings.recurringAmount,
      first_charge_time: firstChargeTime.toISOString(),
      session_expiry: sessionExpiry.toISOString(),
    })
    .select("id")
    .single();

  if (insertError || !created) {
    console.error("subscription insert failed", insertError);
    return fail("server_error", "Something went wrong. Please try again.", 500);
  }

  let response: Record<string, unknown>;
  try {
    response = await createSubscription(settings, {
      subscriptionId,
      customerName: user.name.trim(),
      customerPhone: user.mobile_no,
      customerEmail: syntheticEmail(user.mobile_no),
      firstChargeTime,
      sessionExpiry,
      // The SDK returns control through its own callback; this only matters for the web
      // fallback. The matching intent filter is registered so the redirect resolves rather
      // than dead-ending on "no app can handle this link".
      returnUrl: `loc360://payment?sub=${subscriptionId}`,
    });
  } catch (error) {
    const detail = error instanceof CashfreeError ? error.detail : String(error);
    console.error("cashfree create subscription failed", detail);

    await db
      .from("subscriptions")
      .update({ status: "FAILED_TO_CREATE", failure_reason: detail.slice(0, 500) })
      .eq("id", created.id);

    return fail(
      "payment_failed",
      error instanceof CashfreeError ? error.userMessage : "Could not start the payment.",
      502,
    );
  }

  const snapshot = snapshotOf(response);

  if (!snapshot.sessionId) {
    console.error("cashfree returned no subscription_session_id", response);
    await db
      .from("subscriptions")
      .update({ status: "FAILED_TO_CREATE", failure_reason: "no session id", raw: response })
      .eq("id", created.id);
    return fail("payment_failed", "Could not start the payment. Please try again.", 502);
  }

  await db
    .from("subscriptions")
    .update({
      cf_subscription_id: snapshot.cfSubscriptionId,
      status: snapshot.status,
      session_id: snapshot.sessionId,
      raw: snapshot.raw,
    })
    .eq("id", created.id);

  return json({
    status: "pending",
    subscription_id: subscriptionId,
    subscription_session_id: snapshot.sessionId,
    cf_subscription_id: snapshot.cfSubscriptionId,
    environment: settings.env,
    // Display only. The amounts that are actually charged live in the Cashfree plan.
    trial_amount: settings.trialAmount,
    recurring_amount: settings.recurringAmount,
    trial_days: settings.trialDays,
  });
});
