<h1 align="center">🔥 Ember</h1>

<p align="center">
  <b>Real-time chat, built from scratch — no frameworks, no external database.</b><br/>
  A WhatsApp-style chat app on a hand-rolled <b>Erlang/OTP</b> backend, with a native-feeling
  <b>Liquid Glass</b> web app (installable on any phone) and a <b>SwiftUI</b> iOS app.
</p>

<p align="center">
  🌐 <a href="https://crumpet-troubling-surely.ngrok-free.dev" target="_blank"><b>Live Demo</b></a>
</p>

<p align="center">
  <img src="https://img.shields.io/badge/status-active-brightgreen?style=for-the-badge" alt="status"/>
  <img src="https://img.shields.io/badge/license-private-lightgrey?style=for-the-badge" alt="license"/>
</p>

---

## 🚀 Features

- 💬 **Global room, private DMs, and groups** — each with its own conversation view, history, and unread badges
- 😊 **Emoji, GIF & sticker pickers** — searchable, powered by Giphy
- 📸 **Photos & voice notes** — camera/gallery upload, in-app voice recording with a live waveform
- ↩️ **Swipe-to-reply, long-press reactions, delete-for-everyone** — the interactions you'd expect from a real chat app
- 🟢 **Typing indicators & read receipts**
- 🔐 **Google / Apple sign-in, or guest usernames** — no account required to try it
- 🖼️ **Profile photos & status**, light/dark theme that follows your system
- 📱 **Installable like a real app** (PWA) on Android, iPhone, and desktop — no app store needed
- 🔒 **Real end-to-end encryption** for DMs in the native iOS app (X25519 + AES-GCM)
- ♻️ **Self-healing backend** — OTP supervisors restart any crashed piece automatically; one bad connection never takes down another user's

A full plain-language walkthrough of every feature and how it's built lives in [`PROJECT_OVERVIEW.md`](PROJECT_OVERVIEW.md).

---

## 💻 Tech Stack

<p align="center">
  <img src="https://img.shields.io/badge/Erlang%2FOTP-A90533?style=for-the-badge&logo=erlang&logoColor=white" alt="Erlang/OTP"/>
  <img src="https://img.shields.io/badge/Mnesia-A90533?style=for-the-badge" alt="Mnesia"/>
  <img src="https://img.shields.io/badge/WebSocket-black?style=for-the-badge&logo=websocket&logoColor=white" alt="WebSocket"/>
  <img src="https://img.shields.io/badge/JavaScript-F7DF1E?style=for-the-badge&logo=javascript&logoColor=black" alt="JavaScript"/>
  <img src="https://img.shields.io/badge/PWA-5A0FC8?style=for-the-badge&logo=pwa&logoColor=white" alt="PWA"/>
  <img src="https://img.shields.io/badge/Swift-F05138?style=for-the-badge&logo=swift&logoColor=white" alt="Swift"/>
  <img src="https://img.shields.io/badge/SwiftUI-0066CC?style=for-the-badge&logo=swift&logoColor=white" alt="SwiftUI"/>
  <img src="https://img.shields.io/badge/OAuth%202.0-4285F4?style=for-the-badge&logo=google&logoColor=white" alt="OAuth"/>
</p>

Everything runs on stock Erlang/OTP — no Cowboy, no Phoenix, no external database. The
HTTP/WebSocket layer, the OAuth flow, and persistence (via Mnesia, which ships with Erlang
itself) are all hand-rolled. Zero paid infrastructure anywhere in the stack.

---

## 🧩 Project Layout

```bash
src/            # Erlang backend — server, protocol, Mnesia persistence
web/            # Web app: single-page frontend + PWA install files
EmberApp/       # Native iOS app (Swift/SwiftUI)
build.ps1       # Windows: compile the backend
run.ps1         # Windows: start the server
```

---

## 🛠️ Setup Instructions

### 1️⃣ Clone the repository

```bash
git clone https://github.com/smooth-glitch/ember-chat.git
cd ember-chat
```

### 2️⃣ Install Erlang/OTP

Free, official installer: https://www.erlang.org/downloads — that's the entire toolchain,
no other dependencies to install.

### 3️⃣ (Optional) Add Google Sign-In credentials

```bash
cp src/oauth_config.erl.example src/oauth_config.erl
```

Fill in your own Google OAuth client ID/secret (see comments in that file for how to get
them). Skip this step entirely if you just want to try the app as a guest — no setup needed.

### 4️⃣ Build & run

**Windows (PowerShell):**

```powershell
.\build.ps1
.\run.ps1
```

**macOS/Linux:**

```bash
erlc -o ebin src/*.erl
erl -noshell -pa ebin -s chat_app start 5555 8080
```

Then open 👉 [http://localhost:8080](http://localhost:8080)

---

## 🏗️ Architecture

```
chat_app / chat_app_sup   entry point + supervisor (restarts any crashed piece)
chat_room                 gen_server: online-user registry, routes DMs/broadcasts
chat_groups               gen_server: group membership + message routing
chat_web / chat_web_listener   hand-rolled HTTP + WebSocket server (port 8080)
chat_store                Mnesia persistence: messages, groups, accounts, profiles
chat_oauth / oauth_config Google/Apple Sign-In
chat_gif / chat_link_preview   Giphy search, link-preview fetching
web/index.html            the entire browser frontend (single page, PWA-installable)
EmberApp/                 native SwiftUI iOS app, same protocol/backend
```

Each connected user is its own lightweight Erlang process — the same concurrency model
WhatsApp's own backend runs on. One user's connection crashing never affects anyone else's.

---

## 📡 Protocol

No REST API — the client sends plain-text commands over the WebSocket (`/msg`, `/reply`,
`/react`, `/delete`, `/setavatar`, …) and receives JSON events back (`chat`, `history`,
`reaction`, `deleted`, `profile`, …). See `src/chat_web.erl` for the full command set.

---

## 🔒 Security Notes

- Regular messages are stored server-side like any chat app's history; only iOS-to-iOS DMs
  currently get true end-to-end encryption.
- OAuth credentials live in a local, gitignored config file (`src/oauth_config.erl`) and are
  never committed — see `src/oauth_config.erl.example` for the template.
- Sign-in never touches a password: Google/Apple confirm identity, the app only ever
  receives a name/email.
