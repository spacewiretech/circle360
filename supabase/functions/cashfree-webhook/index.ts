import {
  cashfreeSettings,
  dedupeKey,
  disputeFrom,
  paymentFrom,
  refundFrom,
  subscriptionIdsFrom,
  verifyWebhook,
} from "../_shared/cashfree.ts";
import { loadConfig } from "../_shared/config.ts";
import { corsHeaders, json } from "../_shared/cors.ts";
import { serviceClient } from "../_shared/db.ts";
import { configureMixpanel, trackServer } from "../_shared/mixpanel.ts";
import {
  asSubscriptionRow,
  recordDispute,
  recordPayment,
  recordRefund,
  SUBSCRIPTION_COLUMNS,
  syncSubscription,
} from "../_shared/subscription_sync.ts";

/**
 * Cashfree's server-to-server notifications. This is the only path by which an account becomes
 * paid, so it is also the only path worth attacking.
 *
 * Three rules hold it together:
 *
 *  1. Nothing is *acted on* until the HMAC over the raw bytes verifies. The body is parsed
 *     before that — an unverifiable delivery still has to be recorded and counted, and an unset
 *     secret still fails closed with a 503 — but what comes out of it is only ever used to name
 *     a subscription, never as the state to write. See rule 3.
 *  2. Every delivery is recorded before it is acted on, under a unique dedupe key, so a
 *     redelivery is a no-op — unless the first attempt never finished, in which case it is
 *     deliberately retried.
 *  3. The payload is treated as a hint, never as data. Its only job is to name a subscription;
 *     the state that gets written comes from asking Cashfree what that subscription looks like
 *     now. That is what makes duplicate and out-of-order deliveries harmless.
 */

/** Bounded so a flood of forged calls cannot be used to fill the audit table. */
const MAX_RECORDED_BODY = 64 * 1024;

const UNIQUE_VIOLATION = "23505";

function ok(body: Record<string, unknown>): Response {
  return json(body, 200);
}

/**
 * The user behind a charge, for the events that name a payment but no subscription.
 *
 * A refund or a chargeback arrives months after the mandate it belongs to, and carries only a
 * `cf_payment_id`. The ledger is the only thing that can turn that back into a person.
 */
