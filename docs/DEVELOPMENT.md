# Development guide

## Prerequisites

| For | You need |
|---|---|
| Server | Erlang/OTP 26+ (developed on OTP 29; the Docker image uses 27). Nothing else — no rebar, no deps. |
| iOS app | macOS, **Xcode 26+**, an iOS 26 simulator or device (Liquid Glass APIs). |
| Tests / demo tooling | Python 3 (stdlib only), `curl`. |

## Run the server

```bash
erlc -o ebin -I src src/*.erl                       # compile (ebin/ is gitignored)
erl -noshell -pa ebin -s chat_app start_web_only 8080
```

Open <http://localhost:8080> for the web app. The database (Mnesia) is created in the **current
directory** as `Mnesia.<node>/` and uploads go to `./uploads/`, so run each scratch instance from its own
folder. `-s chat_app start 5555 8080` additionally opens a raw TCP chat port (the legacy CLI client);
hosted deploys use `start_web_only` because they expose one port.

Windows: `.\build.ps1` then `.\run.ps1`. Docker / Render: `Dockerfile` + `render.yaml` (free tier; the
container runs `start_web_only $PORT`).

Optional Google sign-in: `cp src/oauth_config.erl.example src/oauth_config.erl` and fill it in
(gitignored). Guests need nothing.

## Run the iOS app

```bash
open EmberApp/Ember.xcodeproj
```

1. Pick a signing team (Signing & Capabilities). Any Apple ID works for the simulator.
2. Choose an iPhone or iPad simulator and press ⌘R.
3. Log in with any username (or Google if configured).

**Server URL.** `ChatClient.serverURL` (in `Networking/ChatClient.swift`) is `ws://localhost:8080/`, which
works from the simulator because it shares the Mac's network. For a hosted server use `wss://your-host/`.
A *physical device* can't reach `localhost`; use a `wss://` tunnel, or your Mac's LAN IP plus an
`NSAppTransportSecurity › NSAllowsLocalNetworking` entry (ATS blocks plain `ws://` otherwise).

**Project file.** `EmberApp/project.yml` is an [XcodeGen](https://github.com/yonaskolb/XcodeGen) spec,
and `Ember.xcodeproj` is committed. Adding a Swift file means either regenerating with `xcodegen`
(which resets signing settings to `project.yml`'s `DEVELOPMENT_TEAM`, so set it there first) or adding the
file to the project in Xcode.

## Tests

```bash
tests/run.sh
```

Compiles the server, starts a **throwaway** instance (its own database, port 8099), runs 49 end-to-end
checks over the real WebSocket protocol — including restarting the server to prove message ids survive —
and cleans up. See [`tests/README.md`](../tests/README.md). Run it before pushing server changes.

## Launch hooks (screenshots and manual testing)

The simulator can be screenshotted from the command line but not tapped, so the app has a few
launch-time hooks driven by environment variables. Every one is **inert unless its variable is set**.
With `simctl`, prefix each with `SIMCTL_CHILD_`:

```bash
SIMCTL_CHILD_EMBER_AUTOJOIN=alex SIMCTL_CHILD_EMBER_OPEN=group:hike-crew \
  xcrun simctl launch booted com.ember.chat.app
```

| Variable | Effect |
|---|---|
| `EMBER_AUTOJOIN=<name>` | Log in as `<name>` without typing. |
| `EMBER_OPEN=<key>` | Open a chat: `global`, `dm:<user>`, `group:<name>` (waits for it to load). |
| `EMBER_TAB=<tab>` | Start on `chats`, `updates`, `people` or `you`. |
| `EMBER_STORY=<user>` | Open that user's story in the Updates tab. |
| `EMBER_MEMBERS=1` | Open the group info sheet (with `EMBER_OPEN=group:…`). |
| `EMBER_ACTION=<n>` | Show the long-press menu on the n-th newest message. |
| `EMBER_SEARCH=<text>` | Open in-chat search with that query. |
| `EMBER_PROFILE=<user>` | Show that user's profile card. |
| `EMBER_VIEWER=1` | Open the newest photo in the full-screen viewer. |
| `EMBER_NO_NOTIF=1` | Don't ask for notification permission (the prompt would cover screenshots). |

To regenerate the README screenshots end to end, see [`tools/demo/`](../tools/demo/README.md).

## Repository map

```
src/                Erlang server (see docs/ARCHITECTURE.md)
web/                web app + PWA files
EmberApp/           iOS app (Swift/SwiftUI) and its Xcode project
tests/              end-to-end protocol tests (Python, stdlib only)
tools/demo/         demo data seeding + screenshot capture scripts
docs/               protocol, architecture, this guide, screenshots
Dockerfile, render.yaml     hosted deploy
```

## Troubleshooting

- **App shows "Reconnecting…" forever** — the server isn't reachable at `serverURL`, or another session
  already holds your username (names are unique while online; a stale socket clears within seconds).
- **`Username taken` on login** — that name is online (e.g. the same account in another simulator).
- **Server won't start after adding a field to a Mnesia record** — the migration waits up to 30 s for the
  table; if it still fails, move `Mnesia.*/` aside (it is only local data).
- **A new Swift file isn't compiled** — it isn't in the Xcode project yet (see *Project file*).
