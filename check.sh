#!/usr/bin/env bash
# check.sh — the whole MistPlot gate in one command:
#   1. tools/lint.sh, tools/apidoc.sh --selftest and --check (doc rules, and
#      docs/API.md matches the sources)
#   2. `mbuild test` (every src/**/*_test.mettle in the compile-time interpreter)
#   3. every unit test built and run natively in debug and release
#      (release builds have miscompiles, so both run)
#   4. tools/golden.sh: cmd/golden in debug and release, byte-compared with
#      every file in tests/golden/
#   5. the raize, mythic and meodb integration builds (each skipped when
#      ../raize_web, ../mythic_ui or the MeoDB checkout is missing;
#      MEODB_DIR picks the checkout, default ../meodb)
#   6. no memory-analyser warning (warning[M01..]) for a MistPlot file in any
#      build log of this run
#
#   ./check.sh                  # from anywhere; cds to the repo root
#   METTLE=/path/to/mettle ./check.sh
#   MBUILD=/path/to/mbuild ./check.sh
#
# METTLE defaults to the dev compiler next to this repo. It is exported, so
# mbuild uses it too instead of the newest installed release (an older
# release lacks std/conv's str_count and fails the web and integration tests).
# Prints PASS and exits 0 only when every step passed.

set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT" || exit 2
export METTLE="${METTLE:-$ROOT/../Mettle/bin/mettle}"
MBUILD="${MBUILD:-$(command -v mbuild || echo "$ROOT/../mbuild/build/linux/release/mbuild")}"
OUT="build/check"
mkdir -p "$OUT"
# Runs share build/ and the integration ports, so a second run waits for the first.
exec 9> build/.check.lock
flock 9

fails=0
step() { # name, command...
  local name="$1"; shift
  if "$@" > "$OUT/$name.log" 2>&1; then
    echo "ok    $name"
  else
    echo "FAIL  $name (see $OUT/$name.log)"
    tail -n 8 "$OUT/$name.log" | sed 's/^/      /'
    fails=$((fails + 1))
  fi
}

if [ ! -x "$METTLE" ]; then
  echo "FAIL  no compiler at $METTLE (set METTLE)"
  exit 1
fi

# Logs of earlier runs (or of a skipped integration) must not reach the
# memory-warning scan at the end.
rm -f "$OUT"/*.log build/golden/*.log build/integrations/*/*.log

step lint tools/lint.sh
step apidoc-selftest tools/apidoc.sh --selftest
step apidoc tools/apidoc.sh --check

step mbuild-test "$MBUILD" test

for src in $(find src -name '*_test.mettle' | sort); do
  # src/backends/web/live_test.mettle -> backends_web_live_test (two files
  # share the basename live_test).
  name="$(echo "${src#src/}" | sed 's/\.mettle$//; s#/#_#g')"
  for mode in debug release; do
    flag=""
    [ "$mode" = release ] && flag="--release"
    bin="$OUT/$name.$mode"
    rm -f "$bin"   # a failed build must not leave last run's binary to run
    step "build-$name-$mode" "$METTLE" $flag --build "$src" -o "$bin"
    [ -x "$bin" ] && step "run-$name-$mode" "$bin"
  done
done

step golden tools/golden.sh

if [ -d ../raize_web/libs/core ]; then
  step integration-raize integrations/raize/build.sh
else
  echo "skip  integration-raize (no ../raize_web)"
fi
if [ -d ../mythic_ui/src ]; then
  step integration-mythic integrations/mythic/build.sh
else
  echo "skip  integration-mythic (no ../mythic_ui)"
fi

MEODB_DIR="${MEODB_DIR:-$ROOT/../meodb}"
if [ -f "$MEODB_DIR/src/feed/feed.mettle" ]; then
  step integration-meodb env MEODB_DIR="$MEODB_DIR" integrations/meodb/build.sh
else
  echo "skip  integration-meodb (no change feed in $MEODB_DIR)"
fi

step memory-warnings tools/lint.sh --logs "$OUT" build/golden build/integrations

if [ "$fails" = 0 ]; then
  echo "PASS"
  exit 0
fi
echo "FAIL ($fails step(s))"
exit 1
