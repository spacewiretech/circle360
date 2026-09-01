import {
  cashfreeSettings,
  dedupeKey,
  paymentFrom,
  subscriptionIdsFrom,
  verifyWebhook,
} from "../_shared/cashfree.ts";
import { loadConfig } from "../_shared/config.ts";
import { corsHeaders, json } from "../_shared/cors.ts";
import { serviceClient } from "../_shared/db.ts";
import {
  asSubscriptionRow,
  recordPayment,
  SUBSCRIPTION_COLUMNS,
  syncSubscription,
} from "../_shared/subscription_sync.ts";

/**
 * Cashfree's server-to-server notifications. This is the only path by which an account becomes
 * paid, so it is also the only path worth attacking.
 *
 * Three rules hold it together:
 *
 *  1. Nothing is read from the body until the HMAC over the *raw* bytes verifies. An unset
 *     secret fails closed with a 503 rather than trusting whatever arrived.
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

  let settings;
  try {
    settings = cashfreeSettings(config);
  } catch (error) {
    console.error("cashfree webhook cannot verify: settings unavailable", error);
    return new Response("payments not configured", { status: 503, headers: corsHeaders });
  }

  const verified = await verifyWebhook(settings.secret, timestamp, signature, raw);

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

  // Recorded whether or not it verified: a forged call is worth being able to see.
  const skew = timestamp ? Math.round((Date.now() - Number(timestamp) * 1000) / 1000) : null;
  const ids = subscriptionIdsFrom(payload);

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
      return new Response("could not record event", { status: 500, headers: corsHeaders });
    }

    // Seen before. Only skip if the first attempt actually finished — otherwise a transient
    // failure would be swallowed permanently by its own audit row.
    const { data: prior } = await db
      .from("payment_events")
      .select("id, processed_at")
      .eq("dedupe_key", key)
      .maybeSingle();

    if (prior?.processed_at) return ok({ duplicate: true });

    // Seen before but never finished, and we cannot even find the row to mark. Processing now
    // would run the money path with no way to record that it ran, so every retry would run it
    // again. Fail instead and let Cashfree redeliver into a state that can be recorded.
    if (prior?.id == null) {
      console.error(`payment_events conflict on ${key} but no row to resume`);
      return new Response("could not record event", { status: 500, headers: corsHeaders });
    }
    eventId = prior.id as number;
  }

  if (!verified) {
    console.error(
      `cashfree webhook signature mismatch: type=${eventType} ` +
        `sub=${ids.subscriptionId ?? "?"} skew=${skew ?? "?"}s`,
    );
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

    if (!subscriptionId) {
      // Refund and reminder events that name no subscription we own. Recorded, not acted on.
      await finish("no subscription id in payload");
      return ok({ ignored: true, event: eventType });
    }

    const { data: subscriptionRow } = await db
      .from("subscriptions")
      .select(SUBSCRIPTION_COLUMNS)
      .eq("subscription_id", subscriptionId)
      .maybeSingle();

    if (!subscriptionRow) {
      // A mandate Cashfree knows about and we do not. Almost always a webhook from a different
      // environment pointed at this project; either way it must not be silently dropped.
      console.error(`webhook for unknown subscription ${subscriptionId}`);
      await finish("unknown subscription");
      return ok({ ignored: true, event: eventType });
    }

    const payment = paymentFrom(payload);
    if (payment) {
      await recordPayment(
        db,
        settings,
        asSubscriptionRow(subscriptionRow),
        payment,
        eventType,
      );
    }

    // The authoritative step: ask Cashfree what is true now and write that.
    await syncSubscription(db, settings, subscriptionId);

    await finish();
    return ok({ handled: true, event: eventType });
  } catch (error) {
    const detail = String(error);
    console.error(`cashfree webhook processing failed for ${eventType}: ${detail}`);
    await finish(detail.slice(0, 500));
    // 500 so Cashfree retries. The dedupe row is left unprocessed, so the retry runs for real.
    return new Response("processing failed", { status: 500, headers: corsHeaders });
  }
});
