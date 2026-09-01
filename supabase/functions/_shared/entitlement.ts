/**
 * The single place "is this account allowed into the app" is decided.
 *
 * `me`, `subscription-status`, `subscription-start` and the webhook all call this. If the rule
 * lived in more than one place, the paywall and the billing sweep would eventually disagree,
 * and the disagreement would be discovered by a paying customer being locked out.
 *
 * Entitlement is derived, never stored. A stalled webhook therefore expires an account by the
 * clock instead of leaving it entitled indefinitely, and a successful renewal is nothing more
 * than a date moving forward.
 */

import { AppConfig, configSetting } from "./config.ts";

export type PaymentType = "trial" | "active" | "expired" | "cancelled";

/**
 * How long access survives past an expiry while a debit settles.
 *
 * Read here rather than through `cashfreeSettings()` on purpose: the functions that only need
 * to answer "is this user entitled" must keep working when the Cashfree credentials are unset,
 * or a payment misconfiguration would sign every user out.
 */
export function graceHoursFrom(config: AppConfig): number {
  const parsed = Number(configSetting(config, "entitlement_grace_hours"));
  return Number.isFinite(parsed) && parsed >= 0 ? parsed : 12;
}

export interface UserRow {
  user_id: string;
  mobile_no: string;
  name: string | null;
  creation_time?: string;
  payment_type: PaymentType;
  trial_ends_at: string | null;
  current_period_end: string | null;
  active_subscription_id: string | null;
}

/**
 * Every read of `users` that feeds an entitlement decision selects exactly this.
 *
 * Shared rather than written out per function so none of them can quietly forget
 * `trial_ends_at` — a missing column there reads as "trial never started" and would report
 * every trial user as unentitled.
 */
export const USER_COLUMNS =
  "user_id, mobile_no, name, creation_time, payment_type, trial_ends_at, " +
  "current_period_end, active_subscription_id";

/**
 * supabase-js derives a row type by parsing the *literal* select string, so passing the
 * constant above leaves it with `GenericStringError`. The cast is unavoidable; it lives here
 * once instead of being spelled out at a dozen call sites.
 */
export function asUserRow(row: unknown): UserRow {
  return row as UserRow;
}

function isFuture(value: string | null, graceMs: number, now: number): boolean {
  if (!value) return false;
  const at = new Date(value).getTime();
  return Number.isFinite(at) && now < at + graceMs;
}

export function isEntitled(
  user: Pick<UserRow, "payment_type" | "trial_ends_at" | "current_period_end">,
  graceHours: number,
  now: Date = new Date(),
): boolean {
  const graceMs = Math.max(0, graceHours) * 60 * 60 * 1000;
  const ts = now.getTime();

  switch (user.payment_type) {
    case "active":
      // A null period end means a mandate that is active but has not billed yet — which only
      // happens in the window between authorisation and the first debit. Allow it.
      return user.current_period_end === null ||
        isFuture(user.current_period_end, graceMs, ts);

    case "trial":
      // Null means the trial never started: the row exists but the ₹3 was never captured.
      // That is the state every new signup is in, and it must not grant access.
      return isFuture(user.trial_ends_at, graceMs, ts);

    case "cancelled":
      // Paid time is honoured, but no grace — they chose to leave, so there is no in-flight
      // debit to wait for.
      return isFuture(user.current_period_end, 0, ts);

    case "expired":
    default:
      return false;
  }
}

/** True while the user is inside the paid-for trial, so the app can say so. */
export function isInTrial(user: UserRow, graceHours: number, now: Date = new Date()): boolean {
  return user.payment_type === "trial" && isEntitled(user, graceHours, now);
}

/**
 * The user object every function returns to the app.
 *
 * `entitled` is computed here rather than left to the client. The client still re-derives it
 * from the dates when it is offline, but it never gets to decide the answer while online.
 */
export function entitlementPayload(
  user: UserRow,
  graceHours: number,
  now: Date = new Date(),
): Record<string, unknown> {
  return {
    user_id: user.user_id,
    mobile_no: user.mobile_no,
    name: user.name,
    payment_type: user.payment_type,
    trial_ends_at: user.trial_ends_at,
    current_period_end: user.current_period_end,
    entitled: isEntitled(user, graceHours, now),
    in_trial: isInTrial(user, graceHours, now),
  };
}
