import { cashfreeSettings } from "../_shared/cashfree.ts";
import { configSetting, loadConfig } from "../_shared/config.ts";
import { corsHeaders, json } from "../_shared/cors.ts";
import { configureMixpanel } from "../_shared/mixpanel.ts";
import { serviceClient } from "../_shared/db.ts";
import { constantTimeEquals } from "../_shared/cashfree.ts";
import { refreshPaymentTotals, syncSubscription } from "../_shared/subscription_sync.ts";

/**
 * The safety net under the webhook. Run it on a schedule:
 *
 *   select cron.schedule('reconcile-subscriptions', '0 * * * *', $$
 *     select net.http_post(
 *       url    := 'https://symwrytqyhyxlcjaubru.supabase.co/functions/v1/subscription-reconcile',
 *       headers:= '{"x-reconcile-secret": "<app_config.reconcile_secret>"}'::jsonb
 *     ) $$);
 *
 * Webhooks get lost — endpoints are briefly down, deliveries are dropped, a deploy lands at the
 * wrong moment. Without this, a user whose ₹499 was debited during that window would sit in
 * `trial` until it expired and then be told to pay again. Here we go and ask.
 */

/** Bounded so one run cannot exceed the function timeout on a large backlog. */
const BATCH = 100;

/** Cashfree states in which a schedule can still fire, so drift is worth checking for. */
const LIVE = [
  "ACTIVE",
  "ON_HOLD",
  "PAUSED",
  "CUSTOMER_PAUSED",
  "BANK_APPROVAL_PENDING",
  "PENDING_AUTHORIZATION",
  "INITIALIZED",
];

/**
 * How stale a live trial mandate may get before we go and ask Cashfree about it directly.
 *
 * This is the sweep's third pass, and it exists for one case the other two cannot see: a user who
 * revokes the UPI mandate from their PSP app mid-trial. Cashfree does not promise a webhook for a
 * customer-initiated revocation, the user has closed the app so nothing polls `subscription-status`,
 * and neither of the passes below matches — the next charge is not overdue yet, and the trial has
 * not ended. Nothing would notice until the trial expired days later.
 */
const TRIAL_RECHECK_HOURS = 6;

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });

  const db = serviceClient();
  const config = await loadConfig(db);
  // The sync path below emits subscription events; without the token they are dropped
  // silently, so every entry point that can reach it has to set it up.
  configureMixpanel(config, "subscription-reconcile");

  // Fail closed: with no secret configured this endpoint would be an open invitation to make
  // us hammer Cashfree on demand.
  const expected = configSetting(config, "reconcile_secret");
  const provided = req.headers.get("x-reconcile-secret") ?? "";
  if (!expected || !constantTimeEquals(expected, provided)) {
    return new Response("forbidden", { status: 403, headers: corsHeaders });
  }

  let settings;
  try {
    settings = cashfreeSettings(config);
  } catch (error) {
    console.error("reconcile cannot run: settings unavailable", error);
    return new Response("payments not configured", { status: 503, headers: corsHeaders });
  }

  const now = new Date();
  const nowIso = now.toISOString();

  // Cheap first pass, no network: close out checkouts whose session token has expired without
  // the user ever reaching the UPI sheet. These can never become active on their own.
  const { count: abandoned } = await db
    .from("subscriptions")
    .update({ status: "ABANDONED" }, { count: "exact" })
    .in("status", ["INITIALIZED", "PENDING_AUTHORIZATION"])
    .lt("session_expiry", nowIso);

  // A schedule that should have fired an hour ago and produced no webhook is drift worth
  // chasing. The hour of slack keeps the sweep off charges that are simply still settling.
  const overdue = new Date(now.getTime() - 60 * 60 * 1000).toISOString();

  const { data: drifted, error } = await db
    .from("subscriptions")
    .select("subscription_id")
    .in("status", LIVE)
    .not("next_schedule_date", "is", null)
    .lt("next_schedule_date", overdue)
    .order("next_schedule_date", { ascending: true })
    .limit(BATCH);

  if (error) {
    console.error("reconcile candidate query failed", error);
    return new Response("query failed", { status: 500, headers: corsHeaders });
  }

  // Trials that should have converted by now: the first ₹499 was due, the grace has run out,
  // and the account is still sitting in `trial`. Either the debit failed — in which case the
  // paywall is correct — or its webhook went missing, which this repairs.
  const graceAgo = new Date(
    now.getTime() - Number(configSetting(config, "entitlement_grace_hours") || 12) * 3600_000,
  ).toISOString();

  const { data: staleTrials } = await db
    .from("users")
    .select("active_subscription_id")
    .eq("payment_type", "trial")
    .not("trial_ends_at", "is", null)
    .not("active_subscription_id", "is", null)
    .lt("trial_ends_at", graceAgo)
    .limit(BATCH);

  // Trials still running, whose mandate we have not heard about in a while. See
  // TRIAL_RECHECK_HOURS: this is the only pass that catches a mandate the user cancelled in their
  // UPI app before the first ₹499 was ever due.
  const staleSince = new Date(
    now.getTime() - TRIAL_RECHECK_HOURS * 3600_000,
  ).toISOString();

  const { data: unwatchedTrials, error: trialError } = await db
    .from("subscriptions")
    .select("subscription_id, users!inner(payment_type)")
    .in("status", LIVE)
    .eq("users.payment_type", "trial")
    .lt("updated_at", staleSince)
    .order("updated_at", { ascending: true })
    .limit(BATCH);

  // Logged rather than fatal — the two passes above are still worth running — but logged loudly,
  // because a silently empty result here is indistinguishable from "nothing to do" and would
  // leave the only pass that catches a UPI-app cancellation quietly doing nothing at all.
  if (trialError) console.error("reconcile trial-recheck query failed", trialError);

  const ids = new Set<string>();
  for (const row of drifted ?? []) ids.add(row.subscription_id as string);
  for (const row of staleTrials ?? []) ids.add(row.active_subscription_id as string);
  for (const row of unwatchedTrials ?? []) ids.add(row.subscription_id as string);

  let synced = 0;
  const failures: string[] = [];

  for (const id of ids) {
    try {
      // withPayments: this sweep exists for the case where a webhook never arrived, and the
      // subscription snapshot alone cannot tell us a ₹499 was taken. Only the payments list
      // can, and without it a debited user still lapses.
      const result = await syncSubscription(db, settings, id, 0, true);
      // Denormalised counters are recomputed from the ledger, so anything that drifted — a
      // partial write, a charge recorded before these columns existed — is repaired here
      // rather than staying wrong forever.
      await refreshPaymentTotals(db, result.subscription.user_id);
      synced++;
    } catch (err) {
      // One bad subscription must not abort the batch — the rest still need reconciling.
      failures.push(`${id}: ${err}`);
    }
  }

  if (failures.length > 0) console.error("reconcile failures", failures);

  return json({
    checked: ids.size,
    synced,
    abandoned: abandoned ?? 0,
    failed: failures.length,
  });
});
