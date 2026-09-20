# Erlang Chat Server

A basic multi-user chat server, WhatsApp-style: create a username, see who's
online, broadcast to everyone, or send a private message. Built on stock
Erlang/OTP only — no paid services, no external dependencies.

## Why Erlang fits this problem

Each connected client is its own lightweight process. One client crashing
or disconnecting doesn't affect anyone else, and a supervisor restarts the
core server pieces automatically if they ever fail. This is the same
concurrency model WhatsApp's backend (built on Erlang) uses to handle
millions of simultaneous connections.

## Architecture

```
chat_app          entry point, starts the supervisor
chat_app_sup       supervisor: restarts any of the pieces below if they crash
chat_room          gen_server: registry of online users, routes 1:1 messages
chat_groups        gen_server: group membership + group message routing
chat_listener      gen_server: accepts raw TCP connections (port 5555)
chat_client_handler one process per raw-TCP client, owns that socket
chat_client        optional PowerShell/erl test client (no telnet required)
chat_web_listener  gen_server: accepts HTTP/WebSocket connections (port 8080)
chat_web           serves the browser UI and speaks the WebSocket protocol
chat.hrl           shared limits (username/message/group name/frame size caps)
web/index.html     the browser frontend (single self-contained page)
```

`chat_groups` is deliberately a separate process from `chat_room` — it only
knows group membership (a plain map of group name -> {owner, members}) and
resolves who to route a group message to by asking `chat_room:get_pid/1`,
rather than keeping its own copy of the online-user registry. Neither
module needs to know the other exists beyond that one call.

Two independent front doors lead to the same `chat_room`: raw TCP on 5555
(for `client.ps1` or telnet-style clients) and a browser UI over HTTP +
WebSocket on 8080. Both are hand-rolled directly on `gen_tcp` — no
cowboy/ranch/rebar3 dependency, so there's nothing extra to install.

Flow for the browser: `chat_web_listener` accepts a connection and hands it
to `chat_web`, which parses the HTTP request. A plain `GET /` gets served
`web/index.html`; a request with an `Upgrade: websocket` header gets the
RFC 6455 handshake and becomes a WebSocket. From there it behaves exactly
like a TCP client — first message is the username, then it registers with
`chat_room` and relays messages, just JSON-encoded instead of plain text.
`chat_room` keeps a map of username -> pid and monitors each one, so a
dropped connection (browser tab closed, TCP client killed) is cleaned up
and announced automatically, regardless of which front door it came in.

Both front doors also enforce the same limits from `chat.hrl` — usernames
capped at 24 characters, messages at 2000, and any single WebSocket frame
at 64KB — so one abusive client can't grow the server's memory or flood
every other connected client with an oversized message. This matters once
the server is reachable from the internet rather than just localhost.

## Requirements

- Erlang/OTP — already installed on this machine at
  `C:\Program Files\Erlang OTP`. That's the whole toolchain to build and
  run the app locally, and it's free.
- ngrok — only needed to expose the app to the internet (see below).
  Already installed via `winget install --id Ngrok.Ngrok`; also free.

## Quick start (Windows / PowerShell)

```powershell
.\build.ps1              # compile everything into .\ebin
.\run.ps1                # start the server (Ctrl+C to stop)
```

It prints something like:

```
Chat server: raw TCP on port 5555, web UI on http://localhost:8080
```

**Browser UI (the polished frontend):** open `http://localhost:8080` in
any browser — Chrome, Edge, Firefox, mobile Safari/Chrome too. Pick a
username and start chatting. Open it in a second tab (or a second
browser, or a phone) to chat between two users.

- **Everyone** — the global room, always in your chat list.
- **Private chats** — click anyone in the "Online" list to open a real
  1:1 conversation (not a `/msg`-prefixed hack — its own message history,
  its own row in the chat list, unread badge and all).
