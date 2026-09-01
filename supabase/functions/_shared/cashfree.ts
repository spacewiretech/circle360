/**
 * Cashfree Subscriptions (UPI Autopay), called with the client secret held server-side.
 *
 * Same reasoning as the Fast2SMS module: the secret never reaches a device. Here it matters
 * twice over, because the same secret both authenticates our API calls and signs the webhooks
 * we trust to move money state — a leaked secret would let anyone forge a "payment succeeded".
 *
 * Amounts and the plan id are read from app_config, never from a request body. A client that
 * can name its own price is a client that pays ₹1.
 */

import { AppConfig, configSetting } from "./config.ts";

const TIMEOUT_MS = 15_000;

export class CashfreeError extends Error {
  constructor(
    readonly status: number | null,
    readonly userMessage: string,
    readonly detail: string,
    /** Set for failures raised locally, before any request went out. */
    readonly isLocalConfigProblem = false,
  ) {
    super(detail);
  }

  /** Retrying a 5xx or a transport failure can work; retrying a 4xx just repeats the mistake. */
  get isTransient(): boolean {
    return this.status === null || this.status >= 500 || this.status === 429;
  }
}

const UNAVAILABLE = "Payments are temporarily unavailable. Please try again.";

// ---------------------------------------------------------------- settings

export interface CashfreeSettings {
  appId: string;
  secret: string;
  baseUrl: string;
  apiVersion: string;
  env: string;
  planId: string;
  trialAmount: number;
  recurringAmount: number;
  trialDays: number;
  graceHours: number;
}

function numberFrom(config: AppConfig, key: string, fallback: number): number {
  const parsed = Number(configSetting(config, key));
  return Number.isFinite(parsed) && parsed >= 0 ? parsed : fallback;
}

/**
 * Throws when the credentials are missing rather than falling back to sandbox.
 *
 * Failing closed is the only safe default: a silent sandbox fallback would hand out working
 * trials that never charge anyone, and nobody would notice until the month-end reconciliation.
 */
export function cashfreeSettings(config: AppConfig): CashfreeSettings {
  const appId = configSetting(config, "cashfree_app_id");
  const secret = configSetting(config, "cashfree_secret_key");

  if (!appId || !secret) {
    throw new CashfreeError(
      null,
      UNAVAILABLE,
      `app_config is missing ${!appId ? "cashfree_app_id" : ""}${
        !appId && !secret ? " and " : ""
      }${!secret ? "cashfree_secret_key" : ""}`,
      true,
    );
  }

  const env = (configSetting(config, "cashfree_env") || "production").toLowerCase();

  return {
    appId,
    secret,
    env,
    baseUrl: env === "sandbox"
      ? "https://sandbox.cashfree.com/pg"
      : "https://api.cashfree.com/pg",
    apiVersion: configSetting(config, "cashfree_api_version") || "2025-01-01",
    planId: configSetting(config, "cashfree_plan_id"),
    trialAmount: numberFrom(config, "cashfree_trial_amount", 3),
    recurringAmount: numberFrom(config, "cashfree_recurring_amount", 499),
    trialDays: numberFrom(config, "cashfree_trial_days", 2),
    graceHours: numberFrom(config, "entitlement_grace_hours", 12),
  };
}

// ---------------------------------------------------------------- transport

