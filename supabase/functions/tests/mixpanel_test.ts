import { assert, assertEquals } from "jsr:@std/assert@1";

import { configureMixpanel, mixpanelConfigured, setProfile, trackServer } from "../_shared/mixpanel.ts";
import { trackCancellation } from "../_shared/subscription_sync.ts";

/** One captured outbound call. */
interface Captured {
  url: string;
  body: unknown;
}

/** Swaps `fetch` for a recorder, so the module can be exercised without the network. */
function captureFetch(): { calls: Captured[]; restore: () => void } {
  const calls: Captured[] = [];
  const original = globalThis.fetch;

  globalThis.fetch = ((url: string | URL | Request, init?: RequestInit) => {
    calls.push({
      url: String(url),
      body: JSON.parse(String(init?.body ?? "null")),
    });
    return Promise.resolve(new Response("1", { status: 200 }));
  }) as typeof fetch;

  return { calls, restore: () => { globalThis.fetch = original; } };
}

function configWith(token: string): Map<string, string> {
  return new Map([["mixpanel_token", token]]);
}

/** The single event out of a captured /track call. */
function soleEvent(calls: Captured[]): Record<string, // deno-lint-ignore no-explicit-any
  any> {
  assertEquals(calls.length, 1);
  const batch = calls[0].body as Array<Record<string, unknown>>;
  assertEquals(batch.length, 1);
  return batch[0] as Record<string, unknown>;
}

Deno.test("no token means nothing is sent at all", async () => {
  const { calls, restore } = captureFetch();
  try {
    configureMixpanel(configWith(""), "test");
    assertEquals(mixpanelConfigured(), false);

    await trackServer({ event: "Subscription Renewed", distinctId: "u1", insertId: "pay:1" });
    await setProfile("u1", { payment_type: "active" });

    // The whole integration is optional. An empty `mixpanel_token` row must leave the payment
    // path behaving exactly as it did before analytics existed.
    assertEquals(calls.length, 0);
  } finally {
    restore();
  }
});

Deno.test("a tracked event carries the token, the user and the insert id", async () => {
  const { calls, restore } = captureFetch();
  try {
    configureMixpanel(configWith("tok"), "cashfree-webhook");
    await trackServer({
      event: "Subscription Renewed",
      distinctId: "user-1",
      insertId: "pay:cf_99:SUCCESS",
      properties: { amount: 499, failure_reason: null },
    });

    assertEquals(calls[0].url, "https://api.mixpanel.com/track");
    const props = soleEvent(calls).properties;

    assertEquals(props.token, "tok");
    // Must equal what the app passes to identify(), or server and client events land on two
    // different profiles for the same person.
    assertEquals(props.distinct_id, "user-1");
    assertEquals(props.$insert_id, "pay:cf_99:SUCCESS");
    assertEquals(props.amount, 499);
    // Which entry point produced it — a webhook, the reconcile sweep, or a status poll.
    assertEquals(props.server_function, "cashfree-webhook");
    assertEquals(props.source, "server");
    // Nulls are dropped rather than stored as real values.
    assert(!("failure_reason" in props));
  } finally {
    restore();
  }
});

Deno.test("$ip is suppressed so the edge node's geography is never written", async () => {
  const { calls, restore } = captureFetch();
  try {
    configureMixpanel(configWith("tok"), "test");
    await trackServer({ event: "X", distinctId: "u1", insertId: "i1" });
    await setProfile("u1", { payment_type: "active" });

    // Without this Mixpanel resolves the *server's* address and silently overwrites the real
    // city and region the client-side events got right.
    assertEquals((soleEvent([calls[0]]).properties as Record<string, unknown>).$ip, "0");
    const profile = (calls[1].body as Array<Record<string, unknown>>)[0];
    assertEquals(profile.$ip, "0");
  } finally {
    restore();
  }
});

Deno.test("an unattributable event is still counted, under a synthetic id", async () => {
  const { calls, restore } = captureFetch();
  try {
    configureMixpanel(configWith("tok"), "test");
    await trackServer({ event: "Webhook Received", distinctId: null, insertId: "wh:abc" });

    // A webhook for a subscription we do not own — usually the other Cashfree environment
    // pointed at this project — must not vanish just because it names no user.
    assertEquals(soleEvent(calls).properties.distinct_id, "unattributed:wh:abc");
  } finally {
    restore();
  }
});

