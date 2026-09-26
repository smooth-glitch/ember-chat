# Ember wire protocol

Ember has no REST API. Clients hold one WebSocket open and speak a **plain-text command protocol**
upstream and **JSON events** downstream. Both the web app and the iOS app use exactly this.

- Endpoint: `ws://<host>:8080/` (put TLS in front for `wss://`).
- The **first text frame** you send is your username (max 24 chars). The server answers with a
  `welcome` event, or an `error` if the name is empty or taken.
- Every later text frame is either a **command** (starts with `/`) or ordinary **chat text** for the
  global room.
- Limits: message text 2000 chars, WebSocket frame 64 KiB, group name 32 chars, upload 8 MB.
- Downstream text frames are always **valid UTF-8** (the server repairs anything that isn't, because
  browsers and iOS close the socket on an invalid text frame).
- Ids (`id`, `messageId`) are integers, unique across every conversation and strictly increasing,
  including across server restarts.
- Timestamps (`ts`, `exp`, `lastSeen`) are Unix **milliseconds**. `exp` / `lastSeen` of `0` or `null`
  means "none / unknown".

Try it by hand:

```bash
# any WebSocket client, e.g. websocat
websocat ws://localhost:8080/
alice                       # first frame = username  ->  {"type":"welcome","name":"alice"}
hello everyone              # chat text
/msg bob hi                 # command
```

The stdlib-only client in [`tests/wsclient.py`](../tests/wsclient.py) is a compact reference implementation.

## Conversations

Three kinds, addressed the same way in almost every command:

| Scope | Argument form | History key |
|---|---|---|
| Global room | `global` | `global` |
| Direct message | `dm <user>` | `dm:<a>\|<b>` (names sorted) |
| Group | `group <name>` | `group:<name>` |

## Commands (client → server)

### Messaging

| Command | Effect |
|---|---|
| `<text>` | Post to the global room. |
| `/msg <user> <text>` | Direct message. For the iOS app `<text>` is an `ember:` ciphertext (see *Encryption*). |
| `/groupmsg <group> <text>` | Message a group you belong to. |
| `/reply <id> <text>` · `/replydm <user> <id> <text>` · `/replygroup <group> <id> <text>` | Same as above, quoting message `<id>`. |
| `/edit <scope…> <id> <new text>` | Replace the text of **your own**, non-deleted message. Scope is `global`, `dm <user>` or `group <name>`. |
| `/delete <scope…> <id>` | Delete **your own** message for everyone (the row stays; clients show "This message was deleted"). |
| `/react <scope…> <id> <emoji>` | Toggle your reaction. You may hold several different emoji on one message. |
| `/typing <scope…>` | Typing ping. There is no "stopped typing" event; clients expire it after ~3 s. |
| `/read dm <user>` | Mark that DM as read (drives ✓✓). |
| `/history <scope…>` | Last 50 non-expired messages, oldest first. |

### Chat list, presence, profiles

| Command | Effect |
|---|---|
| `/list` | Currently online users → `users`. |
| `/dms` | Everyone you have a live DM conversation with, most recent first → `dms`. Lets a client rebuild its chat list after a relaunch. |
| `/groups` | Groups you belong to (with owner, description, icon) → `groups`. |
| `/getprofile <user>` | → `profile` (avatar, status, `lastSeen`). |
| `/setavatar <url>` · `/setstatus <text>` | Update your profile; broadcast to everyone as `profile`. |
| `/pubkey <base64>` · `/getpubkey <user>` | Publish / fetch a DM public key (see *Encryption*). |
| `/gifsearch [q]` · `/stickersearch [q]` | Giphy search (trending when `q` is empty) → `gif_results` / `sticker_results`. |

### Groups

| Command | Effect |
|---|---|
| `/creategroup <name>` | Create a group; you become its **owner**. |
| `/addmember <group> <user>` | Any member can add an *online* user. |
| `/removemember <group> <user>` | **Owner only**; the owner cannot be removed. |
| `/leavegroup <group>` | Leave. If the owner leaves, ownership passes to the next member; the last member leaving deletes the group. |
| `/groupinfo <group>` | Current description + icon, to you only → `group_meta`. |
| `/setgroupdesc <group> <text>` · `/setgroupicon <group> <url>` | **Owner only**. Description ≤ 200 chars. Broadcast to members as `group_meta`. |

> Group names must not contain spaces (arguments are split on the first space).

### Disappearing messages

`/disappear dm <user> <seconds>` · `/disappear group <name> <seconds>`

Any participant / member can set the timer; `0` turns it off, max 90 days (7 776 000). It applies to
messages sent *from then on*. Each message stores its own `exp`; expired messages are omitted from
history and swept from disk every 15 s. Both sides get a `disappear` event.

### Status updates ("stories")

