import { loadConfig } from "../_shared/config.ts";
import { fail, json, preflight } from "../_shared/cors.ts";
import { serviceClient, userIdForBearer } from "../_shared/db.ts";
import {
  asUserRow,
  graceHoursFrom,
  isEntitled,
  USER_COLUMNS,
} from "../_shared/entitlement.ts";

/**
 * Where every device's position lands. Called from Kotlin/Swift every 10 seconds per device,
 * so it stays deliberately thin: authenticate, check entitlement, upsert one row.
 *
 * The two failure codes matter more than the success path, because they are the only way the
 * native uploader — which has no UI and outlives the Flutter engine — learns it should stop:
 *
 * - 401 `unauthorized`  → the session was revoked or signed out elsewhere.
 * - 403 `not_entitled`  → the subscription lapsed.
 *
 * Both make the uploader clear its token and stop tracking. Without them a signed-out or
 * unpaid phone would keep broadcasting its position indefinitely.
 */
Deno.serve(async (req) => {
  const cors = preflight(req);
  if (cors) return cors;

  const db = serviceClient();
  const userId = await userIdForBearer(db, req.headers.get("Authorization"));
  if (!userId) return fail("unauthorized", "Session expired.", 401);

  let body: Record<string, unknown>;
  try {
    body = await req.json();
  } catch {
    return fail("invalid_request", "Malformed request.", 400);
  }

  const latitude = finite(body.latitude);
  const longitude = finite(body.longitude);
  if (
    latitude === null || longitude === null ||
    latitude < -90 || latitude > 90 ||
    longitude < -180 || longitude > 180
  ) {
    return fail("invalid_request", "Missing or out-of-range coordinates.", 400);
  }

  const { data: user, error: userError } = await db
    .from("users")
    .select(USER_COLUMNS)
    .eq("user_id", userId)
    .single();

  if (userError || !user) {
    console.error("ingest-location user lookup failed", userError);
    return fail("server_error", "Something went wrong.", 500);
  }

  const config = await loadConfig(db);
  if (!isEntitled(asUserRow(user), graceHoursFrom(config))) {
    return fail("not_entitled", "Your subscription has ended.", 403);
  }

  // Anything else is dropped rather than stored: the column has a CHECK on these two values,
  // and a rejected insert would fail an upload over a field nothing depends on.
  const platform = typeof body.platform === "string" &&
      (body.platform === "android" || body.platform === "ios")
    ? body.platform
    : null;

  const { error } = await db.from("user_locations").upsert(
    {
      user_id: userId,
      latitude,
      longitude,
      accuracy: finite(body.accuracy),
      speed: finite(body.speed),
      altitude: finite(body.altitude),
      platform,
      fixed_at: parseTimestamp(body.timestamp),
      // Set explicitly rather than left to the column default: on an UPDATE the default does
      // not re-fire, and this column is what every freshness decision in the app reads.
      updated_at: new Date().toISOString(),
    },
    { onConflict: "user_id" },
  );

  if (error) {
    console.error("user_locations upsert failed", error);
    return fail("server_error", "Could not record that location.", 500);
  }

  return json({ ok: true });
});

function finite(value: unknown): number | null {
  const parsed = typeof value === "number" ? value : Number(value);
  return Number.isFinite(parsed) ? parsed : null;
}

/**
 * The device's own clock, kept only for diagnostics.
 *
 * A device with a wrong clock — or a tampered one — must not be able to write a `fixed_at` that
 * the app would then treat as fresher than reality, so anything unparseable silently becomes
 * the server's own time rather than failing the upload.
 */
function parseTimestamp(value: unknown): string {
  if (typeof value === "string") {
    const at = new Date(value);
    if (Number.isFinite(at.getTime())) return at.toISOString();
  }
  return new Date().toISOString();
}
