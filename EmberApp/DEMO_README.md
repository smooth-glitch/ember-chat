# Ember (native) — demo guide

## What's here

A SwiftUI iOS app that talks to the *same* Erlang server as the web app
(`web/index.html`), over the same raw WebSocket protocol, no changes to the
backend. Scope: the global chat room, deeply — join, history, live
send/receive, reactions, replies, typing indicators, image/GIF messages,
online users. Real Apple Liquid Glass (`.glassEffect()`, iOS 26+), not a CSS
approximation.

## Status (second pass)

Added and verified live against the real server tonight: **reactions**
(long-press a bubble → reaction bar + Reply/Copy menu, or tap an existing
pill), **replies** (swipe a bubble right, or long-press → Reply — GIF/photo
replies show a thumbnail + badge, not a raw URL), **typing indicators**
(topbar subtitle swaps to "X is typing…" live), **image/GIF messages**
render inline, and the earlier **"0 online" bug is fixed**.

Verified end-to-end by scripting a second WebSocket client that joined,
typed, sent a message, and reacted, while screenshotting the real app to
confirm it updated live — online count, typing indicator appearing *and*
clearing, live message delivery, and reaction pills all confirmed working
against real data.

**Not yet tap-tested**: the actual long-press gesture, swipe-to-reply
gesture, and in-app send button, since there's still no simulator input
automation available, only screenshots. The data layer under all of them is
proven correct (every server command and every live push has been exercised
for real); what's unverified is purely "does the gesture recognizer fire
correctly on a real touch," which only shows up by actually touching the
screen.

## Before you touch Xcode

The Erlang server must be running — same as always:

```
cd "/Users/idris/Desktop/erlang whatsapp"
# however you've been starting it (erl -sname chatdev ...); check srv.out
```

Confirm it's up: `curl -s -o /dev/null -w "%{http_code}\n" http://localhost:8080/` → `200`

## Opening the project

```
open "/Users/idris/Desktop/erlang whatsapp/EmberApp/Ember.xcodeproj"
```

First build will ask you to pick a signing team — any option works for
simulator-only; for a real device, pick your personal team (free, no paid
account needed).

## What to check first (do this before anyone else touches it)

1. Run on one simulator (⌘R). Confirm:
   - Login screen looks right (glass card, gradient background)
   - Typing a username + "Join chat" connects and shows history, "N online"
     correct (not "0")
   - Sending a message shows it immediately
   - **Long-press a message bubble** → reaction bar + Reply/Copy overlay
     appears; tapping an emoji reacts, Reply opens the reply banner, Copy
     copies the text
   - **Swipe a message right** → a reply arrow fades in, releasing past
     ~64pt opens the reply banner for that message
   - Reply to a GIF/photo message → banner shows a thumbnail + badge, not a
     raw URL
   - Start typing on one device → a *second* device/simulator should show
     "X is typing…" in its topbar (you won't see your own typing indicator,
     same as the web app)
2. Run a second instance on a different simulator (Product → Destination →
   pick another device, ⌘R again — or `xcrun simctl` for a third/fourth).
   Send a message from one, confirm it appears live on the other; react to
   a message from one, confirm the pill updates live on the other.
3. If anything's broken, tell me what you're seeing and I'll fix it in the
   Swift files directly — I don't need Xcode open to do that, just the
   error/symptom.

## Demoing with 3-4 "users"

Run the app on several simulator instances simultaneously (Xcode → Window →
Devices and Simulators, or just launch a few from `xcrun simctl boot`), each
with a different username. They all hit the same local server, same as
multiple browser tabs would. No paid Apple Developer account needed for
this — simulators are free and unlimited.

If you want it on a real device instead of/in addition to simulators:
`ChatClient.swift`'s `serverURL` is `ws://localhost:8080/`, which only
resolves for simulators (they share the Mac's network stack). For a real
iPhone, swap it for the ngrok `wss://` URL already used elsewhere in this
project (`ngrok_live.log` has the current one) — no other code changes
needed, ATS allows real `wss://` hosts by default.

## Status (third pass)

Added DMs and groups: a conversation list screen (Chats + Online users) is
now the landing screen after login. Tap an online user to DM them, tap the
people icon to create a group. Verified live by scripting a second/third
WebSocket client that DM'd and created+messaged a group while screenshotting
the real app — both appeared correctly in the chat list with live message
previews.

## Known gaps (by design, not bugs) — cut for time, not forgotten

GIF/sticker picker, voice notes, image upload from the device, OAuth, DM
read receipts. The server already supports all of these; `ChatClient.swift`
already threads the fields needed to layer them in later. Tell me which one
matters most if there's time before the demo.

## If the demo needs a fallback

The web app (`web/index.html`) is untouched and still fully working — if
something in the native build won't cooperate right before the demo, that's
always the safe fallback to present instead.
