import { SupabaseClient } from "jsr:@supabase/supabase-js@2";

import { AppConfig, configSetting } from "./config.ts";
import { isValidMobile } from "./db.ts";

/**
 * One fixed-code sign-in for Google Play and App Store reviewers.
 *
 * Both stores require a working demo login, and neither reviewer can receive an Indian SMS.
 * This is deliberately *not* [devOtpEnabled]: that one accepts a fixed code for **every**
 * number and is therefore only safe while no SMS template exists. This is scoped to a single
 * configured number, so it can stay on in production while every other number keeps going
 * through Fast2SMS.
 *
 * Everything downstream of the code check is the real path — a real `users` row and a real
 * session token — so the reviewer exercises the same stack a paying user does. That is the
 * whole point: the client-side shortcut this replaces minted no token, so every authed call
 * after sign-in failed and the reviewer would have been stranded on the paywall.
 *
 * Off unless both `review_mobile` and `review_otp` are set to well-formed values, so an
 * untouched deployment has no fixed-code account at all.
 */
export type ReviewAccount = { mobile: string; otp: string };

export function reviewAccount(config: AppConfig): ReviewAccount | null {
  const mobile = configSetting(config, "review_mobile");
  const otp = configSetting(config, "review_otp");

  // Same shapes the functions already enforce on a real request. A half-filled pair — a number
  // with no code, or a code typed into the wrong row — leaves the account off rather than
  // opening a number whose code is the empty string.
  if (!isValidMobile(mobile)) return null;
  if (!/^\d{4,10}$/.test(otp)) return null;

  return { mobile, otp };
}

/** Whether [mobile] is the configured review number. */
export function isReviewMobile(config: AppConfig, mobile: string): boolean {
  return reviewAccount(config)?.mobile === mobile;
}

/**
 * Verify attempts allowed per hour against the review code.
 *
 * A fixed six-digit code that never rotates is brute-forceable given unlimited guesses, and
 * unlike a real OTP there is no Fast2SMS in front of it doing its own counting. Ten an hour
 * puts a six-digit space out of reach while leaving a reviewer who fat-fingers the code plenty
 * of room.
 */
const maxVerifyAttempts = 10;

/**
 * Claims one verify attempt for the review number.
 *
 * Reuses `consume_otp_quota` under a namespaced key: the throttle table is keyed by plain text
 * and the review number spends no send quota, so a prefix keeps verify counting separate from
 * the send budget of a real number that happens to be the same digits.
 */
export async function consumeReviewVerifyQuota(
  db: SupabaseClient,
  mobile: string,
): Promise<boolean> {
  const { data, error } = await db.rpc("consume_otp_quota", {
    p_mobile: `review-verify:${mobile}`,
    p_max: maxVerifyAttempts,
  });
  if (error) {
    // Fail closed, as with the send quota: an uncheckable throttle must not become no throttle.
    console.error("review verify quota failed", error);
    return false;
  }
  return data === true;
}

export function warnReviewAccount(fn: string): void {
  console.warn(
    `[${fn}] REVIEW ACCOUNT SIGN-IN — fixed-code path used for the configured store-review ` +
      `number. Clear app_config.review_mobile once the app is out of review.`,
  );
}
