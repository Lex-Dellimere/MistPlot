#!/usr/bin/env bash
# tools/lint.sh — source rules the compiler does not enforce.
#
#   tools/lint.sh                 check the sources; prints file:line: message
#   tools/lint.sh --logs DIR...   fail on memory-analyser warnings (warning[M01..])
#                                 for MistPlot files in any *.log under DIR
#
# Source rules (src/, cmd/, integrations/, examples/):
#   1. no exported callback: `export fn <name>_cb(`
#   2. a fn-pointer parameter is named mp_<thing>_cb (files listed in
#      tools/apidoc_legacy.txt are exempt until they are rewritten)
#   3. no by-value Mp* module-scope var under examples/, cmd/, integrations/
#      (release builds miscompile some of them: keep them behind a pointer)
#   4. `import "std/thread"` in src/ only under src/sync/
# Exit 1 when anything is found.

set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || exit 2
export LC_ALL=C

# A log's diagnostics name files relative to the repo root (every build runs
# from there) or absolutely; a MistPlot file is one inside the repo.
lint_logs() {
  local found=0 path code rel f
  local logs=()
  for d in "$@"; do
    [ -e "$d" ] || continue
    while IFS= read -r f; do logs+=("$f"); done < <(find "$d" -name '*.log' -type f | sort)
  done
  [ "${#logs[@]}" -gt 0 ] || return 0
  while IFS=$'\t' read -r log path code; do
    case "$path" in
      /*) rel="$path" ;;
      *) rel="$ROOT/$path" ;;
    esac
    rel="$(realpath -m "$rel")"
    case "$rel" in
      "$ROOT"/*) echo "$log: $code in ${rel#"$ROOT"/}"; found=1 ;;
    esac
  done < <(awk '
    /^-- / { p = $2; sub(/:[0-9]+:[0-9]+$/, "", p); sub(/:[0-9]+$/, "", p); next }
    /warning\[M01[0-9]*\]/ {
      c = $0; sub(/^.*warning\[/, "", c); sub(/\].*$/, "", c)
      print FILENAME "\t" p "\t" c
    }' "${logs[@]}")
  return "$found"
}

if [ "${1:-}" = "--logs" ]; then
  shift
  lint_logs "$@"
  exit $?
fi

legacy="|"
if [ -f tools/apidoc_legacy.txt ]; then
  while IFS= read -r l; do
    l="${l%%#*}"; l="$(echo "$l" | tr -d '[:space:]')"
    [ -n "$l" ] && legacy="$legacy$l|"
  done < tools/apidoc_legacy.txt
fi

mapfile -t files < <(for d in src cmd integrations examples; do
  [ -d "$d" ] && find "$d" -name '*.mettle' -type f
done | sort)
[ "${#files[@]}" -gt 0 ] || exit 0

out="$(awk -v legacy="$legacy" '
function err(msg) { print FILENAME ":" FNR ": " msg; bad = 1 }

# Code with string literals and // comments blanked out.
function strip(s,    out, i, ch, instr) {
  out = ""; instr = 0
  for (i = 1; i <= length(s); i++) {
    ch = substr(s, i, 1)
    if (instr) {
      if (ch == "\\") { i++; out = out "  "; continue }
      if (ch == "\"") { instr = 0; out = out ch; continue }
      out = out " "
      continue
    }
    if (ch == "\"") { instr = 1; out = out ch; continue }
    if (ch == "/" && substr(s, i + 1, 1) == "/") break
    out = out ch
  }
  return out
}

# Checks the parameter list of one fn signature (rule 2).
function check_params(sig, line,    op, i, ch, depth, cur, n, P, k, p, name, type) {
  op = index(sig, "(")
  depth = 0; cur = ""; n = 0
  for (i = op; i <= length(sig); i++) {
    ch = substr(sig, i, 1)
    if (ch == "-" && substr(sig, i + 1, 1) == ">") { cur = cur "->"; i++; continue }
    if (ch == "(" || ch == "[" || ch == "<") { depth++; if (depth == 1 && ch == "(") continue }
    if (ch == ")" || ch == "]" || ch == ">") { depth--; if (depth == 0) break }
    if (ch == "," && depth == 1) { P[++n] = cur; cur = ""; continue }
    cur = cur ch
  }
  P[++n] = cur
  for (k = 1; k <= n; k++) {
    p = P[k]
    if (!match(p, /^[ \t\n]*[A-Za-z_][A-Za-z0-9_]*[ \t\n]*:/)) continue
    name = substr(p, RSTART, RLENGTH - 1); gsub(/[ \t\n]/, "", name)
    type = substr(p, RSTART + RLENGTH); sub(/^[ \t\n]+/, "", type)
    if (type ~ /^fn[ \t]*\(/ && name !~ /^mp_[A-Za-z0-9_]+_cb$/)
      print FILENAME ":" line ": fn-pointer parameter " name " must be named mp_<thing>_cb"
  }
}

function paren_balance(s,    a, b) { a = gsub(/\(/, "(", s); b = gsub(/\)/, ")", s); return a - b }

FNR == 1 {
  if (pending && !is_legacy) check_params(sig, sigline)
  pending = 0
  is_legacy = index(legacy, "|" FILENAME "|") > 0
  pubdir = (FILENAME ~ /^(examples|cmd|integrations)\//)
}

{
  code = strip($0)
  if (pending) {
    sig = sig "\n" code
    if (paren_balance(sig) <= 0) { if (!is_legacy) check_params(sig, sigline); pending = 0 }
  }
  if (code ~ /export[ \t]+fn[ \t]+[A-Za-z0-9_]*_cb[ \t]*\(/)
    err("exported callback; callbacks are private (an exported fn with a string parameter called through a pointer gets garbage in debug builds)")
  if (code ~ /^(export[ \t]+)?var[ \t]+[A-Za-z_][A-Za-z0-9_]*[ \t]*:[ \t]*Mp[A-Za-z0-9_]*[ \t]*([^*A-Za-z0-9_ \t]|$)/ && pubdir)
    err("by-value Mp* module-scope var; hold it through a pointer")
  if ($0 ~ /^[ \t]*import[ \t]+"std\/thread"/ && FILENAME ~ /^src\// && FILENAME !~ /^src\/sync\//)
    err("std/thread imported outside src/sync/")
  if (!pending && code ~ /(^|[^A-Za-z0-9_])fn[ \t]+[A-Za-z_][A-Za-z0-9_]*[ \t]*(<[^>]*>)?[ \t]*\(/ && code !~ /extern[ \t]+fn/) {
    sig = substr(code, match(code, /fn[ \t]+[A-Za-z_]/))
    sigline = FNR
    if (paren_balance(sig) <= 0) { if (!is_legacy) check_params(sig, sigline) }
    else pending = 1
  }
}

END { exit bad }
' "${files[@]}")"; rc=$?
[ -n "$out" ] && { echo "$out"; rc=1; }
exit "$rc"