| Command | Effect |
|---|---|
| `/poststatus text <bg 0-15> <text>` | Text post (≤ 700 chars) on colour palette `<bg>`. |
| `/poststatus image <url>` | Photo post (upload the image first). |
| `/statuses` | All live posts → `statuses`. Only the author's own posts carry `views`. |
| `/viewstatus <id>` | Record that you watched it; the author gets `status_view` (once per viewer). |
| `/deletestatus <id>` | Author only; pushed to everyone as `status_deleted`. |

Posts expire 24 h after creation.

## Events (server → client)

Every event is a JSON object with a `type`.

### Session

| `type` | Fields |
|---|---|
| `welcome` | `name` |
| `error` | `text` — a problem with your last command (not necessarily fatal) |
| `system` | `text` — join / leave notices for the global room |
| `users` | `list` — online usernames |

### Messages

| `type` | Key fields |
|---|---|
| `chat` | `id, from, text, ts, exp, replyTo` — global message |
| `private` | same, from a DM partner |
| `group_message` | same, plus `group` |
| `own_message_id` · `dm_ack` · `group_msg_ack` | `id` (`dm_ack` also `status`) — the id assigned to the message you just sent (the server never echoes it back) |
| `history` | `scope`, `with` / `group`, `list` of `{id, from, text, private, reactions, deleted, edited, ts, exp, replyTo, previewUrl, previewTitle, previewDescription, previewImage}` |
| `reaction` · `dm_reaction` · `group_reaction` | `messageId, reactions:[{user,emoji}]` |
| `deleted` · `dm_deleted` · `group_deleted` | `messageId` (+ conversation fields) |
| `edited` · `dm_edited` · `group_edited` | `messageId, text` (+ conversation fields) |
| `link_preview` · `dm_link_preview` · `group_link_preview` | `messageId, previewUrl, previewTitle, previewDescription, previewImage` — pushed shortly after a message containing a URL |
| `typing` · `typing_dm` · `group_typing` | who is typing, and where |
| `dm_read` | `from` — that user opened your DM |

### Groups & chat list

| `type` | Fields |
|---|---|
| `groups` | `list:[{name, members, owner, description, icon}]` |
| `group_created` · `added_to_group` | `name, members` (+ `by`) |
| `group_members` | `name, members, owner` — pushed to **every** member on any join / leave / removal |
| `group_meta` | `name, description, icon` |
| `group_system` | `group, text` — "X added Y to the group" |
| `left_group` | `text` = group name (you left or were removed) |
| `dms` | `list:[{user, ts}]` |
| `disappear` | `scope` (`dm`/`group`), `target`, `seconds`, `by` (`""` when it's just the current setting sent with history) |

### Profiles & media

| `type` | Fields |
|---|---|
| `profile` | `user, avatar, status`, and `lastSeen` (only in replies to `/getprofile`) |
| `pubkey` | `user, key` |
| `gif_results` · `sticker_results` | `list:[{preview, url}]` |

### Status updates

| `type` | Fields |
|---|---|
| `statuses` | `list` of items |
| `status_new` | `item` |
| `status_deleted` | `id` |
| `status_view` | `id, viewer` (author only) |

A status **item** is `{id, user, kind: "text"\|"image", content, bg, ts, exp}` plus `views: [user]` for
the author's own posts.

## HTTP

| Route | Purpose |
|---|---|
| `GET /`, `/manifest.json`, `/sw.js`, `/icons/*` | The web app (a PWA). |
| `POST /upload` | `multipart/form-data`, field `file`. Returns `{"url": "/uploads/<random>.<ext>"}`. PNG, JPEG, GIF, WebP, WebM/Ogg/M4A audio and **PDF**, ≤ 8 MB. The declared content type is never trusted: the file's magic bytes must match, so a renamed non-image can't get in. |
| `GET /uploads/<file>` | Serves uploads with HTTP `Range` support (needed for audio scrubbing) and `X-Content-Type-Options: nosniff`. |
| `GET /auth/google/*`, `/auth/apple/*`, `/auth/session` | OAuth sign-in (optional; guests just type a name). |

## Encryption (direct messages, iOS app)

The iOS app encrypts DMs end to end: each device makes an **X25519** key pair, publishes the public
half with `/pubkey`, derives a shared secret with the partner's key (`/getpubkey`), and sends
`AES-GCM` ciphertext prefixed `ember:`. The server only stores and relays ciphertext. Global chat,
groups, and web-app DMs are not end-to-end encrypted (multi-party schemes are a different, larger
problem). Because the server treats DM text as opaque, `/edit` works on ciphertext too.

## Robustness rules the server enforces

- **Bare or malformed commands are never broadcast** as chat text (`/edit` with no arguments is
  swallowed).
- Only the message **author** may edit or delete; only a group's **owner** may remove members or change
  its description / icon; only a status **author** may delete it or see its viewers.
- Text is trimmed on **ASCII whitespace only**. (Trimming as Unicode whitespace once chopped the last
  byte off emoji such as 🌅 ✅ 📅, producing invalid UTF-8 — see `docs/ARCHITECTURE.md`.)
