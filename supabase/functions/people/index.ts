import { loadConfig } from "../_shared/config.ts";
import { fail, json, preflight } from "../_shared/cors.ts";
import { serviceClient, userIdForBearer } from "../_shared/db.ts";
import { loadFeed, maxPeopleFrom } from "../_shared/sharing.ts";

/**
 * The one read the Home screen makes, polled every 10 seconds while it is on screen.
 *
 * Everything the screen needs comes back in a single call — connected people with their
 * positions, people who have not accepted yet, unclaimed invites, and requests waiting on the
 * caller. Splitting these across endpoints would mean the list and the request banner could
 * disagree with each other for a tick.
 *
 * Entitlement is deliberately NOT checked here: EntitlementGate already routes a lapsed user
 * to the paywall, and failing this call as well would replace that with an error toast.
 */
Deno.serve(async (req) => {
  const cors = preflight(req);
  if (cors) return cors;

  const db = serviceClient();
  const userId = await userIdForBearer(db, req.headers.get("Authorization"));
  if (!userId) return fail("unauthorized", "Please sign in again.", 401);

  try {
    const [feed, config] = await Promise.all([loadFeed(db, userId), loadConfig(db)]);
    return json({ ...feed, max_people: maxPeopleFrom(config) });
  } catch (error) {
    console.error("people failed", error);
    return fail("server_error", "Could not load your people. Please try again.", 500);
  }
});
