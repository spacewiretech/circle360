import { fail, json, preflight } from "../_shared/cors.ts";
import { consumeOtpQuota, isValidMobile, serviceClient } from "../_shared/db.ts";
import { loadConfig } from "../_shared/config.ts";
import { devOtpEnabled, warnDevOtp } from "../_shared/dev_otp.ts";
import {
  credentialsFrom,
  Fast2SmsError,
  resendOtp,
  sendOtp,
} from "../_shared/fast2sms.ts";

Deno.serve(async (req) => {
  const cors = preflight(req);
  if (cors) return cors;

  let mobile: unknown;
  try {
    ({ mobile } = await req.json());
  } catch {
    return fail("invalid_request", "Malformed request.", 400);
  }

  if (!isValidMobile(mobile)) {
    return fail("invalid_request", "That mobile number is not valid.", 400);
  }

  const db = serviceClient();
  const config = await loadConfig(db);

  if (devOtpEnabled(config)) {
    warnDevOtp("resend-otp");
    return json({ ok: true, dev: true });
  }

  // A resend costs an SMS just like a send, so it draws on the same quota.
  if (!await consumeOtpQuota(db, mobile)) {
    return fail(
      "throttled",
      "You have requested too many codes. Please try again later.",
      429,
    );
  }

  try {
    await resendOtp(credentialsFrom(config), mobile);
    return json({ ok: true });
  } catch (error) {
    if (error instanceof Fast2SmsError) {
      // 404: the 10-minute redelivery window has closed. Issue a fresh code rather than
      // leaving the user on a dead screen.
      if (error.code === 404) {
        try {
          await sendOtp(credentialsFrom(config), mobile);
          return json({ ok: true, reissued: true });
        } catch (retry) {
          if (retry instanceof Fast2SmsError) {
            if (retry.isConfigurationProblem) console.error(retry.detail);
            return fail("send_failed", retry.userMessage, 502);
          }
          throw retry;
        }
      }

      // 400 on resend is Fast2SMS's own cap of 5 redeliveries per window.
      if (error.code === 400) {
        return fail(
          "throttled",
          "You have requested too many codes. Please try again later.",
          429,
        );
      }

      if (error.isConfigurationProblem) console.error(error.detail);
      return fail("send_failed", error.userMessage, 502);
    }
    console.error("resend-otp failed", error);
    return fail("server_error", "Something went wrong. Please try again.", 500);
  }
});
