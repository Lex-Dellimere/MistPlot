#!/usr/bin/env python3
"""End-to-end push check against a running dashboard example.

Joins "chart:live" over the channel socket with RaizeWeb's stdlib-only
WebSocket helpers (tests/integration/ws_client.py, imported from the RaizeWeb
checkout, not copied) and checks the notice + fetch contract:

  * the join reply carries {"tag": "<gen>-<seq>"};
  * a "frame" notice with a new tag arrives within 2 s and stays small;
  * GET /chart/live.svg with If-None-Match: "<notice tag>" is a 304, and with
    the join's (older) tag a 200 whose ETag is the latest notice's tag;
  * a heartbeat on the topic is answered ok, other events and an unknown
    topic are refused.

The producer pushes every 250 ms, so a request can race a new frame: the
HTTP checks take the newest notice and retry a few times.

    python3 push_check.py <port> <raize_web dir>
"""
import http.client
import json
import os
import re
import socket
import sys
import time

PORT = int(sys.argv[1])
sys.path.insert(0, os.path.join(sys.argv[2], "tests", "integration"))
import ws_client as w  # noqa: E402

w.PORT = PORT
TOPIC = "chart:live"
TAG_RE = re.compile(r"^[0-9]+-[0-9]+$")
PASSED = 0
FAILED = 0


def check(label, ok, detail=""):
    global PASSED, FAILED
    if ok:
        PASSED += 1
        print(f"PASS  {label}")
    else:
        FAILED += 1
        print(f"FAIL  {label} {detail}")


class Client:
    def __init__(self):
        self.s = socket.create_connection(("127.0.0.1", PORT), timeout=3)
        _, self.head = w.handshake(self.s, path="/socket/websocket?vsn=2.0.0")
        self.r = w.Reader(self.s)
        self.ref = 0
        self.sizes = []

    def send(self, join_ref, topic, event, payload):
        self.ref += 1
        ref = str(self.ref)
        if join_ref == "self":
            join_ref = ref
        msg = [join_ref, ref, topic, event, payload]
        self.s.sendall(w.frame(1, json.dumps(msg).encode()))
        return ref

    def next(self, timeout):
        self.s.settimeout(max(timeout, 0.01))
        op, p = self.r.frame()
        if op != 1:
            return None
        self.sizes.append(len(p))
        return json.loads(p)

    def reply_to(self, ref, timeout=2.0):
        end = time.time() + timeout
        while time.time() < end:
            m = self.next(end - time.time())
            if m and m[3] == "phx_reply" and m[1] == ref:
                return m
        return None

    def notice(self, newer_than, timeout=2.0):
        end = time.time() + timeout
        while time.time() < end:
            try:
                m = self.next(end - time.time())
            except socket.timeout:
                return None
            if m and m[2] == TOPIC and m[3] == "frame":
                tag = m[4].get("tag")
                if tag != newer_than:
                    return tag
        return None


def get(tag):
    c = http.client.HTTPConnection("127.0.0.1", PORT, timeout=3)
    c.request("GET", "/chart/live.svg", headers={"If-None-Match": f'"{tag}"'})
    r = c.getresponse()
    r.read()
    c.close()
    return r.status, r.getheader("ETag")


def main():
    cl = Client()
    check("upgrade 101", cl.head.startswith(b"HTTP/1.1 101"), cl.head[:40])
    jref = cl.send("self", TOPIC, "phx_join", {})
    rep = cl.reply_to(jref)
    ok = rep is not None and rep[4].get("status") == "ok"
    check("join accepted", ok, rep)
    join_tag = rep[4]["response"].get("tag", "") if ok else ""
    check("join reply has a tag", bool(TAG_RE.match(join_tag)), join_tag)

    t0 = time.time()
    tag = cl.notice(join_tag, 2.0)
    check("frame notice with a new tag within 2 s", tag is not None and TAG_RE.match(tag),
          f"{tag} after {time.time() - t0:.2f}s")
    if tag is None:
        return
    check("notice frames are small", max(cl.sizes) < 128, cl.sizes)

    st = None
    for _ in range(5):
        st, _ = get(tag)
        if st == 304:
            break
        tag = cl.notice(tag, 1.0) or tag
    check("If-None-Match: notice tag -> 304", st == 304, st)

    st, et = None, None
    for _ in range(5):
        tag = cl.notice(tag, 1.0) or tag
        st, et = get(join_tag)
        if st == 200 and et == f'"{tag}"':
            break
    check("If-None-Match: old tag -> 200", st == 200, st)
    check("200 ETag equals the notice tag", et == f'"{tag}"', f"{et} vs {tag}")

    href = cl.send(jref, TOPIC, "heartbeat", {})
    rep = cl.reply_to(href)
    check("heartbeat on the topic ok", rep is not None and rep[4].get("status") == "ok", rep)
    eref = cl.send(jref, TOPIC, "set_window", {"s": 1})
    rep = cl.reply_to(eref)
    check("other event refused", rep is not None and rep[4].get("status") == "error", rep)
    uref = cl.send("self", "chart:nope", "phx_join", {})
    rep = cl.reply_to(uref)
    check("unknown topic refused", rep is not None and rep[4].get("status") == "error", rep)
    cl.s.close()


if __name__ == "__main__":
    try:
        main()
    except Exception as e:  # a dead server or a protocol error is a failure
        check("no exception", False, repr(e))
    print(f"push {'ok' if FAILED == 0 else 'FAILED'}: {PASSED} passed, {FAILED} failed")
    sys.exit(1 if FAILED else 0)
