"""Fills a scratch server with a believable demo: profiles, an active Everyone room, DMs, groups,
status updates. Usage (server on EMBER_PORT, default 8099, ideally freshly started):

    python3 seed.py phase1        # profiles, Everyone conversation, status updates; then waits
    touch go2                     # once the app has logged in as "alex", start phase 2
    echo 'maya|/msg alex hi 👋' > cmds.txt      # optional: send a live message on cue

Phase 2 sends DMs and creates groups *after* the app is connected so they arrive live (unread badges).
The script stays running to keep the demo users online; Ctrl-C to stop.
"""
import os, sys, time
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "tests"))
from wsclient import Client, BASE, upload as _upload

ASSETS = os.environ.get("ASSETS", os.path.join(os.path.dirname(os.path.abspath(__file__)), "assets"))


def up(name, mime="image/jpeg", filename=None):
    return BASE + _upload(os.path.join(ASSETS, name), mime, filename)["url"]


def say(c, text, pause=0.35):
    c.send(text)
    mid = c.own_id(0.6)
    time.sleep(pause)
    return mid


users = {}
for name, avatar in [("maya", "av5"), ("omar", "av12"), ("priya", "av47"), ("jonas", "av15"), ("sofia", "av32")]:
    users[name] = Client(name)
    users[name].drain(.3)
    users[name].send("/setavatar " + up(avatar + ".jpg"))
    users[name].drain(.3)
for n, s in {"maya": "At the beach 🌊", "omar": "Available", "priya": "Hiking > everything",
             "jonas": "In a meeting", "sofia": "Battery about to die 🔋"}.items():
    users[n].send("/setstatus " + s)
    users[n].drain(.3)

# "alex" is the account the app logs in as: give it a profile + status, then free the name
alex = Client("alex")
alex.drain()
alex.send("/setavatar " + up("av68.jpg"))
alex.send("/setstatus Building something fun 🔥")
alex.send("/poststatus text 0 Building something fun 🔥 Ember is coming together!")
alex.drain(.5)
alex.close()
time.sleep(1)

m, o, p, j, s = (users[k] for k in ("maya", "omar", "priya", "jonas", "sofia"))
say(m, "Morning everyone ☀️ anyone up for a hike this weekend?")
say(o, "Count me in! Weather looks perfect for Saturday")
photo = say(p, up("photo_mountain.jpg"))
say(p, "Found this trail — 8km loop with insane views 🏔️")
say(j, "That looks unreal 😍")
gif = say(s, "https://media.giphy.com/media/ICOgUNjpvO0PC/giphy.gif")
say(o, f"/reply {photo} Sold. Meet at 8am?")
say(m, "🎉")
link = say(j, "Trail guide if anyone wants it: https://www.nps.gov/yose/index.htm")
time.sleep(5)                                    # let the link preview arrive
for who, emoji, mid in [(m, "❤️", photo), (j, "🔥", photo), (o, "😂", gif), (p, "👍", link)]:
    who.send(f"/react global {mid} {emoji}")
    time.sleep(.2)
for who, style, text in [(m, 1, "Beach day! 🏖️ Who's coming Saturday?"), (m, 4, "Working from a cafe today ☕"),
                         (o, 2, "New job starts Monday!!"), (p, 3, "Trail report: 12km, 0 regrets"),
                         (s, 3, "Sunday reset ☕📚"), (j, 5, "Golden hour never gets old")]:
    who.send(f"/poststatus text {style} {text}")
    time.sleep(.3)
p.send("/poststatus image " + up("photo_forest.jpg"))
print("phase1 done; log the app in as alex, then `touch go2`", flush=True)

while not os.path.exists("go2"):
    time.sleep(.3)
d1 = say(m, "/msg alex Hey Alex! Did you see the trail photos Priya posted?")
say(m, "/msg alex " + up("photo_lake.jpg"))
d3 = say(m, "/msg alex Also here is the sunrise spot from last time")
m.send(f"/edit dm alex {d3} Also — here's the sunrise spot from last time 🌅")
m.drain(.4)
say(m, f"/replydm alex {d1} Let me know if Saturday works for you")
say(m, "/msg alex " + up("doc.pdf", "application/pdf") + "?name=Trip%20itinerary.pdf")
say(o, "/msg alex Bring the good camera 📸")
say(s, "/msg alex See you Saturday!")
say(j, "/msg alex Quick question about the deploy when you have a minute")
j.close()                                         # jonas goes offline -> "last seen" on his DM

p.send("/creategroup hike-crew"); p.drain(.4)
for u in ("alex", "maya", "omar"):
    p.send("/addmember hike-crew " + u); p.drain(.4)
p.send("/setgroupdesc hike-crew Saturday hike planning: trail, carpool and snacks"); p.drain(.3)
p.send("/setgroupicon hike-crew " + up("icon_trip.jpg")); p.drain(.3)
p.send("/disappear group hike-crew 86400"); p.drain(.3)
say(p, "/groupmsg hike-crew Carpool leaves my place at 7:30 🚗")
say(o, "/groupmsg hike-crew I can bring snacks 🥪")
say(m, "/groupmsg hike-crew Bringing the speaker 🎶")

m.send("/creategroup movie-night"); m.drain(.4)
for u in ("alex", "omar", "priya"):
    m.send("/addmember movie-night " + u); m.drain(.4)
m.send("/setgroupdesc movie-night Friday movie night crew - vote on the film here"); m.drain(.3)
m.send("/setgroupicon movie-night " + up("icon_movie.jpg")); m.drain(.3)
say(m, "/groupmsg movie-night Who's up for a movie Friday?")
say(o, "/groupmsg movie-night I vote for the sci-fi one")
say(p, "/groupmsg movie-night I'll bring popcorn 🍿")
print("phase2 done; holding connections (Ctrl-C to stop)", flush=True)

online = {k: users[k] for k in ("maya", "omar", "priya", "sofia")}
while True:                                       # stay online; run "user|text" lines from cmds.txt on cue
    for c in online.values():
        try: c.drain(.4)
        except Exception: pass
    if os.path.exists("cmds.txt"):
        lines = open("cmds.txt").read().splitlines(); os.remove("cmds.txt")
        for line in lines:
            user, text = line.split("|", 1)
            online[user].send(text)
            time.sleep(.5)
