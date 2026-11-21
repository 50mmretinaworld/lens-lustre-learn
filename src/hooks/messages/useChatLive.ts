/**
 * Messages · live feel of ONE open chat (Owner 21 Nov: "when typing show a typing animation").
 *
 * A private Supabase Realtime BROADCAST channel `chat:<conversation id>` — nothing is stored, nothing
 * is read from a table. The server lets only the two people of that chat join it (policy on
 * realtime.messages, migration 20261118_2500). Opened only while the chat is on screen, closed when
 * it is left. Two tiny events:
 *   typing — "I am typing" (sent at most once per 3 s while the box has text); the other side shows
 *            the animated dots and hides them after 5 s of silence;
 *   ping   — "something changed" (I sent a message / opened the chat): the other side refreshes this
 *            chat at once instead of waiting for its 30 s poll.
 * If the channel cannot open (offline, refused) nothing breaks: the polls still keep the chat fresh.
 * An admin's read-only view never joins (it is not a member and must stay silent).
 */
import { useCallback, useEffect, useRef, useState } from "react";
import { useQueryClient } from "@tanstack/react-query";
import type { RealtimeChannel } from "@supabase/supabase-js";
import { supabase } from "@/integrations/supabase/client";

const TYPING_SHOW_MS = 5000;
const TYPING_SEND_EVERY_MS = 3000;

export interface ChatLive {
  /** The other person is typing right now. */
  typing: boolean;
  /** Call on every change of the text box (it throttles itself; an empty box sends nothing). */
  notifyTyping: (hasText: boolean) => void;
  /** Tell the other side to refresh (after a send or after opening the chat). */
  ping: () => void;
}

export function useChatLive(conversationId: string | null, meId: string | undefined, enabled: boolean): ChatLive {
  const qc = useQueryClient();
  // the screenshot harness can switch the dots on (it has no realtime server); a real session starts with them off
  const [typing, setTyping] = useState<boolean>(() => (globalThis as { __harnessTyping?: boolean }).__harnessTyping === true);
  const channelRef = useRef<RealtimeChannel | null>(null);
  const readyRef = useRef(false);
  const lastSent = useRef(0);
  const hideTimer = useRef<ReturnType<typeof setTimeout> | null>(null);

  useEffect(() => {
    if (!enabled || !conversationId || !meId) return undefined;
    let cancelled = false;
    const channel = supabase.channel(`chat:${conversationId}`, { config: { private: true, broadcast: { self: false } } });
    channelRef.current = channel;
    channel
      .on("broadcast", { event: "typing" }, (msg: { payload?: { from?: string } }) => {
        if (msg.payload?.from === meId) return;
        setTyping(true);
        if (hideTimer.current) clearTimeout(hideTimer.current);
        hideTimer.current = setTimeout(() => setTyping(false), TYPING_SHOW_MS);
      })
      .on("broadcast", { event: "ping" }, (msg: { payload?: { from?: string } }) => {
        if (msg.payload?.from === meId) return;
        // they sent something or opened the chat: stop the dots and refresh
        setTyping(false);
        if (hideTimer.current) clearTimeout(hideTimer.current);
        void qc.invalidateQueries({ queryKey: ["messages"] });
      })
      .subscribe((status) => {
        if (cancelled) return;
        readyRef.current = status === "SUBSCRIBED";
      });
    return () => {
      cancelled = true;
      readyRef.current = false;
      channelRef.current = null;
      if (hideTimer.current) clearTimeout(hideTimer.current);
      setTyping(false);
      void supabase.removeChannel(channel);
    };
  }, [conversationId, meId, enabled, qc]);

  const send = useCallback((event: "typing" | "ping") => {
    const ch = channelRef.current;
    if (!ch || !readyRef.current || !meId) return;
    void ch.send({ type: "broadcast", event, payload: { from: meId } }).catch(() => undefined);
  }, [meId]);

  const notifyTyping = useCallback((hasText: boolean) => {
    if (!hasText) return;
    const now = Date.now();
    if (now - lastSent.current < TYPING_SEND_EVERY_MS) return;
    lastSent.current = now;
    send("typing");
  }, [send]);

  const ping = useCallback(() => { lastSent.current = 0; send("ping"); }, [send]);

  return { typing, notifyTyping, ping };
}
