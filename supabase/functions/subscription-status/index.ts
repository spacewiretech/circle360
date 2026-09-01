import { cashfreeSettings } from "../_shared/cashfree.ts";
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
 * Re-reads the caller's subscription from Cashfree and returns their current entitlement.
 *
 * Two jobs. It is what the app polls after checkout, because the SDK's success callback proves
 * only that the sheet closed — not that the money moved. And it is the self-heal for a webhook
 * that never arrived, which is why it reconciles rather than just reading the local row.
 *
 * A Cashfree outage degrades to the stored state instead of erroring: a user who is already
 * paid up must not be locked out because the gateway is briefly unreachable.
 */

const TERMINAL = ["CANCELLED", "COMPLETED", "EXPIRED", "ABANDONED", "FAILED_TO_CREATE"];

Deno.serve(async (req) => {
  const cors = preflight(req);
  if (cors) return cors;

  const db = serviceClient();
  const userId = await userIdForBearer(db, req.headers.get("Authorization"));
  if (!userId) return fail("unauthorized", "Please sign in again.", 401);

  const config = await loadConfig(db);
  const graceHours = graceHoursFrom(config);

  const subscription = await latestSubscription(db, userId);

  if (subscription && !TERMINAL.includes(subscription.status)) {
    try {
      const settings = cashfreeSettings(config);
      await syncSubscription(db, settings, subscription.subscription_id);
    } catch (error) {
      // Logged, not surfaced. The stored state below is still a correct answer, just possibly
      // a few minutes stale, and the webhook or the nightly sweep will catch up.
      console.error(`status reconcile failed for ${subscription.subscription_id}`, error);
    }
  }

  const { data: userRow, error } = await db
    .from("users")
    .select(USER_COLUMNS)
    .eq("user_id", userId)
    .single();

  if (error || !userRow) {
    console.error("subscription-status user lookup failed", error);
    return fail("server_error", "Something went wrong. Please try again.", 500);
  }

  const fresh = subscription ? await latestSubscription(db, userId) : null;

  return json({
    user: entitlementPayload(asUserRow(userRow), graceHours),
    subscription: fresh
      ? {
        subscription_id: fresh.subscription_id,
        status: fresh.status,
        next_schedule_date: fresh.next_schedule_date,
        authorized_at: fresh.authorized_at,
      }
      : null,
  });
});
