#!/usr/bin/env bash
# tools/golden.sh — builds cmd/golden in debug and release and byte-compares
# every file in tests/golden/ with the output of the fixture named by its stem
# (tests/golden/line.svg is `golden line`).
#
#   tools/golden.sh            compare; one ok/FAIL line per fixture and mode
#   tools/golden.sh --update   rewrite every golden from the debug build, then
#                              compare; look at the new charts before committing
#
# Env: METTLE (compiler, default ../Mettle/bin/mettle next to this repo).
# Builds and logs go to build/golden/. Exit 1 when a build fails or any output
# differs.

set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || exit 2
METTLE="${METTLE:-$ROOT/../Mettle/bin/mettle}"
OUT="build/golden"
mkdir -p "$OUT"

update=0
[ "${1:-}" = "--update" ] && update=1

fails=0
for mode in debug release; do
  flag=""
  [ "$mode" = release ] && flag="--release"
  bin="$OUT/golden.$mode"
  rm -f "$bin"   # a failed build must not leave the last binary to run
  if ! "$METTLE" $flag --build cmd/golden/main.mettle -o "$bin" > "$OUT/build-$mode.log" 2>&1; then
    echo "FAIL  build-$mode (see $OUT/build-$mode.log)"
    tail -n 8 "$OUT/build-$mode.log" | sed 's/^/      /'
    fails=$((fails + 1))
  fi
done

shopt -s nullglob
goldens=(tests/golden/*)
[ "${#goldens[@]}" -gt 0 ] || { echo "FAIL  no files in tests/golden/"; exit 1; }

if [ "$update" = 1 ]; then
  [ -x "$OUT/golden.debug" ] || exit 1
  for g in "${goldens[@]}"; do
    name="$(basename "$g")"; name="${name%.*}"
    if "$OUT/golden.debug" "$name" > "$g.tmp"; then
      mv "$g.tmp" "$g"; echo "wrote $g"
    else
      rm -f "$g.tmp"; echo "FAIL  golden $name (debug) exited non-zero"; fails=$((fails + 1))
    fi
  done
fi

for g in "${goldens[@]}"; do
  name="$(basename "$g")"; name="${name%.*}"
  for mode in debug release; do
    bin="$OUT/golden.$mode"
    [ -x "$bin" ] || continue
    if "$bin" "$name" > "$OUT/$name.$mode.out" 2> "$OUT/$name.$mode.err" &&
       cmp -s "$OUT/$name.$mode.out" "$g"; then
      echo "ok    $name-$mode"
    else
      echo "FAIL  $name-$mode (diff $OUT/$name.$mode.out $g)"
      fails=$((fails + 1))
    fi
  done
done

[ "$fails" = 0 ]
