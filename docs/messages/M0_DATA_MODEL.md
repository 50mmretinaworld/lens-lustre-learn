# Messages M0 — data model and send door (design only, no SQL applied)

Date 2026-11-18. Owner decisions: handover `HANDOVER-2026-11-18-messages-start.md` §2 and the plan doc
"Job Engine and Messages Work Plan". Nothing here is applied anywhere. Staging first, one unit per PR.

## 1. What exists today (inspected on `origin/staging` 18c63557)
| Need | Existing piece to REUSE | File |
|---|---|---|
| Follows / friends | `follows(follower_id, following_id)`, `friendships(requester_id, addressee_id, status)`; `are_friends(a,b)` | 20260227113944…, 20260910_0017 |
| Block | `user_blocks(blocker_id, blocked_id)` (member-owned, passive for the guard) | 20261003_0001 |
| Official account | any `user_roles.role = 'admin'` is "follow-only" (trigger `block_friend_requests_to_admins`) | 20260731180000 |
| Can this account act | `account_can_act(uid)` + trigger `zz_account_state_guard` (attached ONCE at A1 time — new tables need it attached by hand) | 20261115_1310, 20261116_1500 |
| Admin switch | `feature_access` / `feature_access_members` / `feature_access_audit` + `feature_allowed(f,uid)`. **Three modes only** (off / selected / everyone) and a CHECK that lists 3 feature names | 20261005_0004 |
| Background work | `job_enqueue(kind, payload, idem_key)`, `job_kinds`, `push.send` (key `notification:<id>`), `cron_run('<job>')` | 20261115_1100, 1200 |

Gap found: the Owner wants **four** modes (Allowed all / Allowed selected / Blocked all / Blocked selected).
`feature_access` cannot express "Blocked selected" (everyone except a list) and its CHECK is closed. Decision: messages
get **their own control table with the same shape and the same audit rule**, not an edit of the live video switch.

## 2. Tables (all `public`, RLS on, API roles have NO write grant; every write goes through a function)
**Control**
- `message_control` (single row): `mode` ∈ allowed_all | allowed_selected | blocked_all | blocked_selected, `groups_enabled bool default false`, `note`, `updated_by/at`. Seeded `allowed_selected`.
- `message_control_members(user_id, listed_by, listed_at, note)` — the list for the two "selected" modes. Seeded with the Owner only.
- `message_member_rules(user_id PK, text_ok, photos_ok, groups_ok, friends_only, daily_limit int null, blocked_until timestamptz null, reason, set_by, set_at)` — per-member controls and timed block.
- `message_control_log` — append-only (UPDATE/DELETE/TRUNCATE refused): who, when, what, old → new, **reason required**.

**Chats**
- `conversations(id, kind direct|group, direct_key text unique null, title null, created_by, created_at, last_message_at)`. `direct_key = least(a,b)||':'||greatest(a,b)` so a pair can never get two chats.
- `conversation_members(conversation_id, user_id, role, folder inbox|requests, joined_at, last_read_at, muted)`; PK (conversation_id, user_id). Folder `requests` = sender follows the receiver but is not followed back.
- `messages(id bigint identity, conversation_id, sender_id, kind text|photo, body ≤ 4000, client_msg_id uuid, status sent|held, created_at)`; **unique (sender_id, client_msg_id)** = same message never twice. Trigger refuses UPDATE/DELETE from every API role (no delete, no unsend). Only the retention function (service role) removes rows.
- `message_attachments(id, message_id, storage_path, mime, bytes, width, height)` — private bucket, 5-minute signed links made only after the server checks the viewer is a member.

**Safety**
- `message_word_rules(id, category abuse|threat|political|self_harm|abnormal, pattern, lang, action block|hold|help, active)` — admin-edited.
- `message_guard_events(id, user_id, rule_id, action, message_id null, created_at)` — what the guard did (block / hold / help+admin alert).
- `message_admin_reads` — append-only: admin, conversation, at, reason. Kept 1 year. Rogue-admin alarm: > N distinct chats opened by one admin per day → alarm row.

## 3. The one door: `message_send(...)` (SECURITY DEFINER, search_path = '')
Order of checks, first failure wins (each failure has its own error code and its own test):
1. signed in; `account_can_act(auth.uid())`
2. control mode + list → `message_control` rules (all four modes)
3. `message_member_rules`: `blocked_until`, `text_ok` / `photos_ok`, `friends_only`
4. `user_blocks` in **either** direction → refused
5. relationship: sender is admin ("official") → anyone; else receiver is friend → inbox; else sender follows receiver → `requests` folder; else refused
6. limits: per minute and per day (stricter for accounts < N days old, and `daily_limit`)
7. word guard: block → refuse; hold → store `status = held`, not delivered; help → store + show helpline + alert admin
8. insert (idempotent on `client_msg_id`), enqueue `message.push` (sender name only, no text) on the job engine

Receiver-side: `message_accept_request`, `message_decline_request` (folder move only; declined stays out of the inbox).
Reads: members read only chats they belong to (RLS on `conversation_members` / `messages`); admins read only through `admin_read_conversation(conv, reason)` which writes the log row first.

## 4. Hooks into what is already live
- Attach `zz_account_state_guard` to `conversations`, `conversation_members`, `messages`, `message_attachments` (the admin-only control / log tables are passive). Add them to the PROBE attach list so the A1 PROBE stays green.
- Job kinds to add: `message.push`, `message.retention` (180 days after account deletion), `message.logs_trim` (1 year). Cron jobs only via `cron_run('<job>')` (J4 ratchet).
- Realtime: one private channel per member, `realtime.messages` policy by `auth.uid()`; decided in the delivery step.

## 5. Proposed unit order (names from the handover; mapping is mine — correct it if the plan doc differs)
M1 tables + RLS + rollback + PROBE · M2 `message_send` + member rules · M2b four-mode switch + audit · M2c word guard · M3 push + live delivery · M4 requests / folders · M5 photos · M6 groups (OFF) · M7 limits + rogue-admin alarm, M7b admin viewer · M8 screens (real renders first) · M9 launch checks + attack tests. Android build only after M8.

## 6. Tests every unit must carry (fail before, pass after, on staging)
Another member reading a chat · member under review sending · blocked pair sending · follow-without-follow-back lands in `requests` · same `client_msg_id` twice · oversize body / file · admin read without a log row · UPDATE/DELETE on `messages` · member writing a table directly · each of the four switch modes · `blocked_until` in the past / future.
