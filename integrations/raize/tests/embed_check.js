// Runs the mp_live_embed polling script from a served page under node with a
// fake DOM, fetch and setTimeout, and checks its browser-side rules:
//
//   1. backoff after failures stays within [interval, max(interval, 60000)]
//      and never exceeds 2^31-1 ms (setTimeout treats a larger delay as 0);
//   2. an ETag is stored only after its body was swapped in;
//   3. a removed element (isConnected false) stops polling;
//   4. the live div already holds an initial <svg>.
//
// usage: node embed_check.js page.html    prints "embed ok" and exits 0 on success
"use strict";
const fs = require("fs");

const html = fs.readFileSync(process.argv[2], "utf8");
const m = /<div class="mp-live"[^>]*>([\s\S]*?)<\/div>\n<script>\n([\s\S]*?)<\/script>/.exec(html);
if (!m) { console.log("FAIL no live embed in page"); process.exit(1); }
const initial = m[1];
const body = m[2];
let fails = 0;
function expect(name, cond) {
  if (!cond) { fails++; console.log("FAIL " + name); }
}

// One embed instance on a fake element with a scripted fetch.
function run(interval, responses, steps) {
  const el = { attrs: { "data-src": "/live.svg", "data-interval": String(interval) },
               innerHTML: "", isConnected: true,
               getAttribute(k) { return this.attrs[k]; } };
  const doc = { currentScript: { previousElementSibling: el } };
  const timers = [];
  const requests = [];
  let k = 0;
  function fakeFetch(src, opts) {
    requests.push(Object.assign({}, opts.headers));
    const r = responses[Math.min(k, responses.length - 1)];
    k++;
    if (r.reject) { return Promise.reject(new Error("net")); }
    return Promise.resolve({
      status: r.status, ok: r.status >= 200 && r.status < 300,
      headers: { get(h) { return h === "ETag" ? r.etag : null; } },
      text() { return r.textFails ? Promise.reject(new Error("body")) : Promise.resolve(r.text); },
    });
  }
  function fakeSetTimeout(fn, ms) { timers.push({ fn, ms }); }
  new Function("document", "fetch", "setTimeout", body)(doc, fakeFetch, fakeSetTimeout);
  return (async function () {
    for (let i = 0; i < steps; i++) {
      await new Promise((res) => setImmediate(res));
      await new Promise((res) => setImmediate(res));
      if (i === steps - 1) { break; }
      const t = timers[timers.length - 1];
      if (!t || t.done) { break; }
      t.done = true;
      t.fn();
    }
    return { el, timers, requests };
  })();
}

(async function () {
  // 1. backoff, for short, medium and the maximum interval
  for (const iv of [1000, 10000, 3600000]) {
    const r = await run(iv, [{ reject: true }], 25);
    const max = Math.max(...r.timers.map((t) => t.ms));
    const min = Math.min(...r.timers.map((t) => t.ms));
    expect("backoff interval " + iv + " stays <= max(interval, 60000)",
           max <= Math.max(iv, 60000));
    expect("backoff interval " + iv + " stays <= 2^31-1", max <= 2147483647);
    expect("backoff interval " + iv + " never below the interval", min >= iv);
  }
  // an attribute edited past the server's limit is clamped by the script too
  const big = await run(86400000, [{ reject: true }], 6);
  expect("oversized data-interval clamped to one hour",
         Math.max(...big.timers.map((t) => t.ms)) <= 3600000);

  // 2. ETag only after a successful swap
  const e = await run(1000, [
    { status: 200, etag: "\"g-1\"", textFails: true },
    { status: 200, etag: "\"g-2\"", text: "<svg>2</svg>" },
    { status: 304 },
  ], 4);
  expect("failed body read sends no If-None-Match next",
         e.requests[1] && !("If-None-Match" in e.requests[1]));
  expect("swapped frame", e.el.innerHTML === "<svg>2</svg>");
  expect("ETag of the swapped frame is sent",
         e.requests[2] && e.requests[2]["If-None-Match"] === "\"g-2\"");

  // 3. removed element stops polling
  const g = await run(1000, [{ status: 304 }], 1);
  g.el.isConnected = false;
  const before = g.requests.length;
  if (g.timers.length > 0) { g.timers[g.timers.length - 1].fn(); }
  await new Promise((res) => setImmediate(res));
  expect("disconnected element makes no request", g.requests.length === before);

  // 4. initial frame
  expect("live div holds an initial svg", /^<svg[\s\S]*<\/svg>\n?$/.test(initial));

  if (fails === 0) { console.log("embed ok"); process.exit(0); }
  process.exit(1);
})();
