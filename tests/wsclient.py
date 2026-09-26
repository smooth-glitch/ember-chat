"""Minimal WebSocket test client for the Ember protocol (stdlib only).

The server speaks a plain-text command protocol over WebSocket: the first text
frame is the username, every later frame is a command or chat text, and the
server answers with JSON events. See docs/PROTOCOL.md.
"""
import base64, json, os, socket, struct, sys, time

HOST = os.environ.get("EMBER_HOST", "localhost")
PORT = int(os.environ.get("EMBER_PORT", "8099"))
BASE = f"http://{HOST}:{PORT}"

_results = {"pass": 0, "fail": 0}


def check(name, condition, detail=""):
    """Record a PASS/FAIL line; `python run_all.py` exits non-zero if any fail."""
    _results["pass" if condition else "fail"] += 1
    print(("  PASS  " if condition else "  FAIL  ") + name + (f"   [{detail}]" if detail and not condition else ""))
    return condition


def summary():
    print(f"\n{_results['pass']} passed, {_results['fail']} failed")
    return 1 if _results["fail"] else 0


def types(events, *wanted):
    return [e for e in events if e.get("type") in wanted]


class Client:
    def __init__(self, name):
        self.name = name
        self.sock = socket.create_connection((HOST, PORT), timeout=10)
        key = base64.b64encode(os.urandom(16)).decode()
        self.sock.send((
            f"GET / HTTP/1.1\r\nHost: {HOST}:{PORT}\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
            f"Sec-WebSocket-Key: {key}\r\nSec-WebSocket-Version: 13\r\n\r\n").encode())
        self.sock.recv(4096)                 # 101 Switching Protocols (may carry the first frame too)
        self.buf = b""
        self.send(name)
        time.sleep(0.4)

    def send(self, text):
        data = text.encode()
        mask = os.urandom(4)
        n = len(data)
        head = bytes([0x81, 0x80 | n]) if n < 126 else bytes([0x81, 0x80 | 126]) + struct.pack(">H", n)
        self.sock.send(head + mask + bytes(b ^ mask[i % 4] for i, b in enumerate(data)))

    def _read(self, n):
        while len(self.buf) < n:
            chunk = self.sock.recv(65536)
            if not chunk:
                raise ConnectionError("closed")
            self.buf += chunk
        out, self.buf = self.buf[:n], self.buf[n:]
        return out

    def drain(self, wait=0.8):
        """Collect JSON events until the socket has been quiet for `wait` seconds."""
        events = []
        self.sock.settimeout(wait)
        try:
            while True:
                head = self._read(2)
                length = head[1] & 0x7F
                if length == 126:
                    length = struct.unpack(">H", self._read(2))[0]
                elif length == 127:
                    length = struct.unpack(">Q", self._read(8))[0]
                payload = self._read(length)
                if head[0] & 0x0F == 1:
                    events.append(json.loads(payload.decode("utf-8")))   # invalid UTF-8 would raise here
        except (socket.timeout, ConnectionError):
            pass
        return events

    def own_id(self, wait=1.0):
        """The id the server assigned to the message this client just sent."""
        for e in self.drain(wait):
            if e.get("type") in ("own_message_id", "dm_ack", "group_msg_ack"):
                return e["id"]

    def close(self):
        self.sock.close()


def upload(path, mime, filename=None):
    """POST a file to /upload with curl; returns the parsed JSON reply."""
    import subprocess
    spec = f"file=@{path};type={mime}" + (f";filename={filename}" if filename else "")
    out = subprocess.run(["curl", "-s", "-F", spec, BASE + "/upload"], capture_output=True, text=True).stdout
    return json.loads(out)


def unique(prefix):
    """A username that won't collide with another test run."""
    return f"{prefix}{os.getpid() % 10000}{int(time.time()) % 1000}"
