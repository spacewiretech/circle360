/**
 * Fast2SMS OTP endpoints, called with the API key held server-side.
 *
 * This is the whole point of routing OTP through Edge Functions: the key never reaches a
 * device, where it would be extractable from the app bundle.
 */

import { AppConfig, configSetting } from "./config.ts";

const BASE = "https://www.fast2sms.com";
const TIMEOUT_MS = 20_000;

export const OTP_LENGTH = 6;
export const OTP_EXPIRY_MINUTES = 5;

export class Fast2SmsError extends Error {
  constructor(
    readonly code: number | null,
    readonly userMessage: string,
    readonly detail: string,
    /** Set for failures raised locally, before any request went out. */
    readonly isLocalConfigProblem = false,
  ) {
    super(detail);
  }

  /** True when the fix is on the account or in the function secrets, not anything a user did. */
  get isConfigurationProblem(): boolean {
    // A missing secret carries no status code, so it has to be flagged explicitly — without
    // this it would be the one failure that never reaches the logs.
    if (this.isLocalConfigProblem) return true;

    return this.code !== null &&
      [
        400, 401, 402, 403, 405, 406, 407, 408, 409, 410, 412, 413, 414, 415,
        416, 417, 424, 425, 426, 500, 990, 996, 999,
      ].includes(this.code);
  }
}

/** Read from app_config private rows, never from the device. */
export interface Fast2SmsCredentials {
  apiKey: string;
  otpId: string;
}

export function credentialsFrom(config: AppConfig): Fast2SmsCredentials {
  return {
    apiKey: configSetting(config, "fast2sms_api_key"),
    otpId: configSetting(config, "fast2sms_otp_id"),
  };
}

const UNAVAILABLE =
  "Verification is temporarily unavailable. Please try again later.";

/** Codes from https://docs.fast2sms.com/reference/error-code-list */
function userMessageFor(code: number | null): string {
  switch (code) {
    case 411:
      return "That mobile number is not valid.";
    case 995:
      return "Too many codes requested for this number. Please wait a few minutes.";
    default:
      return UNAVAILABLE;
  }
}

async function post(
  apiKey: string,
  path: string,
  body: Record<string, unknown>,
): Promise<Record<string, unknown>> {
  if (!apiKey) {
    throw new Fast2SmsError(
      null,
      UNAVAILABLE,
      "app_config.fast2sms_api_key is empty",
      true,
    );
  }

  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), TIMEOUT_MS);

  let response: Response;
  try {
    response = await fetch(`${BASE}${path}`, {
      method: "POST",
      headers: {
        "Authorization": apiKey,
        "Content-Type": "application/json",
        "Accept": "application/json",
      },
      body: JSON.stringify(body),
      signal: controller.signal,
    });
  } catch (error) {
    throw new Fast2SmsError(
      null,
      "Could not reach the verification service. Please try again.",
      `fetch failed on ${path}: ${error}`,
    );
  } finally {
    clearTimeout(timer);
  }

  const raw = await response.text();
  let decoded: Record<string, unknown>;
  try {
    decoded = JSON.parse(raw);
  } catch {
    throw new Fast2SmsError(
      null,
      "Something went wrong. Please try again.",
      `unreadable body on ${path} (HTTP ${response.status}): ${raw.slice(0, 200)}`,
    );
  }

  // Fast2SMS reports failures as return:false inside an HTTP 200 as readily as with a 4xx,
  // so the body decides — never the status line.
  if (decoded.return === true) return decoded;

  const code = typeof decoded.status_code === "number"
    ? decoded.status_code
    : typeof decoded.status_code === "string"
    ? Number(decoded.status_code)
    : response.status === 200
    ? null
    : response.status;

  const providerMessage = Array.isArray(decoded.message)
    ? decoded.message.join(", ")
    : String(decoded.message ?? "no message");

  throw new Fast2SmsError(
    code,
    userMessageFor(code),
    `Fast2SMS ${code ?? "transport"}: ${providerMessage}`,
  );
}

export function sendOtp(creds: Fast2SmsCredentials, mobile: string) {
  const { apiKey, otpId } = creds;
  if (!otpId) {
    throw new Fast2SmsError(
      null,
      UNAVAILABLE,
      "app_config.fast2sms_otp_id is empty",
      true,
    );
  }
  return post(apiKey, "/dev/otp/send", {
    mobile,
    otp_id: otpId,
    otp_length: OTP_LENGTH,
    otp_expiry: OTP_EXPIRY_MINUTES,
  });
}

/**
 * Redelivers the code from the last send. Valid for 10 minutes and capped at 5 attempts
 * server-side; 404 means that window has closed, so the caller issues a fresh code instead.
 */
export function resendOtp(creds: Fast2SmsCredentials, mobile: string) {
  return post(creds.apiKey, "/dev/otp/resend", { mobile });
}

export type VerifyResult = "verified" | "wrong_code" | "expired_or_used";

export async function verifyOtp(
  creds: Fast2SmsCredentials,
  mobile: string,
  otp: string,
): Promise<VerifyResult> {
  try {
    await post(creds.apiKey, "/dev/otp/verify", { mobile, otp });
    return "verified";
  } catch (error) {
    if (error instanceof Fast2SmsError) {
      // 400 covers a wrong code, an expired one and too many attempts; 404 means there is no
      // outstanding OTP, so it was already used or has aged out.
      if (error.code === 400) return "wrong_code";
      if (error.code === 404) return "expired_or_used";
    }
    throw error;
  }
}
