import { loadConfig } from "../_shared/config.ts";
import { fail, json, preflight } from "../_shared/cors.ts";
import { hashToken, serviceClient, userIdForBearer } from "../_shared/db.ts";
import {
  asUserRow,
  entitlementPayload,
  graceHoursFrom,
  USER_COLUMNS,
} from "../_shared/entitlement.ts";

/**
 * Resolves a stored session token back to its user, so a relaunch can restore the session
 * without asking for the OTP again — and so a revoked or expired token is actually rejected
 * rather than trusted from the device's own cache.
 *
 * DELETE signs out by dropping the session row.
 */
Deno.serve(async (req) => {
  const cors = preflight(req);
  if (cors) return cors;

  const db = serviceClient();
  const authorization = req.headers.get("Authorization");
  const userId = await userIdForBearer(db, authorization);

  if (!userId) return fail("unauthorized", "Please sign in again.", 401);

  if (req.method === "DELETE") {
    const token = authorization!.replace(/^Bearer\s+/i, "").trim();
    await db.from("user_sessions").delete().eq("token_hash", await hashToken(token));
    return json({ ok: true });
  }

  const { data: user, error } = await db
    .from("users")
    .select(USER_COLUMNS)
    .eq("user_id", userId)
    .single();

  if (error || !user) {
    console.error("me lookup failed", error);
    return fail("server_error", "Something went wrong. Please try again.", 500);
  }

  const config = await loadConfig(db);
  return json({ user: entitlementPayload(asUserRow(user), graceHoursFrom(config)) });
});
