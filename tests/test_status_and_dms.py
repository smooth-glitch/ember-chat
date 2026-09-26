"""Status updates (stories), the /dms chat-list command, and upload rules."""
import os
from wsclient import Client, check, types, unique, upload

print("status updates")
a, b = Client(unique("sa")), Client(unique("sb"))
a.drain(); b.drain()
a.send("/poststatus text 3 Hello world, this is my status 🎉")
pa, pb = types(a.drain(), "status_new"), types(b.drain(), "status_new")
check("post pushed to everyone including the author", bool(pa) and bool(pb))
item = pb[0]["item"]; sid = item["id"]
check("item shape; 24h expiry; no viewer list for others",
      item["kind"] == "text" and item["bg"] == 3 and item["exp"] - item["ts"] == 86_400_000 and "views" not in item)
check("author's copy includes the viewer list", "views" in pa[0]["item"])
b.send(f"/viewstatus {sid}")
check("owner notified of a view", types(a.drain(), "status_view") == [{"type": "status_view", "id": sid, "viewer": b.name}])
b.send(f"/viewstatus {sid}")
check("repeat view not re-notified", not types(a.drain(), "status_view"))
b.send(f"/deletestatus {sid}")
check("non-owner cannot delete", not types(a.drain(), "status_deleted"))
a.send(f"/deletestatus {sid}")
check("owner delete pushed to all", bool(types(b.drain(), "status_deleted")))
a.send("/poststatus text 3 " + "x" * 800)
check("over-long status rejected", bool(types(a.drain(), "error")))

print("dm list")
p, q = Client(unique("dl")), Client(unique("dm"))
p.drain(); q.drain()
p.send(f"/msg {q.name} hi"); p.drain(); q.drain()
q.send("/dms")
lst = types(q.drain(), "dms")[0]["list"]
check("/dms lists the DM partner with a timestamp", [i["user"] for i in lst] == [p.name] and lst[0]["ts"] > 0)
r = Client(unique("dn")); r.drain(); r.send("/dms")
check("/dms is empty for a user with no DMs", types(r.drain(), "dms")[0]["list"] == [])

print("uploads")
here = os.path.dirname(os.path.abspath(__file__))
pdf = os.path.join(here, "sample.pdf")
open(pdf, "wb").write(b"%PDF-1.4\n1 0 obj<<>>endobj\ntrailer<<>>\n%%EOF\n")
check("real PDF accepted, served as application/pdf", upload(pdf, "application/pdf").get("url", "").endswith(".pdf"))
html = os.path.join(here, "fake.pdf")
open(html, "wb").write(b"<html><script>alert(1)</script></html>")
check("HTML labelled as PDF rejected (magic-byte check)", "error" in upload(html, "application/pdf"))
check("HTML as text/html rejected", "error" in upload(html, "text/html"))
os.remove(pdf); os.remove(html)
