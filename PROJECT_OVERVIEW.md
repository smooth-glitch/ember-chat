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
  with its own history and unread count.
- **Group chats** — create a group, invite people, add members later.
- **Photos & voice notes** — attach a photo from your camera or gallery, or
  record and send a voice note.
- **GIFs & stickers** — searchable picker (powered by Giphy), plus a full
  emoji picker.
- **Reactions & replies** — long-press a message to react with an emoji or
  reply to it; swipe a message sideways to reply, like iMessage/WhatsApp.
- **Typing indicators & read receipts** — see when someone's typing, and
  whether your direct message has been delivered/read.
- **Sign-in options** — Google account, Apple account (native app only — see
  §5), or just type a username as a guest, no account needed.
- **Profile & status** — set a profile photo and a status line (presets like
  "Available," "In a meeting," or your own text), same idea as WhatsApp.
- **Light & dark mode** — follows your device's system setting automatically.
- **Works on every platform:**
  - **Any phone or computer, via a normal web browser** — Windows, Android,
    Mac, iPhone, all from the same codebase.
  - **Installable like a real app** — "Add to Home Screen" on Android/iPhone,
    or "Install" in a desktop browser, gives it its own icon and full-screen
    window, no browser address bar. This is called a **PWA** (Progressive
    Web App) — see §4.
  - **A separate native iOS app**, built in Swift, with the same features
    plus deeper Apple integration (see §5).

---

## 2. The tech stack, in plain terms

| Layer | What it is | Why |
|---|---|---|
| **Backend server** | Erlang/OTP | The language WhatsApp itself is built on. Extremely good at handling thousands of people connected and messaging at once, and very resistant to crashing — if one person's connection has a problem, it doesn't affect anyone else. |
| **Database** | Mnesia | Erlang's *built-in* database — no separate install, no external service, no monthly cost. It ships with the language itself and stores all messages, group info, accounts, and profiles on disk automatically. |
| **Web frontend** | Plain HTML, CSS, JavaScript | One self-contained page (`web/index.html`). No frameworks (no React/Vue/etc.), which keeps it fast and simple to run anywhere with just a browser. |
| **Native iOS app** | Swift + SwiftUI | Apple's own modern app-building toolkit, used for the "Liquid Glass" native look and deeper iPhone integration (camera, Face ID-style flows, native share sheet, etc.). |
| **Real-time messaging** | WebSocket | A permanently-open connection between your browser/app and the server, so messages appear instantly rather than the app having to keep asking "any updates?" |
| **Hosting for the demo** | ngrok | A tool that takes the server running on this laptop and gives it a real internet address, without needing to rent/set up a cloud server. |

**No paid infrastructure anywhere in this stack.** Erlang, Mnesia, the web
frontend, and the free ngrok tier are all free. The only paid thing in the
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

The iOS app is a second, independent build of the same idea, written
specifically for Apple's ecosystem, using the same server/database as
backend — so a web user and an iOS-app user can chat with each other
normally. What it adds on top of the web version:

- The real **Liquid Glass** material (Apple's newest design system,
  introduced for iOS 26) — genuine translucent/blurred glass panels that
  only Apple's own toolkit can render authentically. The web app *mimics*
  this look with CSS blur effects, which get it very close, but the native
  version is the real thing.
- **Real end-to-end encryption for private 1:1 messages** — the server only
  ever sees and stores scrambled (encrypted) text for DMs sent from the
  iOS app; only the two people chatting can read them. This is scoped to
  private DMs only, not the group/global rooms. *(This encryption has not
  yet been added to the web version — a possible next step.)*
- Native camera/photo picker, native voice recording, native share sheet.
- Sign in with Apple (in addition to Google) — this specifically requires
  the paid Apple Developer account mentioned above, so it's currently
  switched off on this build.

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
build.ps1       Windows: compiles the backend
run.ps1         Windows: starts the server
```

Full technical/architecture details for developers live in `README.md` in
the same folder as this file.
