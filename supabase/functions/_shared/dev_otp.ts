import { AppConfig, configFlag, configSetting } from "./config.ts";

/**
 * Development stand-in for Fast2SMS, so the rest of the stack — user rows, session tokens,
 * the name step — can be exercised before an OTP template exists.
 *
 * Two independent conditions must hold, so this cannot switch itself on in production:
 *
 *   1. `fast2sms_otp_id` is empty, or holds placeholder text such as "-". The moment a real
 *      template is configured, this goes inert on its own, with no flag to remember to unset.
 *   2. `allow_dev_otp` is explicitly "true". A blank or missing value is off.
 *
 * If it were gated on only the missing template, a deployment that lost its credentials would
 * silently start accepting a fixed code for every number.
 */
export function devOtpEnabled(config: AppConfig): boolean {
  const hasTemplate = configSetting(config, "fast2sms_otp_id").length > 0;
  return !hasTemplate && configFlag(config, "allow_dev_otp");
}

/** The only code accepted while the bypass is active. */
export const DEV_OTP = "000000";

export function warnDevOtp(fn: string): void {
  console.warn(
    `[${fn}] DEV OTP BYPASS ACTIVE — no SMS sent and "${DEV_OTP}" is accepted for any ` +
      `number. Set app_config.fast2sms_otp_id to disable, or set allow_dev_otp to false.`,
  );
}
