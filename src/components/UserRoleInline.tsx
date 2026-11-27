import { useMemo } from "react";
import { useRoleDefinitions } from "@/hooks/profile/useRoleDefinitions";
import LazyBadgeTrigger from "@/components/badges/LazyBadgeTrigger";
import { solidPillClass, BADGE_ICON_SIZE, BADGE_ROW_SHRINK } from "@/lib/badgePalette";

interface Props {
  roles: string[];
  size?: "compact" | "full";
  /** Whose roles these are — "{name}" in the role's popup. */
  userId?: string | null;
}

const UserRoleInline = ({ roles, size = "compact", userId }: Props) => {
  const defs = useRoleDefinitions();

  const visibleRoles = useMemo(() => {
    if (!roles || roles.length === 0) return [];
    return roles.filter((r) => defs.get(r)?.show_inline);
  }, [roles, defs]);

  if (visibleRoles.length === 0) return null;

  // Same shared pill as badges — "Featured Creator" is a ROLE pill, and it was
  // failing contrast for exactly the same reason. See src/lib/badgePalette.ts.

  return (
    <span className={`inline-flex items-center gap-1 align-middle ${BADGE_ROW_SHRINK}`}>
      {visibleRoles.map((r) => {
        const cfg = defs.get(r);
        if (!cfg) return null;
        return (
          <LazyBadgeTrigger key={r} badge={r} role userId={userId} label={cfg.label} className={solidPillClass(cfg.pill_class, size)}>
            {cfg.icon && <span className={BADGE_ICON_SIZE}>{cfg.icon}</span>}
            {/* A role without an icon keeps its name: with neither there would be nothing to tap. */}
            {(cfg.show_label !== false || !cfg.icon) && <span className="truncate">{cfg.label}</span>}
          </LazyBadgeTrigger>
        );
      })}
    </span>
  );
};

export default UserRoleInline;
