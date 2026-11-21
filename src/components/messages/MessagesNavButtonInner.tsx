import { Link } from "react-router-dom";
import { MessageCircle } from "lucide-react";
import { useUnreadCounts } from "@/hooks/messages/useUnreadCounts";

/** The message icon with its unread count (see MessagesNavButton: loaded only for members who may message). */
export default function MessagesNavButtonInner() {
  const { inbox, requests } = useUnreadCounts();
  const total = inbox + requests;
  return (
    <Link
      to="/messages"
      aria-label={total > 0 ? `Messages, ${total} unread` : "Messages"}
      className="relative grid h-11 w-11 place-items-center text-muted-foreground hover:text-primary transition-colors duration-300"
    >
      <MessageCircle className="h-6 w-6" />
      {total > 0 && (
        <span className="absolute -top-1 -right-1 h-4 min-w-[16px] px-1 flex items-center justify-center rounded-full bg-primary text-primary-foreground text-[9px] font-bold leading-none">
          {total > 99 ? "99+" : total}
        </span>
      )}
    </Link>
  );
}
