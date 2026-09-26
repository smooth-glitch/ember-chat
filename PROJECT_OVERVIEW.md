# Ember — Project Overview

A WhatsApp-style chat app: global room, private 1:1 chats, group chats,
photos, voice notes, GIFs, emoji, reactions, replies — built from scratch,
with an Apple "Liquid Glass" visual style, running as a web app (installable
on phones like a real app) and as a native iOS app.

This doc explains what it does and how it's built, in plain terms, for
anyone who isn't reading the code.

---

## 1. What it does (features)

- **Global room** — everyone who joins lands in one shared chat, "Everyone."
- **Private messages** — tap anyone online to open a real 1:1 conversation
  with its own history, unread count and "last seen" time.
- **Group chats** — create a group, invite people, add or remove members
  later. Every group has an **owner**, a photo and a description.
- **Photos, GIFs, voice notes, PDFs, camera and location** — share what you
  like from the "+" menu; GIFs and stickers come from a searchable picker.
- **Reactions, replies, edits** — long-press a message to react, reply, edit
  it (your own), forward it, star it or delete it for everyone. Swipe a
  message sideways to reply. Tap a quote to jump to the original.
- **Disappearing messages** — set a timer (1 minute up to 90 days) on any DM
  or group and messages vanish on schedule, on everyone's phone and on the
  server.
- **Status updates ("stories")** — post a text or photo update that lasts 24
  hours; friends watch it full-screen and only you can see who viewed it.
- **Stay organised** — pin, mute, archive, block, search inside a chat, star
  messages to find them later, unread badges everywhere.
- **Typing indicators & read receipts**, delivery ticks on private messages.
- **Sign-in options** — Google account, or just type a username as a guest.
- **Profile & status** — a profile photo and a status line ("Available," "At
  the gym," or your own words).
- **Light & dark mode**, haptics, and layouts for both iPhone and iPad.
- **It fixes itself** — if your connection drops the app reconnects on its
  own and catches up on what you missed.
- **Works on every platform:**
  - **The native iOS app** (SwiftUI) is the main, most complete client.
  - **Any phone or computer, via a normal web browser**, and it can be
    **installed like an app** (a "PWA" — see §4).

---

## 2. The tech stack, in plain terms

| Layer | What it is | Why |
|---|---|---|
| **Backend server** | Erlang/OTP | The language WhatsApp itself is built on. Extremely good at handling thousands of people connected and messaging at once, and very resistant to crashing — if one person's connection has a problem, it doesn't affect anyone else. |
| **Database** | Mnesia | Erlang's *built-in* database — no separate install, no external service, no monthly cost. It ships with the language itself and stores all messages, group info, accounts, and profiles on disk automatically. |
| **Web frontend** | Plain HTML, CSS, JavaScript | One self-contained page (`web/index.html`). No frameworks (no React/Vue/etc.), which keeps it fast and simple to run anywhere with just a browser. |
| **Native iOS app** | Swift + SwiftUI | Apple's own modern app-building toolkit, used for the "Liquid Glass" native look and deeper iPhone integration (camera, Face ID-style flows, native share sheet, etc.). |
| **Real-time messaging** | WebSocket | A permanently-open connection between your browser/app and the server, so messages appear instantly rather than the app having to keep asking "any updates?" |
| **Hosting** | Docker + Render (free tier), or your own laptop | The included `Dockerfile` packages the server so it can run on any free container host; it also runs locally with one command. |

**No paid infrastructure anywhere in this stack.** Erlang, Mnesia, the web
frontend, and free-tier container hosting are all free. The only paid thing in the
entire project is an optional Apple Developer account ($99/year), needed
only if we ever want to publish the iOS app on the App Store — the app runs
fine on a phone without it.

---

## 3. How a message actually gets from one phone to another

1. You open the app (browser or the iOS app) and it opens one persistent
   connection to the server (the WebSocket mentioned above).
2. You type a message and hit send. It's sent over that connection to the
   Erlang server.
3. The server saves it in the database (Mnesia) and immediately forwards it
   to everyone else who should see it — the whole room, or just the other
   person in a DM, or everyone in a group — over *their* open connections.
4. Because the connection is always open, this happens in a fraction of a
   second — there's no "refresh to see new messages."

If your phone loses signal and reconnects, the app automatically
re-establishes that connection and catches up on anything it missed.

---

## 4. What "installable web app" (PWA) actually means

Normally a website just lives in a browser tab. This one can also be
"installed": on Android, Chrome will offer "Add to Home Screen" (or you can
trigger it from the menu); on iPhone it's Safari's "Add to Home Screen."
Either way, it then behaves like a regular app — its own icon, opens
full-screen with no browser bar around it — while still just being the same
web app under the hood. This is how we get "one app that works on every
Android phone" without building and maintaining a separate native Android
app.

---

## 5. Native iOS app — what's different

The iOS app is an independent build of the same idea, written specifically
for Apple's ecosystem, using the same server/database as the backend — so a
web user and an iOS-app user can chat with each other normally. It is where
all the newest features live (edit, stories, disappearing messages, group
admin, PDFs, reconnect). What it adds on top of the web version:

- The real **Liquid Glass** material (Apple's design system introduced for
  iOS 26) — genuine translucent/blurred glass controls floating over the
  content, which only Apple's own toolkit can render authentically. The web
  app *mimics* the look with CSS blur effects.
- **Real end-to-end encryption for private 1:1 messages** — the server only
  ever sees and stores scrambled (encrypted) text for DMs sent from the
  iOS app; only the two people chatting can read them. This covers private
  DMs only, not groups or the global room, and has not been added to the
  web version yet.
- Native camera and photo pickers, voice recording, share sheet, haptics,
  notifications, and an iPad split-view layout.
- Sign in with Apple is switched off on this build because it requires the
  paid Apple Developer account.

---

## 6. Security & privacy notes (for the honest version, not the sales pitch)

- Regular messages (global room, groups, and web DMs) are stored in plain
  form in the server's database, the same way most chat apps' server-side
  history works.
- Only iOS-app-to-iOS-app private messages currently get true end-to-end
  encryption.
- Sign-in credentials (Google/Apple) are never stored by this app — sign-in
  uses the standard OAuth flow, where Google/Apple confirm who you are and
  the app only ever receives your name/email, never your password.
- The Google/Apple API keys that let "Sign in with Google/Apple" work are
  kept in one local, private config file that is deliberately **excluded**
  from the GitHub repository, so they can't leak if the code is shared.

---

## 7. Project layout (for anyone poking around the code)

```
src/            Erlang backend (the server + database logic)
web/            The web app (single HTML file + PWA install files)
EmberApp/       The native iOS app (Swift/SwiftUI)
tests/          Automated end-to-end tests for the server
tools/demo/     Scripts that build a demo and take the README screenshots
docs/           Technical documentation and screenshots
```

Technical details for developers live in `README.md` and the `docs/` folder:
`docs/ARCHITECTURE.md` (how it's built), `docs/PROTOCOL.md` (how the app and
server talk), and `docs/DEVELOPMENT.md` (how to run and test it).
