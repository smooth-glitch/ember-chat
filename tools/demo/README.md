# Demo data + screenshot tooling

How the screenshots in the main README were made, reproducibly.

```bash
# 1. a scratch server with its own empty database (never your real one)
mkdir -p /tmp/ember-demo/uploads && cd /tmp/ember-demo
erlc -o ebin -I <repo>/src <repo>/src/*.erl     # or reuse <repo>/ebin
erl -noshell -pa <repo>/ebin -s chat_app start_web_only 8080 &

# 2. placeholder photos (downloaded, not committed)
<repo>/tools/demo/fetch_assets.sh

# 3. seed the demo, in a second terminal (EMBER_PORT must match the server)
cd <repo>/tools/demo && EMBER_PORT=8080 python3 seed.py
#    ...log the iOS app in as "alex" (EMBER_AUTOJOIN=alex), then:
touch go2

# 4. capture (booted simulator UDID from `xcrun simctl list devices booted`)
DEVICE=<udid> ./capture.sh <path to built Ember.app>
```

The captures use launch-time hooks compiled into the app (documented in `docs/DEVELOPMENT.md`), because
the simulator can be screenshotted from the command line but not tapped.
