import { Suspense, lazy } from "react";
import { useMessagingAllowed } from "@/hooks/messages/useMessagingAllowed";

// The button itself (icon, link, unread count) loads only for a member the server lets message —
// everyone else downloads none of it (P13 entry-bundle ceiling).
const MessagesNavButtonInner = lazy(() => import("./MessagesNavButtonInner"));

/**
 * The desktop top-bar entry to private messages, next to the bell. It renders only for a
 * member the server lets message (message_allowed_me) — at launch that is the Owner alone.
 * Phones reach /messages from the ☰ sheet instead.
 */
export default function MessagesNavButton() {
  const allowed = useMessagingAllowed();
  if (!allowed) return null;
  return (
    <Suspense fallback={null}>
      <MessagesNavButtonInner />
    </Suspense>
  );
}
