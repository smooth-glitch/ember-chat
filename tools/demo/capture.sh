#!/bin/bash
# Captures the README screenshots from the iOS simulator using the launch hooks in docs/DEVELOPMENT.md.
# Prereqs: seed.py has run phase 1+2 against the server the app points at (ws://localhost:8080/ by default),
# the app is built, and DEVICE is a booted simulator UDID.   Usage: DEVICE=<udid> ./capture.sh path/to/Ember.app
set -e
: "${DEVICE:?set DEVICE to a booted simulator UDID (xcrun simctl list devices booted)}"
APP="${1:?path to the built Ember.app}"; BUNDLE=com.ember.chat.app; OUT="${OUT:-shots}"; mkdir -p "$OUT"

xcrun simctl status_bar "$DEVICE" override --time "9:41" --batteryState charged --batteryLevel 100 \
  --cellularBars 4 --wifiBars 3 --operatorName ""
xcrun simctl ui "$DEVICE" appearance dark
xcrun simctl uninstall "$DEVICE" $BUNDLE 2>/dev/null || true
xcrun simctl install "$DEVICE" "$APP"

# Pin / mute / archive state lives in UserDefaults; seed it directly in the app container.
PREFS="$(xcrun simctl get_app_container "$DEVICE" $BUNDLE data)/Library/Preferences"; mkdir -p "$PREFS"
python3 - "$PREFS/$BUNDLE.plist" <<'PY'
import plistlib, sys
plistlib.dump({"ember.pinned": ["group:hike-crew"], "ember.muted": ["group:movie-night"],
               "ember.archived": ["dm:sofia"], "ember.appearance": "system", "ember.haptics": True},
              open(sys.argv[1], "wb"))
PY

shot() {   # shot <name> <seconds to wait> [ENV=VALUE ...]
  local name=$1 wait=$2; shift 2
  xcrun simctl terminate "$DEVICE" $BUNDLE >/dev/null 2>&1 || true; sleep 1.5
  env "${@/#/SIMCTL_CHILD_}" SIMCTL_CHILD_EMBER_AUTOJOIN=alex SIMCTL_CHILD_EMBER_NO_NOTIF=1 \
    xcrun simctl launch "$DEVICE" $BUNDLE >/dev/null
  sleep "$wait"; xcrun simctl io "$DEVICE" screenshot "$OUT/$name.png" >/dev/null 2>&1; echo "captured $name"
}

shot everyone      16 EMBER_OPEN=global
shot direct        12 EMBER_OPEN=dm:maya
shot group         12 EMBER_OPEN=group:hike-crew
shot group-info    12 EMBER_OPEN=group:hike-crew EMBER_MEMBERS=1
shot actions       13 EMBER_OPEN=global EMBER_ACTION=6
shot search        12 EMBER_OPEN=global EMBER_SEARCH=trail
shot profile       12 EMBER_OPEN=global EMBER_PROFILE=priya
shot viewer        13 EMBER_OPEN=dm:maya EMBER_VIEWER=1
shot updates        8 EMBER_TAB=updates
shot story-photo    5 EMBER_TAB=updates EMBER_STORY=priya
shot story-text    10 EMBER_TAB=updates EMBER_STORY=maya
shot settings       7 EMBER_TAB=you
