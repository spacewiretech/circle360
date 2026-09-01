import { loadConfig } from "../_shared/config.ts";
import { fail, json, preflight } from "../_shared/cors.ts";
import { serviceClient, userIdForBearer } from "../_shared/db.ts";
import { loadFeed, maxPeopleFrom } from "../_shared/sharing.ts";

/**
 * Answer a sharing request, or end a connection.
 *
 * `accept` only ever flips the caller's OWN outbound row — there is no request shape that lets
 * one account turn on another account's sharing.
 *
 * `decline` and `remove` are the same operation and delete BOTH directions. Declining only the
 * inbound half would leave the other person's location still arriving on your map after you
 * refused to connect to them, which is not what "no" means.
 */
Deno.serve(async (req) => {
  const cors = preflight(req);
  if (cors) return cors;

  const db = serviceClient();
  const userId = await userIdForBearer(db, req.headers.get("Authorization"));
  if (!userId) return fail("unauthorized", "Please sign in again.", 401);

  let targetId: unknown;
  let action: unknown;
  let mobile: unknown;
  try {
    ({ user_id: targetId, action, mobile } = await req.json());
  } catch {
    return fail("invalid_request", "Malformed request.", 400);
  }

  if (action !== "accept" && action !== "decline" && action !== "remove") {
    return fail("invalid_request", "Unknown action.", 400);
  }

  // Withdrawing an invite to a number that never signed up: there is no user id to name, so
  // the number itself identifies the row.
  if (action === "remove" && typeof mobile === "string" && !targetId) {
    const { error } = await db
      .from("pending_invites")
      .delete()
      .eq("inviter_id", userId)
      .eq("mobile_no", mobile)
      .is("claimed_at", null);

    if (error) {
      console.error("invite withdraw failed", error);
      return fail("server_error", "Could not remove that invite. Please try again.", 500);
    }
    return respondWithFeed(db, userId);
  }

  if (typeof targetId !== "string" || targetId.length === 0 || targetId === userId) {
    return fail("invalid_request", "Unknown person.", 400);
  }

  if (action === "accept") {
    // Scoped to the caller as the sharer, so this can only ever start the caller's own sharing.
    const { data, error } = await db
      .from("location_shares")
      .update({ status: "active" })
      .eq("sharer_id", userId)
      .eq("viewer_id", targetId)
      .eq("status", "pending")
      .select("id");

    if (error) {
      console.error("accept failed", error);
      return fail("server_error", "Could not accept that request. Please try again.", 500);
    }
    // No row means the request was withdrawn while the screen was open. Not an error worth an
    // alert — the refreshed feed below simply won't show it any more.
    if ((data ?? []).length === 0) {
      console.log("accept matched no pending row", { userId, targetId });
    }
    return respondWithFeed(db, userId);
  }

  // decline / remove — both directions, plus any invite left over between the pair.
  const { error: deleteError } = await db
    .from("location_shares")
    .delete()
    .or(
      `and(sharer_id.eq.${userId},viewer_id.eq.${targetId}),` +
        `and(sharer_id.eq.${targetId},viewer_id.eq.${userId})`,
    );

  if (deleteError) {
    console.error("disconnect failed", deleteError);
    return fail("server_error", "Could not update that person. Please try again.", 500);
  }

  const { data: other } = await db
    .from("users")
    .select("mobile_no")
    .eq("user_id", targetId)
    .maybeSingle();

  if (other?.mobile_no) {
    await db
      .from("pending_invites")
      .delete()
      .eq("inviter_id", userId)
      .eq("mobile_no", other.mobile_no as string);
  }

  return respondWithFeed(db, userId);
});

/** Every action answers with the caller's whole feed, so the screen needs no follow-up poll. */
async function respondWithFeed(
  db: ReturnType<typeof serviceClient>,
  userId: string,
): Promise<Response> {
  try {
    const [feed, config] = await Promise.all([loadFeed(db, userId), loadConfig(db)]);
    return json({ ...feed, max_people: maxPeopleFrom(config) });
  } catch (error) {
    console.error("respond-request feed reload failed", error);
    return fail("server_error", "Something went wrong. Please try again.", 500);
  }
}
