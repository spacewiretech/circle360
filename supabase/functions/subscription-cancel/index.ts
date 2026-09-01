import { cancelSubscription, CashfreeError, cashfreeSettings } from "../_shared/cashfree.ts";
import { loadConfig } from "../_shared/config.ts";
import { fail, json, preflight } from "../_shared/cors.ts";
import { serviceClient, userIdForBearer } from "../_shared/db.ts";
import {
  asUserRow,
  entitlementPayload,
  graceHoursFrom,
  USER_COLUMNS,
} from "../_shared/entitlement.ts";
import { latestSubscription, syncSubscription } from "../_shared/subscription_sync.ts";

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
