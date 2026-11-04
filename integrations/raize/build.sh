#!/usr/bin/env bash
# Builds the RaizeWeb integration's test and example in debug and release, runs
# the test in both modes, smoke-tests the example server with curl, checks
# channel push end to end with python (RaizeWeb's ws_client.py, imported from
# ../raize_web) and checks both embed scripts with node. Prints PASS or FAIL.
#
# Needs ../raize_web next to this repo (mettle.deps maps raize=../raize_web).
# Env: METTLE (compiler, default ../Mettle/bin/mettle next to this repo),
#      SMOKE_PORT (default derived from the process id; the push check uses SMOKE_PORT + 1).

set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT" || exit 1
METTLE="${METTLE:-$ROOT/../Mettle/bin/mettle}"
OUT="build/integrations/raize"
SMOKE_PORT="${SMOKE_PORT:-$((20000 + $$ % 20000))}"   # per process, so parallel runs differ
mkdir -p "$OUT"

if [ ! -d ../raize_web/framework ]; then
  echo "FAIL  ../raize_web not found"
  echo "FAIL"
  exit 1
fi

fails=0
step() { # name, command...
  local name="$1"; shift
  if "$@" > "$OUT/$name.log" 2>&1; then
    echo "ok    $name"
  else
    echo "FAIL  $name (see $OUT/$name.log)"
    tail -n 5 "$OUT/$name.log" | sed 's/^/      /'
    fails=$((fails + 1))
  fi
}

for mode in debug release; do
  flag=""
  [ "$mode" = release ] && flag="--release"
  rm -f "$OUT/raize_test.$mode" "$OUT/dashboard.$mode"   # a failed build must not leave an old binary to run
  step "build-test-$mode" "$METTLE" $flag --build \
    integrations/raize/tests/raize_test.mettle -o "$OUT/raize_test.$mode"
  step "build-example-$mode" "$METTLE" $flag --build \
    integrations/raize/examples/dashboard.mettle -o "$OUT/dashboard.$mode"
  if [ -x "$OUT/raize_test.$mode" ]; then
    step "run-test-$mode" "$OUT/raize_test.$mode"
    echo "      $(tail -n 1 "$OUT/run-test-$mode.log")"
  fi
done

# Starts the release dashboard with --run-for (it stops itself), probes the
# routes and the 304 path, then waits for a clean exit.
smoke() {
  local bin="$OUT/dashboard.release" base="http://127.0.0.1:$SMOKE_PORT"
  [ -x "$bin" ] || return 1
  "$bin" --port "$SMOKE_PORT" --run-for 4 > "$OUT/smoke-server.log" 2>&1 &
  local pid=$!
  local up=0
  for _ in $(seq 1 30); do
    if curl -s -o /dev/null "$base/chart/static.svg"; then up=1; break; fi
    sleep 0.1
  done
  [ "$up" = 1 ] || { kill "$pid" 2>/dev/null; wait "$pid"; return 1; }
  local ok=0
  code() { curl -s -o /dev/null -w '%{http_code}' "$@"; }
  [ "$(code "$base/")" = 200 ] || ok=1
  curl -s -o "$OUT/page.html" "$base/" || ok=1
  curl -s -o "$OUT/fragment.html" "$base/chart/live.html" || ok=1
  [ "$(code "$base/chart/static.svg")" = 200 ] || ok=1
  local etag
  etag="$(curl -s -D - -o /dev/null "$base/chart/live.svg" | tr -d '\r' |
    awk 'tolower($1)=="etag:"{print $2}')"
  [ -n "$etag" ] || ok=1
  # The producer pushes every 250 ms, so either 304 or a newer 200 is correct.
  local c; c="$(code -H "If-None-Match: $etag" "$base/chart/live.svg")"
  [ "$c" = 304 ] || [ "$c" = 200 ] || ok=1
  [ "$(code -H 'If-None-Match: "0"' "$base/chart/live.svg")" = 200 ] || ok=1
  wait "$pid"; local rc=$?
  [ "$rc" = 0 ] || ok=1
  return $ok
}
if command -v curl > /dev/null; then
  step "smoke-example-release" smoke
else
  echo "skip  smoke-example-release (no curl)"
fi

# A second dashboard for the channel check, so its timing does not depend on
# the smoke run.
push() {
  local bin="$OUT/dashboard.release" port=$((SMOKE_PORT + 1))
  [ -x "$bin" ] || return 1
  "$bin" --port "$port" --run-for 6 > "$OUT/push-server.log" 2>&1 &
  local pid=$!
  local up=0
  for _ in $(seq 1 30); do
    if curl -s -o /dev/null "http://127.0.0.1:$port/chart/static.svg"; then up=1; break; fi
    sleep 0.1
  done
  [ "$up" = 1 ] || { kill "$pid" 2>/dev/null; wait "$pid"; return 1; }
  local ok=0
  python3 integrations/raize/tests/push_check.py "$port" ../raize_web || ok=1
  wait "$pid" || ok=1
  return $ok
}
if command -v python3 > /dev/null && command -v curl > /dev/null &&
   [ -f ../raize_web/tests/integration/ws_client.py ]; then
  step "push-example-release" push
  grep -E '^(PASS|FAIL)  |^push ' "$OUT/push-example-release.log" | sed 's/^/      /'
else
  echo "skip  push-example-release (no python3, curl or ws_client.py)"
fi

if command -v node > /dev/null && [ -s "$OUT/page.html" ]; then
  step "node-embed-check" node integrations/raize/tests/embed_check.js "$OUT/page.html" \
    "$OUT/fragment.html"
  echo "      $(tail -n 1 "$OUT/node-embed-check.log")"
else
  echo "skip  node-embed-check (no node or no page)"
fi

if [ "$fails" = 0 ]; then
  echo "PASS"
  exit 0
fi
echo "FAIL ($fails step(s))"
exit 1
