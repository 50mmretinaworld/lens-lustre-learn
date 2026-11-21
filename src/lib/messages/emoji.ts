/** Messages · emoji helpers: which messages are "just emoji" (shown big and animated), and the picker's sets. */

const ONE = String.raw`\p{Extended_Pictographic}(?:️|‍\p{Extended_Pictographic}|\p{Emoji_Modifier})*`;
const EMOJI_ONLY = new RegExp(`^(?:${ONE}\\s*){1,3}$`, "u");

/** 1 to 3 emoji and nothing else. */
export function isEmojiOnly(text: string): boolean {
  const s = text.trim();
  return s.length > 0 && s.length <= 40 && EMOJI_ONLY.test(s);
}

export const EMOJI_SETS: Array<{ id: string; label: string; icon: string; items: string[] }> = [
  { id: "smile", label: "Smileys", icon: "😊", items: ["😀", "😃", "😄", "😁", "😆", "😅", "😂", "🤣", "😊", "😇", "🙂", "😉", "😍", "🥰", "😘", "😎", "🤩", "🥳", "😌", "😴", "🤔", "😮", "😢", "😭", "😡", "🥺", "🙃", "😋"] },
  { id: "hands", label: "Hearts and hands", icon: "❤️", items: ["❤️", "🧡", "💛", "💚", "💙", "💜", "🖤", "💖", "💯", "🔥", "✨", "🎉", "👍", "👏", "🙌", "🙏", "👌", "✌️", "🤝", "💪", "👋", "🤞", "🫶", "👀"] },
  { id: "photo", label: "Photo and nature", icon: "📷", items: ["📷", "📸", "🎞️", "🔭", "🌅", "🌄", "🌇", "🌆", "🌃", "🌈", "🌙", "⭐", "☀️", "🌊", "🏔️", "🌿", "🌸", "🌻", "🍂", "🦋", "🐦", "🐯", "🏙️", "🚶"] },
];