async function request(
  settings: CashfreeSettings,
  method: "GET" | "POST",
  path: string,
  body?: Record<string, unknown>,
  idempotencyKey?: string,
): Promise<Record<string, unknown>> {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), TIMEOUT_MS);

  const headers: Record<string, string> = {
    "x-client-id": settings.appId,
    "x-client-secret": settings.secret,
    "x-api-version": settings.apiVersion,
    "Content-Type": "application/json",
    "Accept": "application/json",
  };
  if (idempotencyKey) headers["x-idempotency-key"] = idempotencyKey;

  let response: Response;
  try {
    response = await fetch(`${settings.baseUrl}${path}`, {
      method,
      headers,
      body: body ? JSON.stringify(body) : undefined,
      signal: controller.signal,
    });
  } catch (error) {
    throw new CashfreeError(
      null,
      "Could not reach the payment service. Please try again.",
      `fetch failed on ${method} ${path}: ${error}`,
    );
  } finally {
    clearTimeout(timer);
  }

  const raw = await response.text();
  let decoded: Record<string, unknown>;
  try {
    decoded = raw ? JSON.parse(raw) : {};
  } catch {
    throw new CashfreeError(
      response.status,
      UNAVAILABLE,
      `unreadable body on ${method} ${path} (HTTP ${response.status}): ${raw.slice(0, 300)}`,
    );
  }

  if (!response.ok) {
    const message = String(decoded.message ?? decoded.error_description ?? "no message");
    const code = String(decoded.code ?? decoded.type ?? "");
    throw new CashfreeError(
      response.status,
      UNAVAILABLE,
      `Cashfree ${response.status} on ${method} ${path}: ${code} ${message}`,
    );
  }

  return decoded;
}

// ---------------------------------------------------------------- time

/** 
 * Cashfree stores and expects IST. Everything on our side is `timestamptz` compared in UTC, so
 * the conversion lives here and only here — a stray local-time format string is exactly the
 * kind of bug that silently bills people five and a half hours early.
 */
export function toIstIso(date: Date): string {
  const ist = new Date(date.getTime() + 5.5 * 60 * 60 * 1000);
  const p = (n: number) => String(n).padStart(2, "0");
  return `${ist.getUTCFullYear()}-${p(ist.getUTCMonth() + 1)}-${p(ist.getUTCDate())}` +
    `T${p(ist.getUTCHours())}:${p(ist.getUTCMinutes())}:${p(ist.getUTCSeconds())}+05:30`;
}

export function addDays(date: Date, days: number): Date {
  return new Date(date.getTime() + days * 24 * 60 * 60 * 1000);
}

export function addMonths(date: Date, months: number): Date {
  const next = new Date(date.getTime());
  const day = next.getUTCDate();
  next.setUTCMonth(next.getUTCMonth() + months);
  // Jan 31 + 1 month would roll into March. Clamp back to the last day of the target month so
  // a subscription started on the 31st bills on the 28th/30th rather than skipping a month.
  if (next.getUTCDate() < day) next.setUTCDate(0);
  return next;
}

function parseDate(value: unknown): string | null {
  if (typeof value !== "string" || !value.trim()) return null;
  const parsed = new Date(value);
  return Number.isNaN(parsed.getTime()) ? null : parsed.toISOString();
}

// ---------------------------------------------------------------- API calls

export interface CreateSubscriptionInput {
  subscriptionId: string;
  customerName: string;
  customerPhone: string;
  customerEmail: string;
  firstChargeTime: Date;
  sessionExpiry: Date;
  returnUrl: string;
}

export function createSubscription(
  settings: CashfreeSettings,
  input: CreateSubscriptionInput,
): Promise<Record<string, unknown>> {
  return request(
    settings,
    "POST",
    "/subscriptions",
    {
      subscription_id: input.subscriptionId,
      customer_details: {
        customer_name: input.customerName,
        customer_phone: input.customerPhone,
        customer_email: input.customerEmail,
      },
      // Only the id. The amount and interval live in the Cashfree dashboard, so there is no
      // path by which a request body can change what a subscriber is billed.
      plan_details: { plan_id: settings.planId },
      authorization_details: {
        authorization_amount: settings.trialAmount,
        // False is what turns the authorisation into a kept trial fee. Left true, Cashfree
        // refunds it automatically and the ₹3 the user was promised would silently come back.
        authorization_amount_refund: false,
        payment_methods: ["upi"],
        upi: {
        upi_type: "intent",
        upi_app: "googlepay"
        }
      },
      subscription_first_charge_time: toIstIso(input.firstChargeTime),
      // Far enough out that the mandate never lapses on its own; cancellation is explicit.
      subscription_expiry_time: toIstIso(addDays(new Date(), 3650)),
      subscription_meta: {
        return_url: input.returnUrl,
        // SMS, not email: the address we send is synthesised from the phone number and nobody
        // reads it. The pre-debit notice has to reach a human.
        notification_channel: ["SMS"],
        session_id_expiry: toIstIso(input.sessionExpiry),
      },
    },
    // Same key as the subscription id, so a retried create returns the original rather than
    // opening a second mandate.
    input.subscriptionId,
  );
}

