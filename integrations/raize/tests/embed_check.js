// Runs the live-embed scripts from the served pages under node with a fake
// DOM, fetch, timers and WebSocket, and checks their browser-side rules.
//
// Both scripts (mp_live_embed's polling one and mp_live_embed_ws's channel
// one, the latter with a socket that never opens):
//   1. backoff after failures stays within [interval, max(interval, 60000)]
//      and never exceeds 2^31-1 ms (setTimeout treats a larger delay as 0);
//   2. an ETag is stored only after its body was swapped in;
//   3. a removed element (isConnected false) stops polling;
//   4. at most one poll timer is pending at a time.
// The channel script with a working socket:
//   5. it connects to ws://host/socket/websocket?vsn=2.0.0 and joins the
//      topic with a v2 frame; the heartbeat goes to "phoenix" every 30 s;
//   6. a join reply or a "frame" notice fetches only when its tag differs
//      from the shown frame's ETag, with If-None-Match; joining stops polling;
//   7. one fetch in flight: notices during a fetch give at most one more
//      fetch after it, and none when the fetched frame already has the tag;
//   8. a closed socket falls back to polling and reconnects with a backoff
//      (1 s doubling to 30 s); the rejoin stops polling again; a refused join
//      and phx_error also fall back; a stale socket's messages are ignored;
//   9. a removed element closes the socket, clears every timer and fetches
//      nothing more.
// Also: the live div already holds an initial <svg>, and the channel embed
// names its socket and topic only in data- attributes.
//
// usage: node embed_check.js page.html [fragment.html]
//   page.html holds the channel embed (dashboard /), fragment.html the
//   polling embed (dashboard /chart/live.html). Prints "embed ok" and exits
//   0 on success.
"use strict";
const fs = require("fs");

let fails = 0;
let checks = 0;
function expect(name, cond) {
  checks++;
  if (!cond) { fails++; console.log("FAIL " + name); }
}

function extract(html) {
  const m = /<div class="mp-live"([^>]*)>([\s\S]*?)<\/div>\n<script>\n([\s\S]*?)<\/script>/
    .exec(html);
  if (!m) { return null; }
  const attrs = {};
  const re = /(data-[a-z]+)="([^"]*)"/g;
  let a;
  while ((a = re.exec(m[1])) !== null) { attrs[a[1]] = a[2]; }
  return { attrs, initial: m[2], body: m[3] };
}

async function flush() {
  for (let i = 0; i < 8; i++) { await new Promise((res) => setImmediate(res)); }
}

function response(r) {
  if (r.reject) { return Promise.reject(new Error("net")); }
  return Promise.resolve({
    status: r.status, ok: r.status >= 200 && r.status < 300,
    headers: { get(h) { return h === "ETag" ? r.etag : null; } },
    text() { return r.textFails ? Promise.reject(new Error("body")) : Promise.resolve(r.text); },
  });
}

// One embed instance. cfg.fetch(i, headers) answers request i; cfg.ws is
// "fail" (every socket closes right away) or "manual" (the test drives it).
function env(emb, cfg) {
  const el = { attrs: Object.assign({}, emb.attrs), innerHTML: emb.initial, isConnected: true,
               getAttribute(k) { return k in this.attrs ? this.attrs[k] : null; } };
  if (cfg.interval !== undefined) { el.attrs["data-interval"] = String(cfg.interval); }
  const e = { el, timers: [], intervals: [], requests: [], sockets: [] };
  let nextId = 1;
  function setTimeout(fn, ms) {
    const t = { id: nextId++, fn, ms, kind: fn.name === "connect" ? "connect" : "poll",
                cancelled: false, fired: false };
    e.timers.push(t);
    return t.id;
  }
  function clearTimeout(id) { for (const t of e.timers) { if (t.id === id) { t.cancelled = true; } } }
  function setInterval(fn, ms) {
    const t = { id: nextId++, fn, ms, cancelled: false };
    e.intervals.push(t);
    return t.id;
  }
  function clearInterval(id) {
    for (const t of e.intervals) { if (t.id === id) { t.cancelled = true; } }
  }
  function fetch(src, o) {
    e.requests.push({ src, headers: Object.assign({}, o.headers), cache: o.cache });
    return cfg.fetch(e.requests.length - 1, o.headers);
  }
  class FakeWS {
    constructor(url) {
      this.url = url;
      this.sent = [];
      this.closed = false;
      e.sockets.push(this);
      if (cfg.ws === "fail") {
        Promise.resolve().then(() => {
          if (this.onerror) { this.onerror(); }
          if (this.onclose) { this.onclose(); }
        });
      }
    }
    send(t) {
      if (this.closed) { throw new Error("send on a closed socket"); }
      this.sent.push(JSON.parse(t));
    }
    close() { this.closed = true; }
    open() { this.onopen(); }
    recv(m) { this.onmessage({ data: JSON.stringify(m) }); }
    drop() { this.closed = true; this.onclose(); }
  }
  const args = {
    document: { currentScript: { previousElementSibling: el } },
    location: { href: "http://127.0.0.1:8088/dash" },
    URL, fetch, setTimeout, clearTimeout, setInterval, clearInterval, WebSocket: FakeWS,
  };
  e.active = (kind) => e.timers.filter((t) => t.kind === kind && !t.cancelled && !t.fired);
  e.fire = (t) => { t.fired = true; t.fn(); };
  e.ws = () => e.sockets[e.sockets.length - 1];
  new Function(...Object.keys(args), emb.body)(...Object.values(args));
  return e;
}

