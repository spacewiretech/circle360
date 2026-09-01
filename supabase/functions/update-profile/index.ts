import { loadConfig } from "../_shared/config.ts";
import { fail, json, preflight } from "../_shared/cors.ts";
import { serviceClient, userIdForBearer } from "../_shared/db.ts";
import {
  asUserRow,
  entitlementPayload,
  graceHoursFrom,
  USER_COLUMNS,
} from "../_shared/entitlement.ts";

/**
 * Sets the name collected on the step after OTP.
 *
 * The user id comes from the session token, never from the request body — otherwise anyone
 * could rename any account by guessing a uuid.
 */
Deno.serve(async (req) => {
  const cors = preflight(req);
  if (cors) return cors;

  const db = serviceClient();
  const userId = await userIdForBearer(db, req.headers.get("Authorization"));
  if (!userId) {
    return fail("unauthorized", "Please sign in again.", 401);
  }

  let name: unknown;
  try {
    ({ name } = await req.json());
  } catch {
    return fail("invalid_request", "Malformed request.", 400);
  }

  const trimmed = typeof name === "string" ? name.trim() : "";
  if (trimmed.length < 1 || trimmed.length > 80) {
    return fail("invalid_request", "Please enter your name.", 400);
  }

  const { data: user, error } = await db
    .from("users")
    .update({ name: trimmed })
    .eq("user_id", userId)
    .select(USER_COLUMNS)
    .single();

  if (error || !user) {
    console.error("profile update failed", error);
    return fail("server_error", "Could not save your name. Please try again.", 500);
  }

  const config = await loadConfig(db);
  return json({ user: entitlementPayload(asUserRow(user), graceHoursFrom(config)) });
});