async function userForPayment(
  db: ReturnType<typeof serviceClient>,
  cfPaymentId: string | null,
): Promise<string | null> {
  if (!cfPaymentId) return null;
  const { data } = await db
    .from("subscription_payments")
    .select("user_id")
    .eq("cf_payment_id", cfPaymentId)
    .maybeSingle();
  return (data?.user_id as string | undefined) ?? null;
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }
  if (req.method !== "POST") {
    return new Response("method not allowed", { status: 405, headers: corsHeaders });
  }

  // Must be the exact bytes Cashfree signed. Parsing first and re-serialising reorders keys
  // and the signature silently stops matching.
  const raw = await req.text();
  const signature = req.headers.get("x-webhook-signature");
  const timestamp = req.headers.get("x-webhook-timestamp");

  const db = serviceClient();
  const config = await loadConfig(db);
  configureMixpanel(config, "cashfree-webhook");

  // Parsed before the secret is looked up, so that a delivery arriving at a misconfigured
  // deployment can still be identified and counted. This reads the body without having verified
  // it, which is safe only because nothing below *acts* on it until `verified` is checked — the
  // payload is a hint about which subscription to go and ask Cashfree about, never data.
  let payload: Record<string, unknown> = {};
  try {
    payload = raw ? JSON.parse(raw) : {};
  } catch {
    payload = {};
  }

  const eventType = typeof payload.type === "string"
    ? payload.type
    : typeof payload.event === "string"
    ? payload.event
    : "UNKNOWN";

  const stamp = timestamp ?? "";
  const key = await dedupeKey(eventType, stamp, raw);

  // Assigned once the secret is in hand. `reportDelivery` closes over it and reads it at call
  // time, so the one outcome reported before verification is possible still reports honestly.
  let verified = false;

  // Recorded whether or not it verified: a forged call is worth being able to see.
  const skew = timestamp ? Math.round((Date.now() - Number(timestamp) * 1000) / 1000) : null;
  const ids = subscriptionIdsFrom(payload);

  // Everything known about *why* this delivery arrived, attached to whichever outcome it reaches.
  // The cause — Cashfree's own event type — is the property the whole webhook funnel breaks down
  // by: a renewal, an authorisation and a mandate going on hold all land on this one endpoint and
  // are otherwise indistinguishable once processed.
  let deliveryUserId: string | null = null;
  let reported = false;

  const reportDelivery = async (
    outcome: string,
    extra: Record<string, unknown> = {},
  ): Promise<void> => {
    // Exactly one per delivery. Several exit paths below can be reached in sequence, and a
    // webhook counted twice would double every denominator built on this event.
    if (reported) return;
    reported = true;

    await trackServer({
      event: "Webhook Received",
      distinctId: deliveryUserId,
      // The dedupe key hashes type + timestamp + body, so a Cashfree redelivery of the same
      // notification resolves to the same id. The outcome is part of the id because a redelivery
      // is deliberately reported again under `duplicate`: same delivery, different thing
      // happening to it, and collapsing the two onto one id would hide the redelivery entirely.
      insertId: `wh:${key}:${outcome}`,
      properties: {
        outcome,
        // The cause.
        cf_event_type: eventType,
        signature_ok: verified,
        skew_seconds: Number.isFinite(skew) ? skew : null,
        cf_subscription_id: ids.cfSubscriptionId,
        subscription_id: ids.subscriptionId,
        header_timestamp: timestamp,
        body_bytes: raw.length,
        ...extra,
      },
    });
  };

  let settings;
  try {
    settings = cashfreeSettings(config);
  } catch (error) {
    console.error("cashfree webhook cannot verify: settings unavailable", error);
    // A rotated-away or unset secret stops the only path by which an account becomes paid, and
    // used to do it in total silence — nothing recorded, nothing counted, only a log line nobody
    // reads until a user complains they paid and got nothing.
    await reportDelivery("not_configured");
    return new Response("payments not configured", { status: 503, headers: corsHeaders });
  }

  verified = await verifyWebhook(settings.secret, timestamp, signature, raw);

  const eventRow = {
    event_type: eventType,
    dedupe_key: key,
    signature_ok: verified,
    header_timestamp: timestamp,
    skew_seconds: Number.isFinite(skew) ? skew : null,
    cf_subscription_id: ids.cfSubscriptionId,
    subscription_id: ids.subscriptionId,
    payload: raw.length <= MAX_RECORDED_BODY ? payload : { truncated: raw.length },
  };

  const { data: inserted, error: insertError } = await db
    .from("payment_events")
    .insert(eventRow)
    .select("id, processed_at")
    .single();

  let eventId = inserted?.id as number | undefined;

  if (insertError) {
    if (insertError.code !== UNIQUE_VIOLATION) {
      console.error("payment_events insert failed", insertError);
      // The only exit that used to skip reporting entirely. A database that cannot take the
      // audit row is the one failure where the webhook funnel goes quiet with no trace at all.
      await reportDelivery("record_failed", { error: insertError.message.slice(0, 300) });
      return new Response("could not record event", { status: 500, headers: corsHeaders });
    }

    // Seen before. Only skip if the first attempt actually finished — otherwise a transient
    // failure would be swallowed permanently by its own audit row.
    const { data: prior } = await db
      .from("payment_events")
      .select("id, processed_at")
      .eq("dedupe_key", key)
      .maybeSingle();

    if (prior?.processed_at) {
      await reportDelivery("duplicate");
      return ok({ duplicate: true });
    }

    // Seen before but never finished, and we cannot even find the row to mark. Processing now
    // would run the money path with no way to record that it ran, so every retry would run it
    // again. Fail instead and let Cashfree redeliver into a state that can be recorded.
    if (prior?.id == null) {
      console.error(`payment_events conflict on ${key} but no row to resume`);
      await reportDelivery("unrecoverable");
      return new Response("could not record event", { status: 500, headers: corsHeaders });
    }
    eventId = prior.id as number;
  }

  if (!verified) {
    console.error(
      `cashfree webhook signature mismatch: type=${eventType} ` +
        `sub=${ids.subscriptionId ?? "?"} skew=${skew ?? "?"}s`,
    );
    // A forged or misconfigured caller. Worth an event rather than only a log line: a sudden run
    // of these is either an attack or the webhook secret having been rotated on one side only,
    // and both need noticing before the money path silently stops working.
    await reportDelivery("signature_rejected");
    return new Response("invalid signature", { status: 401, headers: corsHeaders });
  }

  const finish = async (error?: string) => {
    if (eventId === undefined) return;
    await db
      .from("payment_events")
      .update({ processed_at: new Date().toISOString(), process_error: error ?? null })
      .eq("id", eventId);
  };

  try {
    // Cashfree's own id is the fallback: a few event shapes carry it without ours.
    let subscriptionId = ids.subscriptionId;
    if (!subscriptionId && ids.cfSubscriptionId) {
      const { data } = await db
        .from("subscriptions")
        .select("subscription_id")
        .eq("cf_subscription_id", ids.cfSubscriptionId)
        .maybeSingle();
      subscriptionId = (data?.subscription_id as string | undefined) ?? null;
    }

    // Read once, here, rather than inside the subscription branch below. `reportDelivery` stamps
    // whatever `deliveryUserId` holds at the moment it is called, and every branch between here
    // and there — refund, dispute, ignored, unknown — reports before the branch that used to
    // assign it. They all went out as `unattributed:…` even when the user was perfectly well
    // known, which made the whole `Webhook Received` funnel unjoinable to a person.
    const { data: subscriptionRow } = subscriptionId
      ? await db
        .from("subscriptions")
        .select(SUBSCRIPTION_COLUMNS)
        .eq("subscription_id", subscriptionId)
        .maybeSingle()
      : { data: null };

    if (subscriptionRow) {
      deliveryUserId = asSubscriptionRow(subscriptionRow).user_id;
    }

    // Payment-scoped events — refunds and disputes — name no subscription, only a payment. The
    // ledger ties every charge to its mandate, so they resolve through that instead. Handled
    // before the subscription branch because they will never satisfy it.
    const refund = refundFrom(payload);
    if (refund) {
      await recordRefund(db, refund);
      deliveryUserId ??= await userForPayment(db, refund.cfPaymentId);
      await finish();
      await reportDelivery("handled", {
        kind: "refund",
        cf_refund_id: refund.cfRefundId,
        cf_payment_id: refund.cfPaymentId,
        amount: refund.amount,
        currency: refund.currency,
        refund_status: refund.status,
        refund_reason: refund.reason,
      });
      return ok({ handled: true, event: eventType, kind: "refund" });
    }

    const dispute = disputeFrom(payload);
    if (dispute) {
      await recordDispute(db, dispute);
      deliveryUserId ??= await userForPayment(db, dispute.cfPaymentId);
      await finish();
      await reportDelivery("handled", {
        kind: "dispute",
        cf_dispute_id: dispute.cfDisputeId,
        cf_payment_id: dispute.cfPaymentId,
        dispute_status: dispute.status,
      });
      return ok({ handled: true, event: eventType, kind: "dispute" });
    }

    if (!subscriptionId) {
      // Everything else that names nothing we own: one-time PG order events (this app opens no
      // orders), settlement notices, pre-debit reminders. Recorded in payment_events and
      // acknowledged, because a 200 is what stops Cashfree retrying an event we will never act
      // on — and marking it processed is what stops it being retried forever.
      await finish();
      await reportDelivery("ignored", { reason: "no subscription, refund or dispute" });
      return ok({ ignored: true, event: eventType, reason: "no subscription, refund or dispute" });
    }

    if (!subscriptionRow) {
      // A mandate Cashfree knows about and we do not. Almost always a webhook from a different
      // environment pointed at this project; either way it must not be silently dropped.
      console.error(`webhook for unknown subscription ${subscriptionId}`);
      await finish("unknown subscription");
      // Almost always a webhook from the other Cashfree environment pointed at this project.
      // Counting them is how that gets noticed at all.
      await reportDelivery("unknown_subscription");
      return ok({ ignored: true, event: eventType });
    }

    const row = asSubscriptionRow(subscriptionRow);

    const payment = paymentFrom(payload);
    if (payment) {
      await recordPayment(db, settings, row, payment, eventType);
    }

    // The authoritative step: ask Cashfree what is true now and write that.
    const result = await syncSubscription(db, settings, subscriptionId);

    await finish();
    await reportDelivery("handled", {
      kind: payment ? "payment" : "status",
      subscription_status: result.snapshot.status,
      payment_type: result.user.payment_type,
      entitled_until: result.user.current_period_end,
      next_billing_at: result.snapshot.nextScheduleDate,
      cf_payment_id: payment?.cfPaymentId,
      payment_status: payment?.status,
      amount: payment?.amount,
    });
    return ok({ handled: true, event: eventType });
  } catch (error) {
    const detail = String(error);
    console.error(`cashfree webhook processing failed for ${eventType}: ${detail}`);
    await finish(detail.slice(0, 500));
    await reportDelivery("failed", { error: detail.slice(0, 300) });
    // 500 so Cashfree retries. The dedupe row is left unprocessed, so the retry runs for real.
    return new Response("processing failed", { status: 500, headers: corsHeaders });
  }
});
