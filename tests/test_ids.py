"""Message ids must keep increasing across server restarts (usage: test_ids.py before|after).

Regression test: ids used to come from erlang:unique_integer/1, which restarts at 1 with every VM
start, so after a restart new messages overwrote stored ones and sorted to the top of history.
"""
import os, sys
from wsclient import Client, check, types, unique

phase = sys.argv[1]
state = os.path.join(os.path.dirname(os.path.abspath(__file__)), ".last_id")
c = Client(unique("id"))
c.drain()
if phase == "before":
    c.send("marker before restart")
    open(state, "w").write(str(c.own_id()))
else:
    prev = int(open(state).read())
    c.send("marker after restart")
    new = c.own_id()
    c.send("/history global")
    rows = {i["id"]: i["text"] for e in types(c.drain(1.5), "history") for i in e["list"]}
    check("new id continues past the pre-restart id", new > prev, f"{new} <= {prev}")
    check("the old message was not overwritten", rows.get(prev) == "marker before restart")
    check("history stays in ascending id order", list(rows) == sorted(rows))
    os.remove(state)
