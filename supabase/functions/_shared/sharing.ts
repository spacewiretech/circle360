/**
 * The shape Home renders, and the queries that build it.
 *
 * Shared by `people` and `add-person` so a freshly added person and the same person on the
 * next poll are byte-identical — otherwise the card would visibly change shape one tick after
 * being created.
 */

import { SupabaseClient } from "jsr:@supabase/supabase-js@2";
import { AppConfig, configSetting } from "./config.ts";

/**
 * What the viewer can do with this row.
 *
 * - `sharing` — they have agreed and their position is live.
 * - `pending` — added, waiting on them to accept. No position, ever.
 * - `invited`  — not on Loc360 yet. No account, so no position either.
 */
export type PersonStatus = "sharing" | "pending" | "invited";

export interface Person {
  /** Null only for `invited` — there is no account behind an invite yet. */
  user_id: string | null;
  name: string | null;
  mobile_no: string;
  status: PersonStatus;
  latitude: number | null;
  longitude: number | null;
  accuracy: number | null;
  /** Server clock. The client judges freshness on this and never on the device's own stamp. */
  updated_at: string | null;
  created_at: string;
}

export function maxPeopleFrom(config: AppConfig): number {
  const parsed = Number(configSetting(config, "max_tracked_people"));
  return Number.isInteger(parsed) && parsed > 0 ? parsed : 3;
}

export function inviteUrlBaseFrom(config: AppConfig): string {
  return configSetting(config, "invite_url_base") || "https://loc360.app/invite";
}

/**
 * The invite link, and the message wrapped around it.
 *
 * The code in the path is the inviter's own id and is used only for attribution — the
 * connection itself is made by `claim_pending_invites` matching on the mobile number, so it
 * still forms if the invitee ignores the link and installs from the store.
 */
export function inviteText(
  base: string,
  inviterId: string,
  inviterName: string | null,
): { invite_url: string; share_text: string } {
  const from = inviterName?.trim();
  const url = `${base}/${inviterId}` +
    (from ? `?from=${encodeURIComponent(from)}` : "");
  const who = from ? `${from} wants` : "Someone wants";
  return {
    invite_url: url,
    share_text:
      `${who} to stay connected with you on Loc360. Install the app and sign in with this ` +
      `number, and you'll be connected automatically: ${url}`,
  };
}

interface ShareRow {
  sharer_id: string;
  viewer_id: string;
  status: "pending" | "active";
  created_at: string;
}

/**
 * Everything the caller's Home screen shows, in one round trip per concept.
 *
 * `people` is deliberately three different things flattened into one list, because that is how
 * the screen presents them — a person you are connected to, a person who has not accepted yet,
 * and a number that has not installed yet all occupy the same row in the same list.
 */
