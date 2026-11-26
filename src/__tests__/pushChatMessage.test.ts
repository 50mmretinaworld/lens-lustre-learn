/**
 * A private-message push with the sender's photo (Owner 26 Nov 2026): data only for Android builds that
 * registered the "chat" cap, the ordinary notification for every other phone.
 */
import { describe, it, expect } from "vitest";
import { buildChatMessage } from "../../supabase/functions/_shared/pushMessage";

const CHAT = "11111111-2222-3333-4444-555555555555";
const HOSTS = ["cdn.example-lane.test"];
const base = {
  token: "tok",
  title: "Li Wei",
  body: "Which lens was that?",
  data: { type: "new_message", reference_id: CHAT, sender_photo: "https://cdn.example-lane.test/a.webp" },
  imageHosts: HOSTS,
  origin: "https://www.example-lane.test",
  platform: "android",
  caps: ["rich", "chat"],
};

describe("buildChatMessage", () => {
  it("is data only, with the photo and the chat to open", () => {
    expect(buildChatMessage(base)).toEqual({
      token: "tok",
      data: {
        type: "chat_rich",
        title: "Li Wei",
        body: "Which lens was that?",
        link: `/messages/${CHAT}`,
        origin: "https://www.example-lane.test",
        chat_id: CHAT,
        image: "https://cdn.example-lane.test/a.webp",
      },
      android: { priority: "high" },
    });
  });

  it("leaves iPhones, older builds and other pushes to the ordinary message", () => {
    expect(buildChatMessage({ ...base, platform: "ios" })).toBeNull();
    expect(buildChatMessage({ ...base, caps: ["rich"] })).toBeNull();
    expect(buildChatMessage({ ...base, caps: null })).toBeNull();
    expect(buildChatMessage({ ...base, data: { type: "post_comment", reference_id: CHAT } })).toBeNull();
    expect(buildChatMessage({ ...base, origin: null })).toBeNull();
    expect(buildChatMessage({ ...base, data: { type: "new_message", reference_id: "x/../y" } })).toBeNull();
  });

  it("drops a picture from another host and keeps the message", () => {
    const m = buildChatMessage({ ...base, data: { ...base.data, sender_photo: "https://evil.test/a.png" } });
    expect(m?.data.image).toBeUndefined();
    expect(m?.data.body).toBe("Which lens was that?");
  });
});
