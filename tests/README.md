# Tests

End-to-end regression tests: they drive a real server over the same WebSocket protocol the apps use
(stdlib-only Python 3, no dependencies).

```bash
tests/run.sh            # compile, start a throwaway server + database, run everything, clean up
```

Or against a server you already started (use a scratch one, the tests create users and messages):

```bash
EMBER_PORT=8080 python3 tests/run_all.py
```

| File | Covers |
|---|---|
| `test_messaging.py` | timestamps, edit / react / delete rules, emoji that end in byte `0x85`, DM edits, bare-command safety, last seen |
| `test_groups.py` | owner role, add / remove members, description + icon, owner-only rules, ownership transfer, disappearing messages (groups and DMs) |
| `test_status_and_dms.py` | status updates (stories) incl. view privacy, `/dms` chat-list command, upload validation |
| `test_ids.py` | message ids keep increasing across a server restart (run by `run.sh`) |

Several tests are regressions for real bugs found while building the iOS app (see
`docs/ARCHITECTURE.md`, "Lessons learned").
