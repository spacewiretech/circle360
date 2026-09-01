import { SupabaseClient } from "jsr:@supabase/supabase-js@2";

/**
 * Runtime config read from `app_config`, including the private rows the anon key cannot see.
 *
 * Read with the service_role client, so `is_public = false` rows come back here and nowhere
 * else. Never return this map to a caller — it holds the Fast2SMS credentials.
 */
export type AppConfig = Map<string, string>;

/**
 * Edge Function instances are reused across requests, so a module-level cache turns a
 * per-request database round trip into one every [ttlMs]. Short enough that a dashboard edit
 * takes effect within a minute without a redeploy.
 */
let cache: { at: number; config: AppConfig } | null = null;
const ttlMs = 60_000;

export async function loadConfig(
  db: SupabaseClient,
  { force = false }: { force?: boolean } = {},
): Promise<AppConfig> {
  if (!force && cache && Date.now() - cache.at < ttlMs) return cache.config;

  const { data, error } = await db.from("app_config").select("key, value");
  if (error) {
    // Serving stale config beats failing the request outright; only a cold instance with no
    // cache has nothing to fall back on.
    console.error("app_config read failed", error);
    if (cache) return cache.config;
    throw new Error(`app_config unavailable: ${error.message}`);
  }

  const config: AppConfig = new Map(
    (data ?? []).map((row) => [
      String(row.key).trim(),
      String(row.value ?? "").trim(),
    ]),
  );

  cache = { at: Date.now(), config };
  return config;
}

export function configValue(config: AppConfig, key: string): string {
  return config.get(key) ?? "";
}

/**
 * Values people type into a dashboard cell to mean "nothing yet".
 *
 * Without this, a `-` placeholder in `fast2sms_otp_id` reads as a configured template: the dev
 * bypass stays off and every send goes to Fast2SMS as `otp_id: "-"`, failing with
 * `Invalid OTP ID` and no obvious cause.
 */
const placeholders = new Set([
  "",
  "-",
  "--",
  "n/a",
  "na",
  "none",
  "null",
  "todo",
  "tbd",
  "xxx",
]);

export function isUnset(value: string): boolean {
  return placeholders.has(value.trim().toLowerCase());
}

/** Like [configValue], but placeholder text collapses to an empty string. */
export function configSetting(config: AppConfig, key: string): string {
  const value = configValue(config, key);
  return isUnset(value) ? "" : value;
}

export function configFlag(config: AppConfig, key: string): boolean {
  return configValue(config, key).toLowerCase() === "true";
}
