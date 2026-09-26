"""Groups: owner role, add/remove members, description + icon, live updates, disappearing timer."""
import time
from wsclient import Client, check, types, unique

print("groups")
o, m, x = Client(unique("go")), Client(unique("gm")), Client(unique("gx"))
for c in (o, m, x):
    c.drain()
g = unique("grp")

o.send(f"/creategroup {g}")
ev = o.drain()
check("create sends group_members with owner", any(e.get("owner") == o.name for e in types(ev, "group_members")))
o.send(f"/addmember {g} {m.name}")
o.drain()
check("added member gets added_to_group + group_members", {"added_to_group", "group_members"} <= {e["type"] for e in m.drain()})

o.send(f"/setgroupdesc {g} Weekend plans and memes")
check("owner sets description; every member sees it",
      bool(types(o.drain(), "group_meta")) and types(m.drain(), "group_meta")[0]["description"] == "Weekend plans and memes")
m.send(f"/setgroupdesc {g} hacked")
check("member cannot change description", "owner" in types(m.drain(), "error")[0]["text"])
x.send(f"/setgroupdesc {g} hacked")
check("outsider cannot change description", "owner" in types(x.drain(), "error")[0]["text"])
x.send(f"/groupinfo {g}")
check("outsider gets no group info", not types(x.drain(), "group_meta"))
o.send(f"/setgroupdesc {g} " + "x" * 250)
check("over-long description rejected", "too long" in types(o.drain(), "error")[0]["text"].lower())
o.send(f"/setgroupicon {g} /uploads/abc.png"); o.drain(); m.drain()
m.send("/groups")
listing = [gr for e in types(m.drain(), "groups") for gr in e["list"] if gr["name"] == g][0]
check("groups list carries owner, description, icon",
      listing["owner"] == o.name and listing["description"] == "Weekend plans and memes" and listing["icon"] == "/uploads/abc.png")

m.send(f"/removemember {g} {o.name}")
check("member cannot remove the owner", "owner" in types(m.drain(), "error")[0]["text"].lower())
o.send(f"/removemember {g} {m.name}")
oe, me = o.drain(), m.drain()
check("owner removes member: notice + live list for the rest", bool(types(oe, "group_system")) and types(oe, "group_members")[-1]["members"] == [o.name])
check("removed member's group disappears (left_group)", bool(types(me, "left_group")))

# disappearing messages
o.send(f"/disappear group {g} 3"); o.drain()
o.send(f"/groupmsg {g} ephemeral"); o.drain()
o.send(f"/history group {g}")
h = types(o.drain(1.2), "history")
check("message carries an expiry while the timer is on", bool(h) and h[0]["list"][-1]["exp"] > 0)
time.sleep(3.5)
o.send(f"/history group {g}")
h = types(o.drain(1.2), "history")
check("expired message is gone from history", all(i["text"] != "ephemeral" for e in h for i in e["list"]))

# ownership passes on when the owner leaves
o.send(f"/addmember {g} {m.name}"); o.drain(); m.drain()
o.send(f"/leavegroup {g}"); o.drain()
check("owner leaving hands ownership to the next member", types(m.drain(), "group_members")[-1]["owner"] == m.name)

# DM disappearing messages
p, q = Client(unique("dp")), Client(unique("dq"))
p.drain(); q.drain()
p.send(f"/disappear dm {q.name} 3")
check("DM timer pushed to both sides", bool(types(p.drain(), "disappear")) and bool(types(q.drain(), "disappear")))
p.send(f"/msg {q.name} vanishing"); p.drain(); q.drain()
time.sleep(3.5)
q.send(f"/history dm {p.name}")
check("expired DM gone from history", all(i["text"] != "vanishing" for e in types(q.drain(1.2), "history") for i in e["list"]))
p.send(f"/disappear dm {q.name} abc")
check("bad timer value rejected", bool(types(p.drain(), "error")))