Deno.test("a profile write for an unknown user is refused", async () => {
  const { calls, restore } = captureFetch();
  try {
    configureMixpanel(configWith("tok"), "test");
    await setProfile(null, { payment_type: "active" });
    await setProfile("u1", {});
    await setProfile("u1", { billing_state: null });

    // The client's identify() owns profile creation. A $set from the server on an unknown id
    // would mint a bare profile with no name, phone or device attached to it; an empty or
    // all-null patch would write nothing but still cost a request.
    assertEquals(calls.length, 0);
  } finally {
    restore();
  }
});

Deno.test("an event time can be anchored to when the charge actually happened", async () => {
  const { calls, restore } = captureFetch();
  try {
    configureMixpanel(configWith("tok"), "test");
    await trackServer({
      event: "Subscription Renewed",
      distinctId: "u1",
      insertId: "pay:1",
      // A webhook can arrive hours late, and the renewal belongs on the day it was collected.
      time: "2026-09-01T03:00:00.000Z",
    });

    assertEquals(soleEvent(calls).properties.time, Date.parse("2026-09-01T03:00:00.000Z"));
  } finally {
    restore();
  }
});

Deno.test("a Mixpanel outage cannot throw into the payment path", async () => {
  const original = globalThis.fetch;
  globalThis.fetch = (() => Promise.reject(new Error("network down"))) as typeof fetch;

  try {
    configureMixpanel(configWith("tok"), "test");
    // The webhook this hangs off is the only path by which an account becomes paid. A rejected
    // send must be swallowed, not propagated.
    await trackServer({ event: "Subscription Renewed", distinctId: "u1", insertId: "pay:1" });
    await setProfile("u1", { payment_type: "active" });
  } finally {
    globalThis.fetch = original;
  }
});

// ---------------------------------------------------------------- cancellation

Deno.test("a cancellation is one event however many times it is noticed", async () => {
  const { calls, restore } = captureFetch();
  try {
    configureMixpanel(configWith("tok"), "cashfree-webhook");

    await trackCancellation({
      userId: "u1",
      subscriptionId: "c360_abc_123",
      cancelledBy: "customer",
      cfStatus: "CUSTOMER_CANCELLED",
      fromStatus: "ACTIVE",
      wasInTrial: true,
      entitledUntil: "2026-09-20T00:00:00.000Z",
      startedAt: "2026-09-01T00:00:00.000Z",
    });

    const event = soleEvent(calls);
    assertEquals(event.event, "Subscription Cancelled");
    assertEquals(event.properties.distinct_id, "u1");
    assertEquals(event.properties.cancelled_by, "customer");
    assertEquals(event.properties.cf_status, "CUSTOMER_CANCELLED");
    assertEquals(event.properties.was_in_trial, true);

    // The whole point of the id. Four call sites can report the same cancellation — the endpoint
    // that asked for it, the webhook that confirms it, the sync behind both, and the reconcile
    // sweep replaying it every hour after that — and with a time bucket in the id the sweep alone
    // would re-report every cancellation it has ever seen, for as long as the row exists.
    assertEquals(event.properties.$insert_id, "cancel:c360_abc_123");
  } finally {
    restore();
  }
});

Deno.test("days_subscribed is computed, and absent rather than wrong", async () => {
  const { calls, restore } = captureFetch();
  try {
    configureMixpanel(configWith("tok"), "test");

    const tenDaysAgo = new Date(Date.now() - 10 * 86_400_000).toISOString();
    await trackCancellation({
      userId: "u1",
      subscriptionId: "s1",
      cancelledBy: "user_in_app",
      startedAt: tenDaysAgo,
    });
    assertEquals(soleEvent(calls).properties.days_subscribed, 10);

    calls.length = 0;
    await trackCancellation({
      userId: "u1",
      subscriptionId: "s2",
      cancelledBy: "system",
      startedAt: "not a date",
    });
    // Null, not NaN or 0: an unparseable start date is unknown, and reporting it as "cancelled
    // on day zero" would invent a churn spike out of missing data.
    assertEquals(soleEvent(calls).properties.days_subscribed, undefined);
  } finally {
    restore();
  }
});
