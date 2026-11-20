/**
 * Messages · suggested replies. Looks at the last thing the OTHER person sent and offers up to three short
 * answers a photographer would actually give. Pure and on the phone: nothing is sent anywhere to make them,
 * and a tap sends the chosen text like any other message.
 */
import type { ThreadMessage } from "./api";

const has = (s: string, re: RegExp) => re.test(s);

export function suggestReplies(last: ThreadMessage | null): string[] {
  if (!last || last.status !== "sent") return [];
  const s = last.body.trim().toLowerCase();
  if (last.kind === "photo" && !s) return ["Love this 😍", "Great shot! 📸", "Beautiful light ✨"];
  if (!s) return [];
  if (has(s, /\b(thanks|thank you|thx|ty)\b/)) return ["You're welcome 😊", "Anytime!", "Glad you liked it ❤️"];
  if (has(s, /^(hi|hello|hey|hii+|namaste|good (morning|evening|afternoon))\b/)) return ["Hi! 👋", "Hey, how are you?", "Hello 😊"];
  if (s.includes("?")) {
    if (has(s, /\b(lens|camera|setting|settings|aperture|iso|shutter|edit|editing|preset|how did|which)\b/)) return ["Shot on 50mm f/1.4 📷", "Happy to share the details!", "Let me check and tell you"];
    if (has(s, /\b(free|weekend|meet|walk|tomorrow|today|when|available|join)\b/)) return ["Yes, I'm free! 🙌", "Let's plan it", "Sorry, can't make it"];
    return ["Yes 👍", "Not sure yet", "Let me check"];
  }
  if (has(s, /\b(love|beautiful|great|amazing|awesome|stunning|nice|gorgeous|wow)\b/)) return ["Thank you so much! 🙏", "That means a lot ❤️", "Glad you like it 😊"];
  return ["👍", "Sounds good", "Thanks! 😊"];
}
