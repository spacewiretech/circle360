/**
 * Server-side Mixpanel, for the half of the subscription lifecycle the app never sees.
 *
 * A recurring UPI debit happens on Cashfree's schedule, weeks after anyone opened the app. The
 * client can only ever report what a user did in front of it: it cannot report the renewal that
 * succeeded at 3am, the mandate the bank put on hold, or the chargeback filed a month later.
 * Those arrive here, as webhooks, and this is what puts them on the same timeline as the taps.
 *
 * Three things make that join work:
 *
 *  1. **`distinct_id` is the `users.user_id`** — exactly what the app passes to `identify()`. A
 *     renewal lands on the same Mixpanel profile as the `Subscribe Tapped` that started it.
 *  2. **`$insert_id` is derived from the thing that happened**, not from the delivery. Cashfree
 *     redelivers webhooks freely and the reconcile sweep replays history hourly; without a
 *     stable id per *charge*, a single renewal would show up as a dozen renewals and every
 *     revenue number would be wrong.
 *  3. **`$ip: "0"`** so Mixpanel does not geolocate the event. Left alone it would resolve the
 *     Supabase edge node's address and quietly overwrite the user's real city and region with a
 *     data centre — corrupting the geography the client-side events got right.
 */

import { AppConfig, configSetting } from "./config.ts";

const TRACK_URL = "https://api.mixpanel.com/track";
const ENGAGE_URL = "https://api.mixpanel.com/engage";

/** Long enough for a normal call, short enough that Cashfree never waits on analytics. */
const TIMEOUT_MS = 4_000;

/**
 * Set once per request by the entry point.
 *
 * Module-level rather than threaded through every function signature: `recordPayment` and
 * `syncSubscription` sit five frames down from the handler and would otherwise all have to carry
 * a parameter they do not use themselves. It is safe because there is exactly one project token
 * for the whole deployment — a warm instance reusing it across requests is reusing the same
 * value it would have been handed anyway.
 */
let token = "";

/**
 * Which Edge Function is running, stamped on every event it produces.
 *
 * The same `Subscription Renewed` can be raised by a Cashfree webhook arriving in real time, by
 * the hourly reconcile sweep catching one that never arrived, or by a status poll from the app
 * itself. Those are three very different stories about how healthy the payment plumbing is, and
 * without this they are one indistinguishable row.
 */
let source = "unknown";

export function configureMixpanel(config: AppConfig, functionName: string): void {
  token = configSetting(config, "mixpanel_token");
  source = functionName;
}

export function mixpanelConfigured(): boolean {
  return token.length > 0;
}

export interface ServerEvent {
  event: string;
  /**
   * The `users.user_id` this concerns. Null when the event names nothing we own — an unknown
   * subscription, a forged signature — in which case a synthetic id keeps the event countable
   * without inventing a user.
   */
  distinctId: string | null;
  /** Stable per real-world occurrence. See the note on `$insert_id` above. */
  insertId: string;
  /** When it actually happened, if that differs from now. */
  time?: string | null;
  properties?: Record<string, unknown>;
}

/**
 * Sends events, and never lets an analytics failure touch the caller.
 *
 * The webhook this hangs off is the only path by which an account becomes paid. Nothing here may
 * throw, and nothing here may delay it materially: an unreachable Mixpanel must cost the user
 * their analytics, never their subscription.
 */
export async function trackServer(events: ServerEvent[] | ServerEvent): Promise<void> {
  if (!token) return;

  const list = Array.isArray(events) ? events : [events];
  if (list.length === 0) return;

  const payload = list.map((e) => ({
    event: e.event,
    properties: {
      token,
      // A synthetic id rather than a dropped event: knowing how many webhooks arrive for
      // subscriptions we cannot attribute is itself worth knowing.
      distinct_id: e.distinctId ?? `unattributed:${e.insertId}`,
      $insert_id: e.insertId,
      time: e.time ? Date.parse(e.time) : Date.now(),
      // Without this every server event would be stamped with the edge node's geography.
      $ip: "0",
      // So server-originated events can be told apart from the app's in one filter. `mp_lib` is
      // deliberately left to the ingestion API.
      source: "server",
      server_function: source,
      ...stripNullish(e.properties ?? {}),
    },
  }));

  await send(TRACK_URL, payload);
}

/**
 * Mirrors subscription state onto the People profile.
 *
 * Worth doing from here specifically because the interesting transitions happen while the app is
 * closed. A user whose mandate went on hold in the night should look like that in Mixpanel before
 * they next open the app, or every "who is at risk" segment is a day stale.
 */
export async function setProfile(
  distinctId: string | null,
  properties: Record<string, unknown>,
): Promise<void> {
  if (!token || !distinctId) return;

  const cleaned = stripNullish(properties);
  if (Object.keys(cleaned).length === 0) return;

  await send(ENGAGE_URL, [{
    $token: token,
    $distinct_id: distinctId,
    $ip: "0",
    // Never create a profile from the server for someone who has not used the app: the client's
    // identify() owns profile creation, and $set on an unknown id would mint a bare profile with
    // no name, phone or device.
    $set: cleaned,
  }]);
}

/**
 * Hands the send to the runtime and returns immediately.
 *
 * This matters more than it looks. These calls sit inside `recordPayment` and `syncSubscription`,
 * on the path Cashfree is waiting on: awaited, a slow Mixpanel would add its round trip to every
 * webhook response, and a hanging one would push the handler past Cashfree's timeout into a
 * retry. Analytics must never be able to do that to the only code path that makes an account
 * paid.
 *
 * `EdgeRuntime.waitUntil` keeps the isolate alive until the request finishes without holding the
 * response, which is exactly the shape this wants. Where it does not exist — `deno check`, a
 * local run, a test — the promise is awaited instead so nothing is silently dropped.
 */
function send(url: string, body: unknown): Promise<void> {
  const pending = post(url, body);

  const runtime = (globalThis as { EdgeRuntime?: { waitUntil?: (p: Promise<unknown>) => void } })
    .EdgeRuntime;

  if (typeof runtime?.waitUntil === "function") {
    runtime.waitUntil(pending);
    return Promise.resolve();
  }

  return pending;
}

async function post(url: string, body: unknown): Promise<void> {
  try {
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), TIMEOUT_MS);

    try {
      const response = await fetch(url, {
        method: "POST",
        headers: { "content-type": "application/json", accept: "text/plain" },
        body: JSON.stringify(body),
        signal: controller.signal,
      });

      if (!response.ok) {
        console.error(`mixpanel ${url} responded ${response.status}`);
        return;
      }

      // Mixpanel answers `1` for accepted and `0` for rejected, with a 200 either way — a
      // malformed property silently vanishes unless the body is actually read.
      const text = (await response.text()).trim();
      if (text === "0") console.error(`mixpanel ${url} rejected the payload`);
    } finally {
      clearTimeout(timer);
    }
  } catch (error) {
    // Includes the abort. Logged, never rethrown.
    console.error("mixpanel send failed", String(error));
  }
}

/** Mixpanel stores an explicit null as a real value; dropping them keeps breakdowns clean. */
function stripNullish(
  properties: Record<string, unknown>,
): Record<string, unknown> {
  const out: Record<string, unknown> = {};
  for (const [key, value] of Object.entries(properties)) {
    if (value !== null && value !== undefined) out[key] = value;
  }
  return out;
}
