"""Global/DM messaging: timestamps, edit, react, delete, unicode safety, last seen."""
import time
from wsclient import Client, check, types, unique

print("messaging")
a, b, c = Client(unique("ma")), Client(unique("mb")), Client(unique("mc"))
for x in (a, b, c):
    x.drain()

# global chat: live push carries a timestamp and an expiry field
a.send("hello global")
gid = a.own_id()
push = types(b.drain(), "chat")
check("global push carries ts + exp", bool(push) and push[0].get("ts", 0) > 0 and "exp" in push[0])
c.drain()

# edit: only the author, only while not deleted; unicode + spaces preserved
a.send(f"/edit global {gid} hello EDITED  text")
check("author can edit (pushed to others)", any(e["text"] == "hello EDITED  text" for e in types(b.drain(), "edited")))
b.send(f"/edit global {gid} hijack")
a.drain(); c.drain()
b.send("/history global")
row = [i for e in types(b.drain(), "history") for i in e["list"] if i["id"] == gid][0]
check("non-author edit ignored; history shows edited flag", row["text"] == "hello EDITED  text" and row["edited"] is True and row["ts"] > 0)

b.send(f"/react global {gid} 👍")
check("reaction pushed", bool(types(a.drain(), "reaction")))
a.send(f"/delete global {gid}")
check("author delete pushed", bool(types(b.drain(), "deleted")))
a.send(f"/edit global {gid} zombie")
check("edit after delete rejected", not types(b.drain(), "edited"))

# text that ends in a byte the old server mistook for whitespace (0x85 ends these emoji)
for text in ["Sunrise 🌅", "Done ✅", "Meeting 📅", "Zażółć gęślą jaźń ą", "trailing emoji then space 🍅 "]:
    b.drain()
    a.send("/msg " + b.name + " " + text)
    got = [e["text"] for e in types(b.drain(), "private")]
    check(f"DM survives intact: {text!r}", got == [text.rstrip()], str(got))
a.send("Global ✅")
check("global message ending in an 0x85-byte emoji", [e["text"] for e in types(b.drain(), "chat")] == ["Global ✅"])

# a long edit ending in that emoji (this was the exact failure that killed the app's connection)
a.drain(); a.send(f"/msg {b.name} to edit"); did = a.own_id(); b.drain()
a.send(f"/edit dm {b.name} {did} Also — here's the sunrise spot from last time 🌅")
check("DM edit with unicode + trailing emoji delivered",
      [e["text"] for e in types(b.drain(), "dm_edited")] == ["Also — here's the sunrise spot from last time 🌅"])

# bare commands must never be broadcast to the room as chat text
c.drain()
for cmd in ["/edit", "/disappear", "/removemember", "/groupinfo", "/setgroupdesc", "/poststatus", "/statuses "]:
    a.send(cmd)
check("bare commands are swallowed, not broadcast", not types(c.drain(), "chat"))

# last seen: stamped on disconnect, null until then
b.close(); time.sleep(1.5)
a.send(f"/getprofile {b.name}")
pr = types(a.drain(), "profile")
check("lastSeen set after disconnect", bool(pr) and isinstance(pr[0].get("lastSeen"), int) and pr[0]["lastSeen"] > 0)
a.send(f"/getprofile {a.name}")
pr = types(a.drain(), "profile")
check("lastSeen null while never disconnected", bool(pr) and pr[0].get("lastSeen") is None)
