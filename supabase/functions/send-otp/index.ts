import { fail, json, preflight } from "../_shared/cors.ts";
import { consumeOtpQuota, isValidMobile, serviceClient } from "../_shared/db.ts";
import { loadConfig } from "../_shared/config.ts";
import { devOtpEnabled, warnDevOtp } from "../_shared/dev_otp.ts";
import { credentialsFrom, Fast2SmsError, sendOtp } from "../_shared/fast2sms.ts";

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
    warnDevOtp("send-otp");
    // No quota is spent because no SMS is sent.
    return json({ ok: true, dev: true });
  }

  if (!await consumeOtpQuota(db, mobile)) {
    return fail(
      "throttled",
      "Too many codes requested for this number. Please try again later.",
      429,
    );
  }

  try {
    await sendOtp(credentialsFrom(config), mobile);
    return json({ ok: true });
  } catch (error) {
    if (error instanceof Fast2SmsError) {
      // The real cause of a configuration failure stays in the logs, never on a user's screen.
      if (error.isConfigurationProblem) console.error(error.detail);
      return fail("send_failed", error.userMessage, 502);
    }
    console.error("send-otp failed", error);
    return fail("server_error", "Something went wrong. Please try again.", 500);
  }
});