// The polling rules (1-4) for either script; `ws` is "fail" for the channel
// script so it stays on its fallback loop.
async function pollRun(emb, interval, responses, steps, ws) {
  const e = env(emb, {
    interval, ws,
    fetch: (i) => response(responses[Math.min(i, responses.length - 1)]),
  });
  e.maxActive = 0;
  for (let i = 0; i < steps; i++) {
    await flush();
    const act = e.active("poll");
    e.maxActive = Math.max(e.maxActive, act.length);
    if (i === steps - 1 || act.length === 0) { break; }
    e.fire(act[act.length - 1]);
  }
  return e;
}

async function checkPolling(label, emb, ws) {
  for (const iv of [1000, 10000, 3600000]) {
    const r = await pollRun(emb, iv, [{ reject: true }], 25, ws);
    const ms = r.timers.filter((t) => t.kind === "poll").map((t) => t.ms);
    const max = Math.max(...ms);
    const min = Math.min(...ms);
    expect(label + ": backoff interval " + iv + " polled", ms.length >= 20);
    expect(label + ": backoff interval " + iv + " stays <= max(interval, 60000)",
           max <= Math.max(iv, 60000));
    expect(label + ": backoff interval " + iv + " stays <= 2^31-1", max <= 2147483647);
    expect(label + ": backoff interval " + iv + " never below the interval", min >= iv);
    expect(label + ": one poll timer at a time (" + iv + ")", r.maxActive === 1);
  }
  const big = await pollRun(emb, 86400000, [{ reject: true }], 6, ws);
  expect(label + ": oversized data-interval clamped to one hour",
         Math.max(...big.timers.filter((t) => t.kind === "poll").map((t) => t.ms)) <= 3600000);

  const e = await pollRun(emb, 1000, [
    { status: 200, etag: "\"g-1\"", textFails: true },
    { status: 200, etag: "\"g-2\"", text: "<svg>2</svg>" },
    { status: 304 },
  ], 4, ws);
  expect(label + ": failed body read sends no If-None-Match next",
         e.requests[1] && !("If-None-Match" in e.requests[1].headers));
  expect(label + ": swapped frame", e.el.innerHTML === "<svg>2</svg>");
  expect(label + ": ETag of the swapped frame is sent",
         e.requests[2] && e.requests[2].headers["If-None-Match"] === "\"g-2\"");
  expect(label + ": no-store fetches", e.requests.every((q) => q.cache === "no-store"));

  const g = await pollRun(emb, 1000, [{ status: 304 }], 1, ws);
  g.el.isConnected = false;
  const before = g.requests.length;
  for (const t of g.active("poll")) { g.fire(t); }
  await flush();
  expect(label + ": disconnected element makes no request", g.requests.length === before);
  expect(label + ": disconnected element arms no timer", g.active("poll").length === 0);
}

// A fetch the test answers by hand.
function manualFetch() {
  const pending = [];
  const f = (i) => new Promise((resolve, reject) => { pending.push({ i, resolve, reject }); });
  f.pending = pending;
  f.answer = (r) => {
    const p = pending.shift();
    if (!p) { return false; }
    response(r).then(p.resolve, p.reject);
    return true;
  };
  return f;
}

function joinOf(ws) { return ws.sent.find((m) => m[3] === "phx_join"); }
function reply(ws, status, response) {
  const j = joinOf(ws);
  ws.recv([j[0], j[1], "chart:live", "phx_reply", { status, response }]);
}
function notice(ws, tag) { ws.recv([null, null, "chart:live", "frame", { tag }]); }

