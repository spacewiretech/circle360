import { loadConfig } from "../_shared/config.ts";
import { fail, json, preflight } from "../_shared/cors.ts";
import { isValidMobile, serviceClient, userIdForBearer } from "../_shared/db.ts";
import {
  inviteText,
  inviteUrlBaseFrom,
  loadFeed,
  maxPeopleFrom,
  usedSlots,
} from "../_shared/sharing.ts";

/**
 * Connect to a mobile number, or invite it.
 *
 * The consent rule lives here and nowhere else: adding someone starts YOUR location flowing to
 * them right away — you agreed to that by adding them — and leaves THEIR location pending
 * until they accept in their own app. Nobody's position is ever exposed by someone else's
 * action.
 */
Deno.serve(async (req) => {
  const cors = preflight(req);
  if (cors) return cors;

  const db = serviceClient();
  const userId = await userIdForBearer(db, req.headers.get("Authorization"));
  if (!userId) return fail("unauthorized", "Please sign in again.", 401);

  let mobile: unknown;
  let name: unknown;
  try {
    ({ mobile, name } = await req.json());
  } catch {
    return fail("invalid_request", "Malformed request.", 400);
  }

  if (!isValidMobile(mobile)) {
    return fail("invalid_request", "That mobile number is not valid.", 400);
  }
  const invitedName = typeof name === "string" && name.trim().length > 0
    ? name.trim().slice(0, 80)
    : null;

  const { data: me, error: meError } = await db
    .from("users")
    .select("user_id, name, mobile_no")
    .eq("user_id", userId)
    .single();

  if (meError || !me) {
    console.error("add-person caller lookup failed", meError);
    return fail("server_error", "Something went wrong. Please try again.", 500);
  }

  if (me.mobile_no === mobile) {
    return fail("invalid_request", "That's your own number.", 400);
  }

  const config = await loadConfig(db);
  const maxPeople = maxPeopleFrom(config);

  // Who is this number?
  const { data: target, error: targetError } = await db
    .from("users")
    .select("user_id, name, mobile_no")
    .eq("mobile_no", mobile)
    .maybeSingle();

  if (targetError) {
    console.error("add-person target lookup failed", targetError);
    return fail("server_error", "Something went wrong. Please try again.", 500);
  }

  // The cap is checked before either branch writes, but AFTER the existing-connection check
  // below would have short-circuited — re-adding someone you already have must not be
  // rejected for being over a limit they are already inside.
  const alreadyLinked = target
    ? await isLinked(db, userId, target.user_id as string)
    : await hasOpenInvite(db, userId, mobile);

  if (!alreadyLinked && (await usedSlots(db, userId)) >= maxPeople) {
    return fail(
      "limit_reached",
      `You can add up to ${maxPeople} people.`,
      400,
    );
  }

  if (!target) {
    // Nobody by that number yet. Record the intent and hand the app something to send.
    const { error } = await db
      .from("pending_invites")
      .upsert(
        {
          inviter_id: userId,
          mobile_no: mobile,
          invited_name: invitedName,
          // A re-invite of a number that already signed up and was claimed must not silently
          // reopen; upsert only ever touches the caller's own row for this number.
          claimed_at: null,
        },
        { onConflict: "inviter_id,mobile_no" },
      );

    if (error) {
      console.error("pending_invites upsert failed", error);
      return fail("server_error", "Could not send that invite. Please try again.", 500);
    }

    const feed = await loadFeed(db, userId);
    return json({
      status: "invite_required",
      ...inviteText(
        inviteUrlBaseFrom(config),
        userId,
        (me.name as string | null) ?? null,
      ),
      ...feed,
      max_people: maxPeople,
    });
  }

  const targetId = target.user_id as string;

  // Two rows, two different meanings. `ignoreDuplicates` so re-adding is a no-op rather than
  // resetting an accept the other side has already given.
  const { error: shareError } = await db
    .from("location_shares")
    .upsert(
      [
        // Mine flows now: adding them is the consent.
        {
          sharer_id: userId,
          viewer_id: targetId,
          status: "active",
          created_by: userId,
        },
        // Theirs waits for them to say yes.
        {
          sharer_id: targetId,
          viewer_id: userId,
          status: "pending",
          created_by: userId,
        },
      ],
      { onConflict: "sharer_id,viewer_id", ignoreDuplicates: true },
    );

  if (shareError) {
    console.error("location_shares upsert failed", shareError);
    return fail("server_error", "Could not add that person. Please try again.", 500);
  }

  // Any invite the caller had open for this number is now redundant.
  await db
    .from("pending_invites")
    .delete()
    .eq("inviter_id", userId)
    .eq("mobile_no", mobile)
    .is("claimed_at", null);

  const feed = await loadFeed(db, userId);
  return json({ status: "connected", ...feed, max_people: maxPeople });
});

async function isLinked(
  db: ReturnType<typeof serviceClient>,
  userId: string,
  otherId: string,
): Promise<boolean> {
  const { count } = await db
    .from("location_shares")
    .select("id", { count: "exact", head: true })
    .eq("viewer_id", userId)
    .eq("sharer_id", otherId);
  return (count ?? 0) > 0;
}

async function hasOpenInvite(
  db: ReturnType<typeof serviceClient>,
  userId: string,
  mobile: string,
): Promise<boolean> {
  const { count } = await db
    .from("pending_invites")
    .select("id", { count: "exact", head: true })
    .eq("inviter_id", userId)
    .eq("mobile_no", mobile)
    .is("claimed_at", null);
  return (count ?? 0) > 0;
}
