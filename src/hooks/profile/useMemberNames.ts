import { useEffect, useState } from "react";
import { fetchProfileMap } from "@/lib/profileMapCache";
import type { MemberIdentity } from "@/lib/memberText";

/**
 * THE one place a tagged member's name and link are read (src/lib/memberText.ts,
 * root rule): the member's profile, through the shared batched profile cache —
 * every tag on a screen in one request, cached across screens.
 *
 * Until the profiles arrive the map is empty, so a tag briefly shows the name
 * copied in the text; a member with no profile keeps that copy, without a link.
 */
export function useMemberNames(ids: readonly string[]): ReadonlyMap<string, MemberIdentity> {
  const [names, setNames] = useState<ReadonlyMap<string, MemberIdentity>>(new Map());
  const key = [...new Set(ids)].sort().join(",");
  useEffect(() => {
    if (!key) { setNames(new Map()); return; }
    let cancelled = false;
    void fetchProfileMap(key.split(",")).then((map) => {
      if (cancelled) return;
      const next = new Map<string, MemberIdentity>();
      map.forEach((p, id) => next.set(id, { name: p.full_name?.trim() || null, handle: p.full_name ? p.custom_url ?? null : null }));
      setNames(next);
    }).catch(() => { /* names stay as typed; never break the text */ });
    return () => { cancelled = true; };
  }, [key]);
  return names;
}
