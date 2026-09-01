import { fail, json, preflight } from "../_shared/cors.ts";
import {
  hashToken,
  isValidMobile,
  newSessionToken,
  serviceClient,
} from "../_shared/db.ts";
import { loadConfig } from "../_shared/config.ts";
import {
  asUserRow,
  entitlementPayload,
  graceHoursFrom,
  USER_COLUMNS,
} from "../_shared/entitlement.ts";
import { DEV_OTP, devOtpEnabled, warnDevOtp } from "../_shared/dev_otp.ts";
import {
  credentialsFrom,
  Fast2SmsError,
  VerifyResult,
  verifyOtp,
} from "../_shared/fast2sms.ts";

/**
 * The one place a `users` row is created. Verification happens against Fast2SMS first, so a
 * row can only exist for a number whose owner actually received the code.
 */
Deno.serve(async (req) => {
  const cors = preflight(req);
  if (cors) return cors;

  let mobile: unknown;
  let otp: unknown;
  try {
    ({ mobile, otp } = await req.json());
  } catch {
    return fail("invalid_request", "Malformed request.", 400);
  }

  if (!isValidMobile(mobile)) {
    return fail("invalid_request", "That mobile number is not valid.", 400);
  }
  if (typeof otp !== "string" || !/^\d{4,10}$/.test(otp)) {
    return fail("invalid_otp", "That code is not right. Try again.", 400);
  }

  const db = serviceClient();
  const config = await loadConfig(db);

  let result: VerifyResult;
  if (devOtpEnabled(config)) {
    warnDevOtp("verify-otp");
    // Only the SMS check is stubbed. Everything below is the real path — a real users row
    // and a real session token — so the rest of the stack is genuinely exercised.
    result = otp === DEV_OTP ? "verified" : "wrong_code";
  } else {
    try {
      result = await verifyOtp(credentialsFrom(config), mobile, otp);
    } catch (error) {
      if (error instanceof Fast2SmsError) {
        if (error.isConfigurationProblem) console.error(error.detail);
        return fail("send_failed", error.userMessage, 502);
      }
      console.error("verify-otp failed", error);
      return fail("server_error", "Something went wrong. Please try again.", 500);
    }
  }

  if (result === "wrong_code") {
    return fail("invalid_otp", "That code is not right. Try again.", 400);
  }
  if (result === "expired_or_used") {
    return fail(
      "otp_expired",
      "That code has expired. Tap resend to get a new one.",
      400,
    );
  }

  // Upsert, not insert: a returning user verifies the same number again and must land on the
  // row they already own rather than colliding with the unique index.
  const { data: user, error: upsertError } = await db
    .from("users")
    .upsert({ mobile_no: mobile }, { onConflict: "mobile_no", ignoreDuplicates: false })
    .select(USER_COLUMNS)
    .single();

  if (upsertError || !user) {
    console.error("user upsert failed", upsertError);
    return fail("server_error", "Could not complete sign in. Please try again.", 500);
  }

  const row = asUserRow(user);

  // Turn any invite waiting on this number into a real connection, in the same request that
  // created the account. Best-effort: a failure here must never block a sign-in, and the
  // invite stays unclaimed so the next sign-in picks it up.
  const { error: claimError } = await db.rpc("claim_pending_invites", {
    p_user_id: row.user_id,
    p_mobile: mobile,
  });
  if (claimError) console.error("claim_pending_invites failed", claimError);

  const token = newSessionToken();
  const { error: sessionError } = await db.from("user_sessions").insert({
    token_hash: await hashToken(token),
    user_id: row.user_id,
  });

  if (sessionError) {
    console.error("session insert failed", sessionError);
    return fail("server_error", "Could not complete sign in. Please try again.", 500);
  }

  // The raw token is returned exactly once; only its hash is stored.
  //
  // A brand new row is `trial` with a null trial_ends_at, which entitlementPayload reports as
  // entitled: false — so a fresh signup lands on the paywall, not in the app.
  return json({
    user: entitlementPayload(row, graceHoursFrom(config)),
    token,
  });
});
