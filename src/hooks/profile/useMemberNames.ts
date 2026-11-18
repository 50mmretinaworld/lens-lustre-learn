import { useEffect, useState } from "react";
import { fetchProfileMap, type ProfileMap } from "@/lib/profileMapCache";

/**
 * THE one place a tagged member's name and link are read (src/lib/memberText.ts,
 * root rule): the member's profile, through the shared batched profile cache —
 * every tag on a screen in one request, cached across screens. Returns the
 * profile rows as they are (full_name, custom_url).
 *
 * Until the profiles arrive the map is empty, so a tag briefly shows the name
 * copied in the text; a member with no profile keeps that copy, without a link.
 */
export function useMemberNames(ids: readonly string[]): ProfileMap {
  const [names, setNames] = useState<ProfileMap>(new Map());
  const key = [...new Set(ids)].sort().join(",");
  useEffect(() => {
    let cancelled = false;
    if (!key) setNames(new Map());
    else void fetchProfileMap(key.split(",")).then((m) => { if (!cancelled) setNames(m); }).catch(() => { /* names stay as typed; never break the text */ });
    return () => { cancelled = true; };
  }, [key]);
  return names;
}
