/**
 * Tests for the store-review sign-in gate.
 *
 * This is a fixed credential that stays live in production, so the thing worth pinning down is
 * when it is *off*: a half-filled config, a placeholder left in a cell, or any number other
 * than the configured one must all fall through to the real Fast2SMS path. Run with:
 *
 *   deno test --allow-none supabase/functions/tests/review_account_test.ts
 */

import { assertEquals, assertFalse } from "jsr:@std/assert@1";

import { AppConfig } from "../_shared/config.ts";
import { isReviewMobile, reviewAccount } from "../_shared/review_account.ts";

const REVIEW_MOBILE = "9931133385";
const REVIEW_OTP = "123456";

function config(entries: Record<string, string>): AppConfig {
  return new Map(Object.entries(entries));
}

const configured = config({
  review_mobile: REVIEW_MOBILE,
  review_otp: REVIEW_OTP,
});

Deno.test("a fully configured pair opens exactly that number", () => {
  assertEquals(reviewAccount(configured), {
    mobile: REVIEW_MOBILE,
    otp: REVIEW_OTP,
  });
  assertEquals(isReviewMobile(configured, REVIEW_MOBILE), true);
});

Deno.test("every other number is untouched", () => {
  assertFalse(isReviewMobile(configured, "9931145610"));
  // One digit off, and a prefix/suffix of the real thing: the match is exact, not partial.
  assertFalse(isReviewMobile(configured, "9931133386"));
  assertFalse(isReviewMobile(configured, "993113338"));
});

Deno.test("an untouched deployment has no review account", () => {
  assertEquals(reviewAccount(config({})), null);
  assertEquals(
    reviewAccount(config({ review_mobile: "", review_otp: "" })),
    null,
  );
  assertFalse(isReviewMobile(config({}), REVIEW_MOBILE));
});

Deno.test("a half-filled pair stays off", () => {
  // The dangerous direction: a number with no code must not open with the empty string.
  assertEquals(reviewAccount(config({ review_mobile: REVIEW_MOBILE })), null);
  assertEquals(reviewAccount(config({ review_otp: REVIEW_OTP })), null);
});

Deno.test("placeholder text does not configure an account", () => {
  for (const placeholder of ["-", "n/a", "none", "TBD", "  "]) {
    assertEquals(
      reviewAccount(config({
        review_mobile: placeholder,
        review_otp: REVIEW_OTP,
      })),
      null,
      `mobile placeholder ${placeholder} should stay off`,
    );
    assertEquals(
      reviewAccount(config({
        review_mobile: REVIEW_MOBILE,
        review_otp: placeholder,
      })),
      null,
      `otp placeholder ${placeholder} should stay off`,
    );
  }
});

Deno.test("malformed values stay off rather than half-working", () => {
  const bad: Array<[string, string]> = [
    ["12345", REVIEW_OTP], // too short
    ["99311333850", REVIEW_OTP], // too long
    ["1931133385", REVIEW_OTP], // Indian mobiles start 6-9
    ["99311a3385", REVIEW_OTP], // not digits
    [REVIEW_MOBILE, "12"], // code too short to be worth having
    [REVIEW_MOBILE, "12345678901"], // longer than verify-otp accepts
    [REVIEW_MOBILE, "12a456"], // not digits
  ];

  for (const [mobile, otp] of bad) {
    assertEquals(
      reviewAccount(config({ review_mobile: mobile, review_otp: otp })),
      null,
      `${mobile}/${otp} should stay off`,
    );
  }
});
