import { cancelSubscription, CashfreeError, cashfreeSettings } from "../_shared/cashfree.ts";
import { loadConfig } from "../_shared/config.ts";
import { fail, json, preflight } from "../_shared/cors.ts";
import { configureMixpanel } from "../_shared/mixpanel.ts";
import { serviceClient, userIdForBearer } from "../_shared/db.ts";
import {
  asUserRow,
  entitlementPayload,
  graceHoursFrom,
  USER_COLUMNS,
} from "../_shared/entitlement.ts";
import {
  latestSubscription,
  syncSubscription,
  trackCancellation,
} from "../_shared/subscription_sync.ts";

/**
 * Cancels the caller's UPI mandate so no further ₹499 is debited.
 *
 * Access is deliberately not revoked here: `current_period_end` is left alone, so the user
 * keeps the month they already paid for and `payment_type` becomes `cancelled`, which the
 * entitlement rule honours until that date passes.
 *
 * The subscription is found from the session token, never named in the body — otherwise
 * knowing a subscription id would be enough to cancel a stranger's plan.
 */
Deno.serve(async (req) => {
  const cors = preflight(req);
  if (cors) return cors;

  const db = serviceClient();
  const userId = await userIdForBearer(db, req.headers.get("Authorization"));
  if (!userId) return fail("unauthorized", "Please sign in again.", 401);

  const config = await loadConfig(db);
  // The sync path below emits subscription events; without the token they are dropped
  // silently, so every entry point that can reach it has to set it up.
  configureMixpanel(config, "subscription-cancel");
  const graceHours = graceHoursFrom(config);

  let settings;
  try {
    settings = cashfreeSettings(config);
  } catch (error) {
    console.error("cashfree settings unavailable", error);
    return fail("payment_failed", "Payments are temporarily unavailable.", 503);
  }

  const subscription = await latestSubscription(db, userId);
  if (!subscription || !["ACTIVE", "ON_HOLD", "PAUSED"].includes(subscription.status)) {
    return fail("invalid_request", "There is no active subscription to cancel.", 400);
  }

  // Read before the cancel, for the event below. The row read at the end of the handler is the
  // post-sync one, which is the right answer to return to the client but the wrong one to
  // describe the cancellation with — by then `payment_type` already says `cancelled`, and
  // whether this user was still in their trial when they left is exactly what churn reporting
  // is asking. `current_period_end` is deliberately untouched by a cancellation, so reading it
  // early is accurate either way.
  const { data: before } = await db
    .from("users")
    .select("payment_type, current_period_end, subscription_started_at")
    .eq("user_id", userId)
    .maybeSingle();

  try {
    await cancelSubscription(settings, subscription.subscription_id);
  } catch (error) {
    const detail = error instanceof CashfreeError ? error.detail : String(error);
    console.error("cashfree cancel failed", detail);
    return fail(
      "payment_failed",
      "Could not cancel the subscription. Please try again.",
      502,
    );
  }

  // Emitted here rather than left to the sync below, which is deliberately allowed to fail: the
  // Cashfree call above has already succeeded, so the cancellation is a fact whether or not the
  // read-back works. `trackCancellation` keys on the subscription id with no time bucket, so the
  // sync's own event — and the webhook's, minutes later — collapse onto this one. That ordering
  // is the point: Cashfree will report our own API cancel as a plain `CANCELLED`, indis-
  // tinguishable from any other, and only this call site knows it was the user tapping cancel
  // in the app rather than a mandate revoked from their UPI app.
  await trackCancellation({
    userId,
    subscriptionId: subscription.subscription_id,
    cancelledBy: "user_in_app",
    fromStatus: subscription.status,
    wasInTrial: before?.payment_type === "trial",
    entitledUntil: (before?.current_period_end as string | null) ?? null,
    startedAt: (before?.subscription_started_at as string | null) ?? null,
  });

  // Read the result back rather than assuming the cancel took effect, so the status we report
  // is the one Cashfree will actually bill against.
  try {
    await syncSubscription(db, settings, subscription.subscription_id);
  } catch (error) {
    console.error(`cancel reconcile failed for ${subscription.subscription_id}`, error);
  }

  const { data: userRow, error } = await db
    .from("users")
    .select(USER_COLUMNS)
    .eq("user_id", userId)
    .single();

  if (error || !userRow) {
    return fail("server_error", "Something went wrong. Please try again.", 500);
  }

  return json({ user: entitlementPayload(asUserRow(userRow), graceHours) });
});
