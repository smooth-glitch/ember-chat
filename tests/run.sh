#!/bin/bash
# Compiles the server, starts a THROWAWAY instance (own database, port 8099), runs the whole suite,
# restarts it to prove ids survive a restart, then shuts it down. Your real data is never touched.
set -e
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PORT="${EMBER_PORT:-8099}"; export EMBER_PORT="$PORT"
WORK="$(mktemp -d)"; mkdir -p "$WORK/uploads" "$WORK/ebin"
erlc +nowarn_deprecated_catch -o "$WORK/ebin" -I "$ROOT/src" "$ROOT"/src/*.erl
start() { (cd "$WORK" && erl -noshell -pa "$WORK/ebin" -s chat_app start_web_only "$PORT" >"$WORK/server.log" 2>&1 &) ; sleep 3; }
stop()  { pkill -f "start_web_only $PORT" || true; sleep 1; }
trap 'stop; rm -rf "$WORK"' EXIT
cd "$ROOT/tests"
start
python3 run_all.py
python3 test_ids.py before
stop; start
echo "ids across a restart"
python3 test_ids.py after