export async function loadFeed(
  db: SupabaseClient,
  userId: string,
): Promise<{ people: Person[]; requests: Person[] }> {
  const [sharesResult, invitesResult] = await Promise.all([
    db
      .from("location_shares")
      .select("sharer_id, viewer_id, status, created_at")
      .or(`viewer_id.eq.${userId},sharer_id.eq.${userId}`),
    db
      .from("pending_invites")
      .select("mobile_no, invited_name, created_at")
      .eq("inviter_id", userId)
      .is("claimed_at", null),
  ]);

  if (sharesResult.error) throw sharesResult.error;
  if (invitesResult.error) throw invitesResult.error;

  const shares = (sharesResult.data ?? []) as ShareRow[];

  // Who I can see, and who I am waiting on. Both are "the other person" from my side, so they
  // collapse into one map keyed by that person's id.
  const visible = new Map<string, ShareRow>(); // they share with me
  const waiting = new Map<string, ShareRow>(); // I added them, they haven't accepted
  const requests = new Map<string, ShareRow>(); // they are waiting on me

  for (const row of shares) {
    if (row.viewer_id === userId && row.status === "active") {
      visible.set(row.sharer_id, row);
    } else if (row.viewer_id === userId && row.status === "pending") {
      waiting.set(row.sharer_id, row);
    } else if (row.sharer_id === userId && row.status === "pending") {
      requests.set(row.viewer_id, row);
    }
  }

  const otherIds = [
    ...new Set([...visible.keys(), ...waiting.keys(), ...requests.keys()]),
  ];

  const profiles = new Map<string, { name: string | null; mobile_no: string }>();
  const positions = new Map<
    string,
    { latitude: number; longitude: number; accuracy: number | null; updated_at: string }
  >();

  if (otherIds.length > 0) {
    const usersResult = await db
      .from("users")
      .select("user_id, name, mobile_no")
      .in("user_id", otherIds);
    if (usersResult.error) throw usersResult.error;

    for (const row of (usersResult.data ?? []) as Record<string, unknown>[]) {
      profiles.set(row.user_id as string, {
        name: row.name as string | null,
        mobile_no: row.mobile_no as string,
      });
    }

    // Only people who actually share with me. Selecting positions for the pending set as well
    // would pull a location its owner has not agreed to expose — even if the UI never drew it,
    // it would be in the response — so the filter belongs here, not in the client.
    if (visible.size > 0) {
      const locationsResult = await db
        .from("user_locations")
        .select("user_id, latitude, longitude, accuracy, updated_at")
        .in("user_id", [...visible.keys()]);
      if (locationsResult.error) throw locationsResult.error;

      for (const row of (locationsResult.data ?? []) as Record<string, unknown>[]) {
        positions.set(row.user_id as string, {
          latitude: row.latitude as number,
          longitude: row.longitude as number,
          accuracy: row.accuracy as number | null,
          updated_at: row.updated_at as string,
        });
      }
    }
  }

  function personFor(id: string, row: ShareRow, status: PersonStatus): Person {
    const profile = profiles.get(id);
    const position = status === "sharing" ? positions.get(id) : undefined;
    return {
      user_id: id,
      name: profile?.name ?? null,
      mobile_no: profile?.mobile_no ?? "",
      status,
      latitude: position?.latitude ?? null,
      longitude: position?.longitude ?? null,
      accuracy: position?.accuracy ?? null,
      updated_at: position?.updated_at ?? null,
      created_at: row.created_at,
    };
  }

  const people: Person[] = [
    ...[...visible].map(([id, row]) => personFor(id, row, "sharing")),
    ...[...waiting].map(([id, row]) => personFor(id, row, "pending")),
    ...(invitesResult.data ?? []).map((row): Person => ({
      user_id: null,
      name: (row.invited_name as string | null) ?? null,
      mobile_no: row.mobile_no as string,
      status: "invited",
      latitude: null,
      longitude: null,
      accuracy: null,
      updated_at: null,
      created_at: row.created_at as string,
    })),
  ];

  // Oldest first, so the list does not reshuffle under the user's thumb between polls.
  people.sort((a, b) => a.created_at.localeCompare(b.created_at));

  return {
    people,
    requests: [...requests].map(([id, row]) => personFor(id, row, "pending"))
      .sort((a, b) => a.created_at.localeCompare(b.created_at)),
  };
}

/**
 * How many of the caller's slots are already spoken for.
 *
 * Counts invites too: a slot held by someone who has not installed yet is still a slot, or
 * three unanswered invites would leave room for three more connections on top.
 */
export async function usedSlots(db: SupabaseClient, userId: string): Promise<number> {
  const [shares, invites] = await Promise.all([
    db
      .from("location_shares")
      .select("sharer_id", { count: "exact", head: true })
      .eq("viewer_id", userId),
    db
      .from("pending_invites")
      .select("id", { count: "exact", head: true })
      .eq("inviter_id", userId)
      .is("claimed_at", null),
  ]);

  return (shares.count ?? 0) + (invites.count ?? 0);
}