- **Groups** — "+ New Group", name it, tick who to invite (or add people
  later from the members panel — 👥 icon in a group's header). Any
  current member can add another online user.
- **Emoji** — the 😊 icon by the composer opens a searchable picker
  (try typing "heart" or "fire").
  - **GIFs/images** — paste a direct image/GIF link (ending in
  `.gif`/`.png`/`.jpg`/`.webp`) as a message and it renders inline
  instead of as plain text. No API key, no account, no third-party
  service involved — it's just an `<img>` pointed at whatever URL you
  sent, so it works with any host (Giphy, Tenor, Imgur, anything).

The layout is responsive — under ~820px wide the sidebar collapses into
a slide-out drawer (tap the ☰ icon) — and it auto-reconnects with
backoff if the connection drops (e.g. switching networks on mobile),
showing a "Reconnecting…" banner rather than just dying.

**Raw TCP client (optional, no browser needed):** in another terminal:

```powershell
powershell -ExecutionPolicy Bypass -File .\client.ps1     # connects to localhost:5555
```

The browser and TCP clients share the same chat — a browser user and a
terminal user can talk to each other. You can also connect with any raw
TCP client (PuTTY in "Raw" mode, Windows' Telnet Client if enabled, `ncat`)
pointed at `localhost 5555`.

## Chatting from across the world

The server already binds all network interfaces (not just localhost), so
it's reachable the moment something routes traffic to it. The fastest free
way to do that without touching your router is an
[ngrok](https://ngrok.com) tunnel, which also gives you HTTPS for free
(ngrok terminates TLS and proxies WebSocket traffic through transparently
— no certificate setup needed on the Erlang side).

**One-time setup** (ngrok's free tier requires a free account — there's no
way around this from a script, it's on their end):
1. Sign up at <https://dashboard.ngrok.com/signup>
2. Copy your authtoken from <https://dashboard.ngrok.com/get-started/your-authtoken>
3. Run once: `ngrok config add-authtoken <your-token>`

**Every time you want to go live:**
```powershell
powershell -ExecutionPolicy Bypass -File .\run.ps1       # window 1: the server
powershell -ExecutionPolicy Bypass -File .\tunnel.ps1     # window 2: the public link
```
`tunnel.ps1` prints a `https://xxxx.ngrok-free.app` URL — send that to
anyone, anywhere, and they land on the same chat UI over HTTPS. The URL
changes every time you restart the tunnel on the free plan; a paid ngrok
plan (or a real deploy — see "What's next") gets you a stable one.

**Security note, worth being upfront about:** this app still has no
accounts or passwords — anyone with the link can join as any username
that isn't already taken. That's fine for a demo shared with people you
trust, but don't treat the link as access-controlled. If real access
control matters, that's the next thing to build, not an afterthought.

## Protocol (once connected)

On the raw TCP client (`client.ps1`) or any telnet-style connection, you
type these commands directly. The browser UI speaks the exact same
commands under the hood — clicking a name sends `/msg`, opening a group
chat sends `/groupmsg`, the "+ New Group" modal sends `/creategroup` then
`/addmember` for each invitee — but you never have to type them there.

1. Enter a username when prompted.
2. Type anything and hit Enter to broadcast it to everyone online.
3. Commands:
   - `/list` — show who's online
   - `/msg <user> <message>` — private message
   - `/creategroup <name>` — create a group (you're the only member)
   - `/addmember <group> <user>` — add an online user to a group you're in
   - `/leavegroup <group>` — leave a group
   - `/groupmsg <group> <message>` — message a group you're in
   - `/groups` — list your groups and their members
   - `/quit` — disconnect

Example session (two terminals):

```
Terminal A                          Terminal B
> alice                             > bob
Welcome, alice!                     Welcome, bob!
                                     * alice has joined  (shown to bob)
hello everyone                  ->  alice: hello everyone
                                     /msg alice hey!
[private] bob: hey!             <-
/creategroup Friends
/addmember Friends bob          ->  * alice added you to group 'Friends' (members: alice, bob)
/groupmsg Friends welcome!      ->  [Friends] alice: welcome!
```

## What's next (if we want to keep going)

- **Accounts/auth** — right now anyone can claim any free username; no
  passwords, no identity verification. This also means group membership
  is tied to a username string, not a real identity — if someone
  disconnects and a different person later claims that same name, they
  inherit the old groups. Real accounts would fix this.
- **Message persistence** — messages aren't stored; closing the server
  clears history, and anyone joining mid-conversation (or a new member
  added to a group) sees nothing prior
- **Rate limiting** — length caps stop oversized messages, but not a
  client sending many small ones quickly
- **GIF search picker** — current GIF support is paste-a-link (free, zero
  setup); a searchable picker would need a Giphy/Tenor API key (their own
  free tier, but another account to set up, like ngrok's)
- A stable public URL (a real deploy, e.g. Fly.io/Render's free tier,
  instead of ngrok's free plan which reassigns the URL on every restart)
- Packaged release (`rebar3`/`relx`) for one-command deploy

## Status update draft (for Monday)

> Built a working Erlang/OTP chat app, with a polished, responsive browser
> frontend: pick a username and get a real WhatsApp-style experience —
> a global room, private 1:1 chats, and groups you can create and add
> people to, each with its own conversation view and unread badges. Emoji
> picker, and pasting a GIF/image link renders it inline. Works on phones
> (auto-reconnects if the connection drops) and is reachable from anywhere
> via a public link, not just this machine. Verified with multiple
> concurrent users end to end, including group creation, invites, group
> messaging, and DMs happening simultaneously.
> Under the hood it's OTP supervisors and gen_servers (no external
> dependencies at all, not even a web framework — the HTTP/WebSocket layer
> is hand-rolled on Erlang's raw sockets), so the server self-heals if a
> piece crashes, and each connected user is an isolated process — the same
> concurrency model WhatsApp's own backend is built on. There's also a
> terminal client for anyone who wants to connect without a browser, and
> it shares the same chat, DMs and groups as the web UI. Known gap, worth
> flagging: there's no login/auth yet, so treat the public link as
> shared-with-people-you-trust, not access-controlled. Next step, if we
> want to take it further, is accounts, message persistence, and a stable
> (non-ngrok) public URL.
