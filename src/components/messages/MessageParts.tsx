/**
 * Messages · small shared pieces: avatar, refusal wording, helpline card, a bubble with its photos.
 * Plain text only — a body is rendered as text, never as HTML, and a link in it is not made clickable.
 */
import { useQuery } from "@tanstack/react-query";
import { HeartHandshake } from "lucide-react";
import { signedPhotoUrl, type SendRefusal, type ThreadMessage, type MessagePerson } from "@/lib/messages/api";

export const headingFont = { fontFamily: "var(--font-heading)" };

export function PersonAvatar({ person, size = 44 }: { person: MessagePerson | null; size?: number }) {
  const name = person?.fullName?.trim() || "Member";
  const initial = name.charAt(0).toUpperCase();
  return person?.avatarUrl ? (
    <img src={person.avatarUrl} alt="" width={size} height={size} loading="lazy" className="shrink-0 rounded-full object-cover bg-muted" style={{ width: size, height: size }} />
  ) : (
    <span aria-hidden className="grid shrink-0 place-items-center rounded-full bg-muted text-sm font-semibold text-muted-foreground" style={{ width: size, height: size }}>
      {initial}
    </span>
  );
}

/** What the member reads when the server refuses a send. Calm, one line, no codes. */
export function refusalText(r: SendRefusal): string {
  switch (r) {
    case "under_review": return "Your account is under review · Contact support@50mmretina.com";
    case "no_link": return "You can message people you follow and your friends.";
    case "blocked": return "You can't message this member.";
    case "word_guard": return "This message can't be sent.";
    case "too_fast": return "You're sending too fast. Try again in a minute.";
    case "daily_limit": return "You've reached today's message limit.";
    case "chat_limit": return "You've started too many new chats today.";
    case "photo_limit": return "You've reached today's photo limit.";
    case "paused": return "Messaging is paused for your account.";
    case "not_available": return "Messaging isn't available for your account.";
    case "text_off": return "Text messages aren't available for your account.";
    case "photos_off": return "Photos aren't available for your account.";
    case "friends_only": return "Your account can message friends only.";
    case "recipient_unavailable": return "This member can't receive messages right now.";
    case "bad_photo": return "That photo couldn't be sent. Try another one.";
    case "bad_message": return "Write 1 to 4000 characters.";
    case "sign_in": return "Please sign in to send a message.";
    default: return "Message not sent. Please try again.";
  }
}

/** Shown after the word guard finds a self-harm phrase. The message itself was delivered. */
export function HelplineCard({ onClose }: { onClose: () => void }) {
  return (
    <div role="status" data-testid="helpline-card" className="mx-3 my-2 rounded-2xl border border-primary/30 bg-primary/5 p-3 text-sm">
      <div className="mb-1 flex items-center gap-2 font-semibold" style={headingFont}>
        <HeartHandshake className="h-4 w-4 text-primary" /> You are not alone
      </div>
      <p className="text-muted-foreground">If you are going through a hard time, please talk to someone now.
        India: Tele-MANAS 14416 (free, 24 hours). United States: call or text 988.</p>
      <button type="button" onClick={onClose} className="mt-2 text-xs font-medium text-primary underline-offset-2 hover:underline">Close</button>
    </div>
  );
}

function PhotoTile({ path, width, height }: { path: string; width: number | null; height: number | null }) {
  // A 5-minute link, asked for only when the tile is on screen; the server's read rule decides.
  const { data: url } = useQuery({ queryKey: ["messages", "photo", path], queryFn: () => signedPhotoUrl(path), staleTime: 4 * 60_000 });
  const ratio = width && height ? `${width} / ${height}` : "4 / 3";
  return url ? (
    <img src={url} alt="Photo in this chat" loading="lazy" className="w-full rounded-xl object-cover" style={{ aspectRatio: ratio }} />
  ) : (
    <div aria-hidden className="w-full animate-pulse rounded-xl bg-muted" style={{ aspectRatio: ratio }} />
  );
}

export function MessageBubble({ m, mine }: { m: ThreadMessage; mine: boolean }) {
  // a photo with no caption is the picture alone (no coloured frame around it)
  const photoOnly = m.photos.length > 0 && !m.body && m.status !== "held";
  return (
    <div className={`flex ${mine ? "justify-end" : "justify-start"} px-3`}>
      <div
        data-testid={mine ? "bubble-mine" : "bubble-theirs"}
        className={`max-w-[78%] whitespace-pre-wrap break-words text-[15px] leading-snug ${
          photoOnly
            ? "w-[78%]"
            : `rounded-2xl px-3.5 py-2 ${mine ? "bg-primary text-primary-foreground rounded-br-md" : "bg-muted text-foreground rounded-bl-md"}`
        }`}
      >
        {m.photos.length > 0 && (
          <div className={`mb-1 grid gap-1 ${m.photos.length > 1 ? "grid-cols-2" : "grid-cols-1"}`}>
            {m.photos.map((p) => <PhotoTile key={p.path} path={p.path} width={p.width} height={p.height} />)}
          </div>
        )}
        {m.body && <span>{m.body}</span>}
        {m.status === "held" && <span className="mt-1 block text-[11px] opacity-70">Waiting for review</span>}
      </div>
    </div>
  );
}