async function checkChannel(emb) {
  expect("ws: data-ws attribute", emb.attrs["data-ws"] === "/socket/websocket");
  expect("ws: data-topic attribute", emb.attrs["data-topic"] === "chart:live");
  expect("ws: socket path not in the script", emb.body.indexOf("/socket/websocket") < 0);
  expect("ws: topic not in the script", emb.body.indexOf("chart:live") < 0);

  const f = manualFetch();
  const e = env(emb, { interval: 1000, ws: "manual", fetch: f });
  // The first fetch runs at load, as the polling script's does.
  await flush();
  expect("ws: fetch at load", e.requests.length === 1);
  f.answer({ status: 200, etag: "\"g-1\"", text: "<svg>1</svg>" });
  await flush();
  expect("ws: load frame swapped", e.el.innerHTML === "<svg>1</svg>");
  expect("ws: polls until joined", e.active("poll").length === 1);

  // 5. connect and join
  expect("ws: one socket", e.sockets.length === 1);
  const ws = e.ws();
  expect("ws: socket url", ws.url === "ws://127.0.0.1:8088/socket/websocket?vsn=2.0.0");
  const abs = env({ attrs: Object.assign({}, emb.attrs, { "data-ws": "wss://example.test/s?a=1" }),
                    initial: "", body: emb.body },
                  { interval: 1000, ws: "manual", fetch: () => response({ status: 304 }) });
  expect("ws: absolute wss url kept", abs.ws().url === "wss://example.test/s?a=1&vsn=2.0.0");
  abs.el.isConnected = false;
  ws.open();
  const j = joinOf(ws);
  expect("ws: join frame", j && j[0] === j[1] && typeof j[0] === "string" &&
         j[2] === "chart:live" && JSON.stringify(j[4]) === "{}");
  expect("ws: one heartbeat interval of 30 s",
         e.intervals.length === 1 && e.intervals[0].ms === 30000);
  e.intervals[0].fn();
  const hb = ws.sent[ws.sent.length - 1];
  expect("ws: heartbeat frame", hb[0] === null && hb[2] === "phoenix" && hb[3] === "heartbeat" &&
         typeof hb[1] === "string" && hb[1] !== j[1]);
  // A heartbeat reply (another ref, topic phoenix) changes nothing.
  ws.recv([null, hb[1], "phoenix", "phx_reply", { status: "ok", response: {} }]);

  // 6. join reply with the shown tag: no fetch, polling stops
  reply(ws, "ok", { tag: "g-1" });
  await flush();
  expect("ws: same tag on join, no fetch", e.requests.length === 1);
  expect("ws: join stops polling", e.active("poll").length === 0);
  notice(ws, "g-2");
  await flush();
  expect("ws: notice fetches", e.requests.length === 2);
  expect("ws: notice fetch sends the shown ETag",
         e.requests[1].headers["If-None-Match"] === "\"g-1\"");
  f.answer({ status: 200, etag: "\"g-2\"", text: "<svg>2</svg>" });
  await flush();
  expect("ws: notice frame swapped", e.el.innerHTML === "<svg>2</svg>");
  expect("ws: no polling while joined", e.active("poll").length === 0);
  notice(ws, "g-2");
  await flush();
  expect("ws: repeated tag, no fetch", e.requests.length === 2);
  ws.recv([null, null, "chart:other", "frame", { tag: "g-9" }]);
  ws.recv([null, null, "chart:live", "other", { tag: "g-9" }]);
  await flush();
  expect("ws: other topics and events ignored", e.requests.length === 2);

  // 7. one fetch in flight
  notice(ws, "g-3");
  notice(ws, "g-4");
  notice(ws, "g-5");
  await flush();
  expect("ws: notices during a fetch wait", e.requests.length === 3);
  f.answer({ status: 200, etag: "\"g-3\"", text: "<svg>3</svg>" });
  await flush();
  expect("ws: one fetch after it", e.requests.length === 4);
  expect("ws: the follow-up sends the new ETag",
         e.requests[3].headers["If-None-Match"] === "\"g-3\"");
  f.answer({ status: 200, etag: "\"g-5\"", text: "<svg>5</svg>" });
  await flush();
  expect("ws: then idle", e.requests.length === 4 && e.el.innerHTML === "<svg>5</svg>");
  notice(ws, "g-6");
  await flush();
  notice(ws, "g-6");
  f.answer({ status: 200, etag: "\"g-6\"", text: "<svg>6</svg>" });
  await flush();
  expect("ws: no follow-up when the fetched frame has the tag", e.requests.length === 5);
  // A failed fetch while joined retries after the backoff delay.
  notice(ws, "g-7");
  await flush();
  f.answer({ reject: true });
  await flush();
  const retry = e.active("poll");
  expect("ws: failed fetch retried once", retry.length === 1 && retry[0].ms === 2000);
  e.fire(retry[0]);
  await flush();
  f.answer({ status: 200, etag: "\"g-7\"", text: "<svg>7</svg>" });
  await flush();
  expect("ws: retry swapped", e.el.innerHTML === "<svg>7</svg>" && e.requests.length === 7);
  expect("ws: joined again idle", e.active("poll").length === 0);

  // 8. fallback on close, resume on reopen
  ws.drop();
  await flush();
  expect("ws: heartbeat cleared on close", e.intervals[0].cancelled);
  const poll = e.active("poll");
  expect("ws: close resumes polling at the interval", poll.length === 1 && poll[0].ms === 1000);
  const rc = e.active("connect");
  expect("ws: reconnect after 1 s", rc.length === 1 && rc[0].ms === 1000);
  notice(ws, "g-8");
  await flush();
  expect("ws: closed socket's notice ignored", e.requests.length === 7);
  e.fire(poll[0]);
  await flush();
  expect("ws: polling fetch", e.requests.length === 8 &&
         e.requests[7].headers["If-None-Match"] === "\"g-7\"");
  f.answer({ status: 304 });
  await flush();
  expect("ws: polling continues", e.active("poll").length === 1);
  e.fire(rc[0]);
  expect("ws: reconnected", e.sockets.length === 2);
  const ws2 = e.ws();
  ws2.open();
  expect("ws: rejoined", joinOf(ws2) && joinOf(ws2)[0] !== j[0]);
  reply(ws2, "ok", { tag: "g-8" });
  await flush();
  expect("ws: rejoin stops polling", e.active("poll").length === 0);
  expect("ws: rejoin with a new tag fetches", e.requests.length === 9);
  f.answer({ status: 200, etag: "\"g-8\"", text: "<svg>8</svg>" });
  await flush();
  expect("ws: rejoin frame swapped", e.el.innerHTML === "<svg>8</svg>");
  expect("ws: joined, idle", e.active("poll").length === 0);

  // A channel error falls back the same way; so does a refused join.
  ws2.recv([joinOf(ws2)[0], joinOf(ws2)[0], "chart:live", "phx_error", {}]);
  await flush();
  expect("ws: phx_error closes the socket", ws2.closed);
  expect("ws: phx_error resumes polling", e.active("poll").length === 1);
  const rc2 = e.active("connect");
  expect("ws: reconnect after 1 s again (backoff reset by the join)",
         rc2.length === 1 && rc2[0].ms === 1000);
  e.fire(rc2[0]);
  const ws3 = e.ws();
  ws3.open();
  reply(ws3, "error", { reason: "unknown chart" });
  await flush();
  expect("ws: refused join closes the socket", ws3.closed);
  expect("ws: refused join keeps polling", e.active("poll").length === 1);
  const rc3 = e.active("connect");
  expect("ws: reconnect backs off", rc3.length === 1 && rc3[0].ms === 2000);

  // 9. removal
  e.fire(rc3[0]);
  const ws4 = e.ws();
  ws4.open();
  reply(ws4, "ok", { tag: "g-8" });
  await flush();
  const n = e.requests.length;
  e.el.isConnected = false;
  notice(ws4, "g-9");
  await flush();
  expect("ws: removed element fetches nothing", e.requests.length === n);
  expect("ws: removed element closes the socket", ws4.closed);
  expect("ws: removed element clears timers",
         e.active("poll").length === 0 && e.active("connect").length === 0 &&
         e.intervals.every((t) => t.cancelled));

  // Reconnect backoff while the socket keeps failing: 1 s doubling to 30 s.
  const fe = env(emb, { interval: 1000, ws: "fail", fetch: () => response({ status: 304 }) });
  const delays = [];
  for (let i = 0; i < 10; i++) {
    await flush();
    const c = fe.active("connect");
    if (c.length !== 1) { break; }
    delays.push(c[0].ms);
    fe.fire(c[0]);
  }
  expect("ws: reconnect delays " + delays.join(","),
         delays.join(",") === "1000,2000,4000,8000,16000,30000,30000,30000,30000,30000");
}

(async function () {
  const page = extract(fs.readFileSync(process.argv[2], "utf8"));
  if (!page) { console.log("FAIL no live embed in page"); process.exit(1); }
  expect("live div holds an initial svg", /^<svg[\s\S]*<\/svg>\n?$/.test(page.initial));
  expect("page embed is the channel one", "data-ws" in page.attrs);
  await checkPolling("ws fallback", page, "fail");
  await checkChannel(page);

  if (process.argv[3]) {
    const frag = extract(fs.readFileSync(process.argv[3], "utf8"));
    expect("fragment has a live embed", frag !== null);
    if (frag) {
      expect("fragment embed is the polling one", !("data-ws" in frag.attrs));
      expect("fragment div holds an initial svg", /^<svg[\s\S]*<\/svg>\n?$/.test(frag.initial));
      await checkPolling("poll", frag, "fail");
    }
  }

  if (fails === 0) { console.log("embed ok (" + checks + " checks)"); process.exit(0); }
  process.exit(1);
})().catch(function (err) {
  console.log("FAIL exception: " + (err && err.stack ? err.stack : err));
  process.exit(1);
});