/**
 * The source of truth for every state transition.
 *
 * Webhook payload shapes differ per event type and per API version, so nothing downstream
 * trusts them — the webhook records what it was sent, then calls this and writes absolute
 * state from the answer. That is what makes duplicate and out-of-order deliveries harmless.
 */
export function fetchSubscription(
  settings: CashfreeSettings,
  subscriptionId: string,
): Promise<Record<string, unknown>> {
  return request(settings, "GET", `/subscriptions/${encodeURIComponent(subscriptionId)}`);
}

export function cancelSubscription(
  settings: CashfreeSettings,
  subscriptionId: string,
): Promise<Record<string, unknown>> {
  return request(
    settings,
    "POST",
    `/subscriptions/${encodeURIComponent(subscriptionId)}/manage`,
    { subscription_id: subscriptionId, action: "CANCEL" },
    `cancel_${subscriptionId}`,
  );
}

// ---------------------------------------------------------------- snapshot

/** The fields we persist, pulled out of Cashfree's response shape in one place. */
export interface SubscriptionSnapshot {
  subscriptionId: string | null;
  cfSubscriptionId: string | null;
  status: string;
  sessionId: string | null;
  authorizationAmount: number | null;
  recurringAmount: number | null;
  firstChargeTime: string | null;
  nextScheduleDate: string | null;
  authorizedAt: string | null;
  raw: Record<string, unknown>;
}

function numberOrNull(value: unknown): number | null {
  const parsed = typeof value === "number" ? value : Number(value);
  return Number.isFinite(parsed) ? parsed : null;
}

export function snapshotOf(cf: Record<string, unknown>): SubscriptionSnapshot {
  const auth = (cf.authorisation_details ?? cf.authorization_details ?? {}) as Record<
    string,
    unknown
  >;
  const plan = (cf.plan_details ?? {}) as Record<string, unknown>;

  return {
    subscriptionId: typeof cf.subscription_id === "string" ? cf.subscription_id : null,
    cfSubscriptionId: cf.cf_subscription_id != null ? String(cf.cf_subscription_id) : null,
    status: typeof cf.subscription_status === "string" ? cf.subscription_status : "UNKNOWN",
    sessionId: typeof cf.subscription_session_id === "string"
      ? cf.subscription_session_id
      : null,
    authorizationAmount: numberOrNull(auth.authorization_amount),
    recurringAmount: numberOrNull(plan.plan_recurring_amount ?? plan.plan_amount),
    firstChargeTime: parseDate(cf.subscription_first_charge_time),
    nextScheduleDate: parseDate(cf.next_schedule_date),
    authorizedAt: parseDate(auth.authorization_time),
    raw: cf,
  };
}

/** Cashfree states in which the mandate can still charge, or still might start charging. */
export function isLiveStatus(status: string): boolean {
  return ["INITIALIZED", "PENDING_AUTHORIZATION", "ACTIVE", "ON_HOLD", "BANK_APPROVAL_PENDING"]
    .includes(status);
}

// ---------------------------------------------------------------- webhooks

const encoder = new TextEncoder();

/**
 * `base64(HMAC-SHA256(x-webhook-timestamp + rawBody, clientSecret))`.
 *
 * [rawBody] must be the exact bytes Cashfree sent. Re-serialising the parsed JSON reorders
 * keys and drops whitespace, and the signature stops matching for reasons no log will explain.
 */
