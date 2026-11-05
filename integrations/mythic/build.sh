#!/usr/bin/env bash
# Builds the MythicUI integration's test and example in debug and release, runs
# the test headless in both modes and checks that both wrote identical PNGs.
# Prints PASS or FAIL.
#
# Env: METTLE (compiler, default ../Mettle/bin/mettle next to this repo).

set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT" || exit 1
METTLE="${METTLE:-$ROOT/../Mettle/bin/mettle}"
OUT="build/integrations/mythic"
mkdir -p "$OUT"

# MythicUI's GL path (Glint) dlopens libEGL / libGL, so Linux builds bind libc.
LIBS=()
[ "$(uname -s)" = Linux ] && LIBS=(-lc)

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
  rm -f "$OUT/mythic_test.$mode" "$OUT/live_dashboard.$mode"   # a failed build must not leave an old binary to run
  step "build-test-$mode" "$METTLE" $flag "${LIBS[@]}" --build \
    integrations/mythic/tests/mythic_test.mettle -o "$OUT/mythic_test.$mode"
  step "build-example-$mode" "$METTLE" $flag "${LIBS[@]}" --build \
    integrations/mythic/examples/live_dashboard.mettle -o "$OUT/live_dashboard.$mode"
done

# Both test runs write the same test_*.png names, so the release images are
# renamed before the debug run.
if [ -x "$OUT/mythic_test.release" ]; then
  step "run-test-release" timeout 120 "$OUT/mythic_test.release"
  echo "      $(tail -n 1 "$OUT/run-test-release.log")"
  for f in "$OUT"/test_*.png; do
    case "$f" in *_release.png) continue ;; esac
    [ -e "$f" ] && mv -f "$f" "${f%.png}_release.png"
  done
fi
if [ -x "$OUT/mythic_test.debug" ]; then
  step "run-test-debug" timeout 120 "$OUT/mythic_test.debug"
  echo "      $(tail -n 1 "$OUT/run-test-debug.log")"
fi

# Debug and release must paint the same pixels.
compare_pngs() {
  local rc=0 f d
  for f in "$OUT"/test_*_release.png; do
    [ -e "$f" ] || continue
    d="${f%_release.png}.png"
    if [ -e "$d" ] && ! cmp -s "$f" "$d"; then echo "differ: $d"; rc=1; fi
  done
  return $rc
}
step "compare-pngs" compare_pngs

if [ "$fails" = 0 ]; then
  echo "PASS"
  exit 0
fi
echo "FAIL ($fails step(s))"
exit 1
