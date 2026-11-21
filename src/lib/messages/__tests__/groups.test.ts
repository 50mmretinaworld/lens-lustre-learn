import { describe, expect, it } from "vitest";
import { parseGroupFriends, parseGroupMembers } from "../groups";
import { refusalFrom } from "../api";

describe("group chat data layer", () => {
  it("reads members with the owner role and drops malformed rows", () => {
    const m = parseGroupMembers([
      { user_id: "u1", role: "owner", full_name: "Asha", username: "asha", avatar_url: null },
      { user_id: "u2", role: "member", full_name: null },
      { nope: 1 },
      "x",
    ]);
    expect(m.map((x) => [x.userId, x.role])).toEqual([["u1", "owner"], ["u2", "member"]]);
    expect(parseGroupMembers("x")).toEqual([]);
  });

  it("reads the friend picker", () => {
    expect(parseGroupFriends([{ user_id: "u3", full_name: "Ravi" }, {}])).toEqual([{ userId: "u3", fullName: "Ravi", username: null, avatarUrl: null }]);
    expect(parseGroupFriends(null)).toEqual([]);
  });

  it("maps the group refusal codes", () => {
    expect(refusalFrom("MSG-080: group chats are not available yet")).toBe("groups_off");
    expect(refusalFrom("MSG-084: a group can only take your own friends")).toBe("bad_group");
    expect(refusalFrom("MSG-083: a group needs 2 to 19 other members")).toBe("bad_group");
  });
});