export async function webhookSignature(
  secret: string,
  timestamp: string,
  rawBody: string,
): Promise<string> {
  const key = await crypto.subtle.importKey(
    "raw",
    encoder.encode(secret),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const mac = await crypto.subtle.sign("HMAC", key, encoder.encode(timestamp + rawBody));
  return btoa(String.fromCharCode(...new Uint8Array(mac)));
}

/** Length-independent, value-independent comparison, so timing cannot leak the signature. */
export function constantTimeEquals(a: string, b: string): boolean {
  if (a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) diff |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return diff === 0;
}

export async function verifyWebhook(
  secret: string,
  timestamp: string | null,
  signature: string | null,
  rawBody: string,
): Promise<boolean> {
  if (!secret || !timestamp || !signature) return false;
  return constantTimeEquals(await webhookSignature(secret, timestamp, rawBody), signature);
}

/**
 * Stable identity for one delivery, so a redelivery collides on the unique index and no-ops.
 * The body alone is not enough — Cashfree can send the same body for a retry of a different
 * event — and the timestamp alone is not enough either, hence both plus the type.
 */
export async function dedupeKey(
  eventType: string,
  timestamp: string,
  rawBody: string,
): Promise<string> {
  const digest = await crypto.subtle.digest(
    "SHA-256",
    encoder.encode(`${eventType}|${timestamp}|${rawBody}`),
  );
  return [...new Uint8Array(digest)].map((b) => b.toString(16).padStart(2, "0")).join("");
}

/**
 * Cashfree nests the subscription id differently per event type — sometimes at `data`,
 * sometimes under `data.subscription_details`, sometimes under a `subscription_status_webhook`
 * wrapper. Rather than a switch per event, walk the few known shapes and take the first hit.
 */
export function subscriptionIdsFrom(
  payload: Record<string, unknown>,
): { subscriptionId: string | null; cfSubscriptionId: string | null } {
  const data = (payload.data ?? {}) as Record<string, unknown>;
  const candidates: Record<string, unknown>[] = [
    data,
    (data.subscription_details ?? {}) as Record<string, unknown>,
    ((data.subscription_status_webhook ?? {}) as Record<string, unknown>)
      .subscription_details as Record<string, unknown> ?? {},
    payload,
  ];

  let subscriptionId: string | null = null;
  let cfSubscriptionId: string | null = null;

  for (const source of candidates) {
    if (!subscriptionId && typeof source.subscription_id === "string") {
      subscriptionId = source.subscription_id;
    }
    if (!cfSubscriptionId && source.cf_subscription_id != null) {
      cfSubscriptionId = String(source.cf_subscription_id);
    }
  }

  return { subscriptionId, cfSubscriptionId };
}

/** The payment fields, for the events that carry one. Null when the event is not a charge. */
export interface WebhookPayment {
  cfPaymentId: string;
  amount: number | null;
  currency: string;
  status: string;
  paymentTime: string | null;
  failureReason: string | null;
  /** The untouched `data` block, kept for disputes months after the fact. */
  raw: Record<string, unknown>;
}

export function paymentFrom(payload: Record<string, unknown>): WebhookPayment | null {
  const data = (payload.data ?? {}) as Record<string, unknown>;
  const failure = (data.failure_details ?? {}) as Record<string, unknown>;

  const cfPaymentId = data.cf_payment_id ?? data.payment_id;
  if (cfPaymentId == null) return null;

  return {
    cfPaymentId: String(cfPaymentId),
    amount: numberOrNull(data.payment_amount),
    currency: typeof data.payment_currency === "string" ? data.payment_currency : "INR",
    status: typeof data.payment_status === "string" ? data.payment_status : "UNKNOWN",
    paymentTime: parseDate(data.payment_time ?? data.payment_completion_time),
    failureReason: typeof failure.failure_reason === "string"
      ? failure.failure_reason
      : typeof data.failure_reason === "string"
      ? data.failure_reason
      : null,
    raw: data,
  };
}
