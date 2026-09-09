import {
  addDays,
  addMonths,
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
  hasUsedTrial,
  isEntitled,
  USER_COLUMNS,
} from "../_shared/entitlement.ts";
import { configureMixpanel } from "../_shared/mixpanel.ts";
import {
  isResumable,
  latestSubscription,
  trackCancellation,
} from "../_shared/subscription_sync.ts";

/**
 * Opens a Cashfree UPI Autopay mandate, in one of two shapes.
 *
 * A first-time subscriber gets the trial offer: ₹3 now, then ₹499/month starting after the trial
 * days. Someone whose trial is already spent — lapsed, cancelled, or returning after either —
 * gets the plain monthly plan: ₹499 now, then ₹499/month starting a month out.
 *
 * That second shape is the whole point of this branch. It used to not exist: the mandate was
 * built one way for everybody, so a returning user read "Subscribe · ₹499/month" on the paywall,
 * tapped it, and was shown a ₹3 debit in their UPI app. The paywall was right and the mandate was
 * wrong, because trial eligibility lived only on the client and this function had no notion of it.
 *
 * The request body is still empty by design. The plan, both amounts and the trial length come
 * from `app_config`, and eligibility comes from the caller's own `users` row — so there is no
 * parameter a modified client could send to pay less. The only thing the caller supplies is its
 * session token, and the user id is derived from that.
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
  // The stale-mandate cleanup below cancels a real UPI mandate; without the token that event is
  // dropped silently, so this entry point needs the same setup as the other four.
  configureMixpanel(config, "subscription-start");
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

  // The one decision this function exists to make, and the one it never used to make at all.
  // `isEntitled` above answers "does this account have access right now"; this answers "has this
  // account already had its trial", and a lapsed subscriber is both unentitled and trial-spent.
  const trialEligible = !hasUsedTrial(user);
  const authorizationAmount = trialEligible ? settings.trialAmount : settings.recurringAmount;

  // Resume rather than duplicate: a double tap, or a checkout the user backgrounded and came
  // back to, must reuse the mandate it already opened.
  //
  // Only when it is the *same* offer, though. A trial-shaped session from before this branch
  // existed — or from before a webhook moved the account — stays resumable for its full fifteen
  // minutes, and handing it back would re-sell the ₹3 through the very path meant to stop it.
  const existing = await latestSubscription(db, userId);
  if (existing && isResumable(existing) && (existing.is_trial ?? true) === trialEligible) {
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
  // mandate the user just authorised, in favour of the broken one — or, worse, leave two UPI
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

    // Counted as a cancellation because that is what it is at the bank, but attributed to the
    // system: the user is in the middle of starting a *new* mandate, and a churn report that
    // reads this as them leaving would be exactly wrong.
    await trackCancellation({
      userId,
      subscriptionId: existing.subscription_id,
      cancelledBy: "system",
      cfStatus: "CANCELLED",
      fromStatus: existing.status,
      reason: "replaced_by_new_mandate",
    });
  }

  const now = new Date();
  const subscriptionId = newSubscriptionId(userId);
  // On the trial offer the first ₹499 lands when the trial runs out. Without it, the ₹499
  // authorisation *is* the first month, so the next debit is a month away — anything sooner
  // would bill twice for the same period.
  const firstChargeTime = trialEligible
    ? addDays(now, settings.trialDays)
    : addMonths(now, 1);
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
      is_trial: trialEligible,
      authorization_amount: authorizationAmount,
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
      authorizationAmount,
      // Kept, never returned — on both offers the authorisation is money the user is paying for
      // something, not a token debit to prove the mandate works.
      authorizationRefund: false,
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
    // What this mandate will actually do, not a copy of the config rows. These used to be
    // labelled "display only" and to always quote the trial, which is precisely the gap the
    // paywall fell into: it showed one offer while the mandate carried another.
    is_trial: trialEligible,
    authorization_amount: authorizationAmount,
    recurring_amount: settings.recurringAmount,
    first_charge_at: firstChargeTime.toISOString(),
    trial_days: settings.trialDays,
  });
});
