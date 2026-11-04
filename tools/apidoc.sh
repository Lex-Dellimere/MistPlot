#!/usr/bin/env bash
# tools/apidoc.sh — builds docs/API.md from the //! and /// doc comments, and
# checks them.
#
#   tools/apidoc.sh              regenerate docs/API.md
#   tools/apidoc.sh --check      print file:line: message for every export that
#                                breaks the doc rules, then fail if docs/API.md
#                                is stale; exit 1 on any finding
#   tools/apidoc.sh --selftest   run the generator and the checker on
#                                tools/testdata/apidoc and compare with the
#                                expected output there
#
# Inputs: src/**/*.mettle (not *_test.mettle) and integrations/*/mp_*.mettle,
# in LC_ALL=C order. Files listed in an optional tools/apidoc_legacy.txt (absent:
# none) still appear in the reference (their plain // comments stand in for docs)
# but are exempt from the rules. Options for tests: --root DIR (tree to read),
# --legacy FILE, --out FILE.

set -u
TOOLS="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$TOOLS/.." && pwd)"
export LC_ALL=C

root="$REPO"
legacy=""
out=""
mode=gen
while [ $# -gt 0 ]; do
  case "$1" in
    --check) mode=check ;;
    --selftest) mode=selftest ;;
    --root) root="$(cd "$2" && pwd)"; shift ;;
    --legacy) legacy="$2"; shift ;;
    --out) out="$2"; shift ;;
    -h|--help) sed -n '2,19p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "apidoc: unknown argument $1" >&2; exit 2 ;;
  esac
  shift
done

read -r -d '' AWK_PROG <<'AWK'
# One state machine over every input file. Collects module docs and exported
# items, then (at END) prints either the markdown reference (mode=gen) or the
# rule findings (mode=check).

function trim(s) { sub(/^[ \t\r\n]+/, "", s); sub(/[ \t\r\n]+$/, "", s); return s }
function squash(s) { gsub(/[ \t\r\n]+/, " ", s); return trim(s) }
function cell(s) { gsub(/\|/, "\\|", s); return s }
function err(file, line, msg) { nerr++; errs[nerr] = file ":" line ": " msg }

# Position of the first character c at bracket depth 0, outside string and
# char literals and // comments; 0 if none. With c == "}" it is the brace that
# closes the first "{".
function scan(s, c,    i, n, ch, instr, depth, nx) {
  n = length(s); instr = 0; depth = 0
  for (i = 1; i <= n; i++) {
    ch = substr(s, i, 1)
    if (instr) {
      if (ch == "\\") { i++; continue }
      if (ch == "\"") instr = 0
      continue
    }
    if (ch == "\"") { instr = 1; continue }
    if (ch == "'") { if (substr(s, i + 1, 1) == "\\") i += 3; else i += 2; continue }
    if (ch == "/" && substr(s, i + 1, 1) == "/") {
      nx = index(substr(s, i), "\n")
      if (nx == 0) return 0
      i += nx - 1
      continue
    }
    if (c == "}") {
      if (ch == "{") depth++
      else if (ch == "}") { depth--; if (depth == 0) return i }
      continue
    }
    if (ch == c && depth == 0) return i
    if (ch == "(" || ch == "[" || ch == "{") depth++
    else if (ch == ")" || ch == "]" || ch == "}") depth--
  }
  return 0
}

# Splits a parameter list at depth-0 commas (parentheses, brackets and angle
# brackets nest; "->" is not a bracket). Fills P_name[], P_type[]; returns n.
function split_params(s,    i, n, ch, depth, cur, k, p) {
  n = 0; depth = 0; cur = ""
  s = trim(s)
  if (s == "") return 0
  for (i = 1; i <= length(s); i++) {
    ch = substr(s, i, 1)
    if (ch == "-" && substr(s, i + 1, 1) == ">") { cur = cur "->"; i++; continue }
    if (ch == "(" || ch == "[" || ch == "<") depth++
    else if (ch == ")" || ch == "]" || ch == ">") depth--
    if (ch == "," && depth == 0) { P_raw[++n] = cur; cur = ""; continue }
    cur = cur ch
  }
  P_raw[++n] = cur
  for (k = 1; k <= n; k++) {
    p = trim(P_raw[k])
    if (match(p, /^[A-Za-z_][A-Za-z0-9_]*[ \t]*:/)) {
      P_name[k] = trim(substr(p, 1, RLENGTH - 1))
      P_type[k] = trim(substr(p, RLENGTH + 1))
    } else {
      P_name[k] = p; P_type[k] = ""
    }
  }
  return n
}

# Parses one doc block (lines joined by "\n", comment markers already gone).
function parse_doc(d,    nl, L, i, l, intag, tag, para, np, k) {
  D_summary = ""; D_body = ""; D_ret = ""; D_hasret = 0; D_nerr = 0
  D_mem = ""; D_thread = ""; D_cost = ""; D_internal = 0; D_np = 0; D_nbad = 0
  delete D_pn; delete D_pt; delete D_err; delete D_bad
  np = 0; para = ""; intag = 0
  nl = split(d, L, "\n")
  for (i = 1; i <= nl; i++) {
    l = L[i]
    if (match(l, /^@[A-Za-z]+/)) {
      tag = substr(l, 2, RLENGTH - 1)
      add_tag(tag, trim(substr(l, RLENGTH + 1)))
      intag = 1
      continue
    }
    if (trim(l) == "") {
      intag = 0
      if (para != "") { P[++np] = para; para = "" }
      continue
    }
    if (intag) { append_tag(trim(l)); continue }
    para = (para == "") ? trim(l) : para " " trim(l)
  }
  if (para != "") P[++np] = para
  if (np >= 1) D_summary = P[1]
  for (k = 2; k <= np; k++) D_body = (D_body == "") ? P[k] : D_body "\n\n" P[k]
}

function add_tag(tag, text,    sp) {
  last_tag = tag
  if (tag == "param") {
    D_np++
    sp = index(text, " ")
    if (sp == 0) { D_pn[D_np] = text; D_pt[D_np] = "" }
    else { D_pn[D_np] = substr(text, 1, sp - 1); D_pt[D_np] = trim(substr(text, sp + 1)) }
  } else if (tag == "return") { D_hasret = 1; D_ret = text }
  else if (tag == "error") { D_err[++D_nerr] = text }
  else if (tag == "mem") D_mem = text
  else if (tag == "thread") D_thread = text
  else if (tag == "cost") D_cost = text
  else if (tag == "internal") D_internal = 1
  else D_bad[++D_nbad] = tag
}

function append_tag(text) {
  if (last_tag == "param") D_pt[D_np] = trim(D_pt[D_np] " " text)
  else if (last_tag == "return") D_ret = trim(D_ret " " text)
  else if (last_tag == "error") D_err[D_nerr] = trim(D_err[D_nerr] " " text)
  else if (last_tag == "mem") D_mem = trim(D_mem " " text)
  else if (last_tag == "thread") D_thread = trim(D_thread " " text)
  else if (last_tag == "cost") D_cost = trim(D_cost " " text)
}

function start_file() {
  if (cur_kind != "") err(it_file[nit], it_line[nit], "unterminated export")
  cur_kind = ""
  if (nmod > 0) finish_module()
  nmod++
  mod_path[nmod] = FILENAME
  mod_legacy[nmod] = index(legacy, "|" FILENAME "|") > 0
  mod_doc[nmod] = ""; mod_internal[nmod] = 0; mod_hasdoc[nmod] = 0
  in_moddoc = 0; moddoc_done = 0; header = 1; hdr = ""
  ndoc = 0; doc = ""; ldoc = ""
}

function begin_item(line,    rest) {
  rest = line
  sub(/^(@[A-Za-z_]+(\([^)]*\))?[ \t]+)*export[ \t]+/, "", rest)
  nit++
  it_mod[nit] = nmod; it_file[nit] = FILENAME; it_line[nit] = FNR
  it_doc[nit] = (ndoc > 0) ? doc : ""
  it_hasdoc[nit] = (ndoc > 0)
  it_ldoc[nit] = (ndoc == 0) ? ldoc : ""
  it_extern[nit] = 0
  if (rest ~ /^extern[ \t]+fn[ \t]/) { cur_kind = "fn"; term = ";"; it_extern[nit] = 1 }
  else if (rest ~ /^extern[ \t]+var[ \t]/) { cur_kind = "var"; term = ";"; it_extern[nit] = 1 }
  else if (rest ~ /^fn[ \t]/) { cur_kind = "fn"; term = "{" }
  else if (rest ~ /^const[ \t]/) { cur_kind = "const"; term = ";" }
  else if (rest ~ /^var[ \t]/) { cur_kind = "var"; term = ";" }
  else if (rest ~ /^struct[ \t]/) { cur_kind = "struct"; term = "}" }
  else if (rest ~ /^enum[ \t]/) { cur_kind = "enum"; term = "}" }
  else { cur_kind = "other"; term = (index(rest, "{") > 0) ? "}" : ";" }
  it_kind[nit] = cur_kind
  acc = rest
  ndoc = 0; doc = ""; ldoc = ""
  try_finish()
}

function try_finish(    p, text, tail) {
  p = scan(acc, term)
  if (p == 0) return
  if (term == "}") text = substr(acc, 1, p)
  else text = substr(acc, 1, p - 1)
  tail = substr(acc, p + 1)
  it_text[nit] = text
  it_tail[nit] = ""
  if (match(tail, /\/\/\/?/)) it_tail[nit] = trim(substr(tail, RSTART + RLENGTH))
  cur_kind = ""
}

FNR == 1 { start_file() }

{
  line = $0
  sub(/\r$/, "", line)
  if (cur_kind != "") { acc = acc "\n" line; try_finish(); next }
  if (line ~ /^[ \t]*\/\/!/) {
    if (!moddoc_done) {
      t = line; sub(/^[ \t]*\/\/! ?/, "", t)
      if (trim(t) == "@internal") mod_internal[nmod] = 1
      else mod_doc[nmod] = mod_doc[nmod] t "\n"
      mod_hasdoc[nmod] = 1; in_moddoc = 1
    }
    header = 0
    next
  }
  if (in_moddoc) { in_moddoc = 0; moddoc_done = 1 }
  if (line ~ /^[ \t]*\/\/\//) {
    t = line; sub(/^[ \t]*\/\/\/ ?/, "", t)
    doc = (ndoc == 0) ? t : doc "\n" t
    ndoc++
    header = 0
    next
  }
  if (line ~ /^[ \t]*\/\//) {
    t = line; sub(/^[ \t]*\/\/ ?/, "", t)
    if (header) hdr = hdr t "\n"
    else { ldoc = ldoc t "\n"; ndoc = 0; doc = "" }
    next
  }
  header = 0
  if (line ~ /^[ \t]*$/) { ndoc = 0; doc = ""; ldoc = ""; next }
  if (line ~ /^(@[A-Za-z_]+(\([^)]*\))?[ \t]+)*export[ \t]/) { begin_item(line); next }
  ndoc = 0; doc = ""; ldoc = ""
}

# Header comment of a legacy file stands in for its module doc.
function finish_module() {
  if (!mod_hasdoc[nmod] && mod_legacy[nmod]) mod_doc[nmod] = hdr
}

# ---- per-item analysis --------------------------------------------------

function analyse(i,    t, nm, p, q, op, cl, params, after, k, hasptr, rt) {
  t = it_text[i]
  it_name[i] = ""; it_sig[i] = ""; it_type[i] = ""; it_value[i] = ""
  it_np[i] = 0; it_rtype[i] = ""
  if (it_kind[i] == "fn") {
    t = squash(t)
    if (match(t, /fn [A-Za-z_][A-Za-z0-9_]*/)) it_name[i] = substr(t, RSTART + 3, RLENGTH - 3)
    op = index(t, "(")
    # parameters end at the parenthesis that closes the first "("
    cl = 0; q = 0
    for (p = op; p <= length(t); p++) {
      if (substr(t, p, 1) == "(") q++
      else if (substr(t, p, 1) == ")") { q--; if (q == 0) { cl = p; break } }
    }
    params = (op > 0 && cl > op) ? substr(t, op + 1, cl - op - 1) : ""
    after = (cl > 0) ? trim(substr(t, cl + 1)) : ""
    it_np[i] = split_params(params)
    for (k = 1; k <= it_np[i]; k++) { it_pn[i, k] = P_name[k]; it_pt[i, k] = P_type[k] }
    rt = ""
    if (substr(after, 1, 2) == "->") rt = trim(substr(after, 3))
    sub(/ = ".*$/, "", rt)
    sub(/ (with|where|requires|provides|forbids) .*$/, "", rt)
    it_rtype[i] = rt
    t = substr(t, 1, cl) ((after == "") ? "" : " " after)
    gsub(/\( /, "(", t); gsub(/ \)/, ")", t); gsub(/ ,/, ",", t)
    it_sig[i] = t
  } else if (it_kind[i] == "const" || it_kind[i] == "var") {
    p = index(t, "=")
    lhs = (p > 0) ? substr(t, 1, p - 1) : t
    it_value[i] = (p > 0) ? trim(substr(t, p + 1)) : ""
    gsub(/\n[ \t]*/, " ", it_value[i])
    lhs = squash(lhs)
    sub(/^(extern )?(const|var) /, "", lhs)
    k = index(lhs, ":")
    if (k > 0) { it_name[i] = trim(substr(lhs, 1, k - 1)); it_type[i] = trim(substr(lhs, k + 1)) }
    else it_name[i] = trim(lhs)
  } else {
    nm = squash(t)
    if (match(nm, /^[a-z]+ [A-Za-z_][A-Za-z0-9_]*/)) {
      it_name[i] = substr(nm, RSTART, RLENGTH); sub(/^[a-z]+ /, "", it_name[i])
    }
    if (it_kind[i] == "struct") analyse_struct(i)
    else it_sig[i] = nm
  }
}

# Fields of a struct, one entry per declaration; methods are skipped.
function analyse_struct(i,    t, ob, before, body, nb, B, k, line0, l, code, fdoc, hasdoc, nd, D, j, decl, depth, nf, c, fl) {
  t = it_text[i]
  ob = index(t, "{")
  before = substr(t, 1, ob - 1)
  body = substr(t, ob + 1, length(t) - ob - 1)
  line0 = it_line[i] + gsub(/\n/, "\n", before)
  nb = split(body, B, "\n")
  nf = 0; depth = 0
  for (k = 1; k <= nb; k++) {
    l = B[k]; code = l; fdoc = ""; hasdoc = 0
    if (match(l, /\/\/\//)) { code = substr(l, 1, RSTART - 1); fdoc = trim(substr(l, RSTART + 3)); hasdoc = 1 }
    else if (match(l, /\/\//)) { code = substr(l, 1, RSTART - 1); fdoc = trim(substr(l, RSTART + 2)) }
    if (depth > 0 || code ~ /^[ \t]*method[ \t]/) {
      c = code; depth += gsub(/\{/, "{", c); c = code; depth -= gsub(/\}/, "}", c)
      continue
    }
    nd = split(code, D, ";")
    fl = 0
    for (j = 1; j <= nd; j++) {
      decl = trim(D[j])
      if (!match(decl, /^[A-Za-z_][A-Za-z0-9_]*[ \t]*:/)) continue
      nf++; fl++
      it_fn[i, nf] = trim(substr(decl, 1, RLENGTH - 1))
      it_ft[i, nf] = trim(substr(decl, RLENGTH + 1))
      it_fd[i, nf] = fdoc
      it_fhas[i, nf] = hasdoc
      it_fline[i, nf] = line0 + k - 1
      it_fmany[i, nf] = (fl > 1)
    }
  }
  it_nf[i] = nf
  it_sig[i] = "struct " it_name[i]
}

# ---- rules (non-legacy files only) ---------------------------------------

function check_item(i,    f, l, k, sig, n, ptr, obj) {
  f = it_file[i]; l = it_line[i]
  if (!it_hasdoc[i]) { err(f, l, it_name[i] ": export has no /// doc block"); return }
  parse_doc(it_doc[i])
  for (k = 1; k <= D_nbad; k++) err(f, l, it_name[i] ": unknown tag @" D_bad[k])
  if (D_summary == "") err(f, l, it_name[i] ": missing summary")
  else if (D_summary !~ /\.$/) err(f, l, it_name[i] ": summary does not end with a period")
  if (it_kind[i] == "fn") {
    n = (D_np > it_np[i]) ? D_np : it_np[i]
    for (k = 1; k <= n; k++) {
      if (k > it_np[i]) err(f, l, it_name[i] ": @param " D_pn[k] " is not a parameter")
      else if (k > D_np) err(f, l, it_name[i] ": parameter " it_pn[i, k] " has no @param")
      else if (D_pn[k] != it_pn[i, k]) err(f, l, it_name[i] ": @param " k " is " D_pn[k] ", the signature has " it_pn[i, k])
    }
    if (it_rtype[i] != "" && it_rtype[i] != "void" && !D_hasret) err(f, l, it_name[i] ": missing @return")
    if ((it_rtype[i] == "" || it_rtype[i] == "void") && D_hasret) err(f, l, it_name[i] ": @return on a function that returns nothing")
    if (D_hasret && D_ret ~ /MP_OK/ && D_nerr == 0) err(f, l, it_name[i] ": @return mentions MP_OK but there is no @error")
    sig = it_rtype[i]; ptr = 0; obj = 0
    for (k = 1; k <= it_np[i]; k++) {
      sig = sig " " it_pt[i, k]
      if (it_pt[i, k] ~ OBJ_RE) obj = 1
    }
    if (sig ~ /\*/ || sig ~ /(^|[^A-Za-z0-9_])(string|cstring|rawptr)([^A-Za-z0-9_]|$)/) ptr = 1
    if (ptr && D_mem == "") err(f, l, it_name[i] ": pointer, string or rawptr in the signature but no @mem")
    if (obj && D_thread == "") err(f, l, it_name[i] ": takes a chart or integration object but has no @thread")
  }
  if (it_kind[i] == "struct") {
    if (D_mem == "") err(f, l, it_name[i] ": struct has no @mem")
    for (k = 1; k <= it_nf[i]; k++) {
      if (!it_fhas[i, k]) err(f, it_fline[i, k], it_name[i] "." it_fn[i, k] ": field has no trailing /// doc")
      if (it_fmany[i, k]) err(f, it_fline[i, k], it_name[i] "." it_fn[i, k] ": one field per line")
    }
  }
}

# ---- markdown -------------------------------------------------------------

function slug(s) {
  s = tolower(s)
  gsub(/[^a-z0-9 _-]/, "", s)
  gsub(/ /, "-", s)
  return s
}

function oneline(i) {
  parse_doc(it_doc[i] it_ldoc[i])
  if (D_summary == "" && it_tail[i] != "") D_summary = it_tail[i]
  if (D_body != "") return D_summary " " squash(D_body)
  return D_summary
}

function render_module(m, part,    i, s, has, title, imp) {
  title = "`" mod_path[m] "`" ((part == "int") ? " (internals)" : "")
  s = "## " title "\n\n"
  if (mod_path[m] ~ /^src\//) {
    imp = mod_path[m]; sub(/^src\//, "", imp); sub(/\.mettle$/, "", imp)
    s = s "`import \"mistplot/" imp "\";`\n\n"
  }
  if (part == "pub" || mod_internal[m]) {
    if (trim(mod_doc[m]) != "") s = s paragraphs(mod_doc[m]) "\n\n"
    if (mod_legacy[m]) s = s "_Legacy module: its comments predate the doc rules._\n\n"
  }
  s = s render_table(m, part, "const", "Constants", "Value")
  s = s render_table(m, part, "var", "Variables", "Initial value")
  for (i = 1; i <= nit; i++) if (in_part(i, m, part) && it_kind[i] != "fn" && it_kind[i] != "const" && it_kind[i] != "var") s = s render_type(i)
  for (i = 1; i <= nit; i++) if (in_part(i, m, part) && it_kind[i] == "fn") s = s render_fn(i)
  return s
}

function in_part(i, m, part) {
  if (it_mod[i] != m) return 0
  if (mod_internal[m]) return part == "int"
  parse_doc(it_doc[i])
  return (part == "int") ? D_internal : !D_internal
}

function module_in_part(m, part,    i) {
  if (mod_internal[m]) return part == "int"
  if (part == "pub") return 1
  for (i = 1; i <= nit; i++) if (in_part(i, m, "int")) return 1
  return 0
}

# Doc text with paragraph breaks kept and lines inside a paragraph joined.
function paragraphs(d,    nl, L, k, out, para) {
  nl = split(d, L, "\n"); out = ""; para = ""
  for (k = 1; k <= nl; k++) {
    if (trim(L[k]) == "") { if (para != "") { out = (out == "") ? para : out "\n\n" para; para = "" } continue }
    para = (para == "") ? trim(L[k]) : para " " trim(L[k])
  }
  if (para != "") out = (out == "") ? para : out "\n\n" para
  return out
}

function render_table(m, part, kind, heading, vhead,    i, s, n, desc) {
  s = ""; n = 0
  for (i = 1; i <= nit; i++) {
    if (!in_part(i, m, part) || it_kind[i] != kind) continue
    if (n == 0) s = "**" heading "**\n\n| Name | Type | " vhead " | Description |\n|---|---|---|---|\n"
    n++
    desc = oneline(i)
    s = s "| `" it_name[i] "` | " code(it_type[i]) " | " code(it_value[i]) " | " cell(desc) " |\n"
  }
  return (n > 0) ? s "\n" : ""
}

function code(s) { if (s == "") return ""; return "`" cell(s) "`" }

function prose(i,    s) {
  parse_doc(it_doc[i] it_ldoc[i])
  if (D_summary == "" && it_tail[i] != "") D_summary = it_tail[i]
  if (D_summary == "") return "_Undocumented._\n\n"
  s = D_summary "\n\n"
  if (D_body != "") s = s D_body "\n\n"
  return s
}

function render_type(i,    s, k) {
  s = "### `" it_name[i] "`\n\n```mettle\n" it_sig[i] "\n```\n\n" prose(i)
  if (it_kind[i] == "struct" && it_nf[i] > 0) {
    s = s "| Field | Type | Description |\n|---|---|---|\n"
    for (k = 1; k <= it_nf[i]; k++) s = s "| `" it_fn[i, k] "` | " code(it_ft[i, k]) " | " cell(it_fd[i, k]) " |\n"
    s = s "\n"
  }
  parse_doc(it_doc[i])
  return s tags()
}

function render_fn(i,    s, k, j, txt, sig) {
  sig = it_sig[i]
  if (length(sig) > 96 && it_np[i] > 1) {
    sig = substr(sig, 1, index(sig, "(")) "\n"
    for (k = 1; k <= it_np[i]; k++) sig = sig "  " it_pn[i, k] ": " it_pt[i, k] ((k < it_np[i]) ? "," : "") "\n"
    sig = sig ")" ((it_rtype[i] != "") ? " -> " it_rtype[i] : "")
  }
  s = "### `" it_name[i] "`\n\n```mettle\n" sig "\n```\n\n" prose(i)
  parse_doc(it_doc[i])
  if (it_np[i] > 0) {
    s = s "| Parameter | Type | Meaning |\n|---|---|---|\n"
    for (k = 1; k <= it_np[i]; k++) {
      txt = ""
      for (j = 1; j <= D_np; j++) if (D_pn[j] == it_pn[i, k]) txt = D_pt[j]
      s = s "| `" it_pn[i, k] "` | " code(it_pt[i, k]) " | " cell(txt) " |\n"
    }
    s = s "\n"
  }
  return s tags()
}

function tags(    s, k, c, sp) {
  s = ""
  if (D_hasret) s = s "**Returns:** " D_ret "\n\n"
  if (D_nerr > 0) {
    s = s "**Errors:**\n\n"
    for (k = 1; k <= D_nerr; k++) {
      sp = index(D_err[k], " ")
      if (sp > 0) s = s "- `" substr(D_err[k], 1, sp - 1) "` " substr(D_err[k], sp + 1) "\n"
      else s = s "- `" D_err[k] "`\n"
    }
    s = s "\n"
  }
  if (D_mem != "") s = s "**Memory:** " D_mem "\n\n"
  if (D_thread != "") s = s "**Threads:** " D_thread "\n\n"
  if (D_cost != "") s = s "**Cost:** " D_cost "\n\n"
  return s
}

END {
  if (cur_kind != "") err(it_file[nit], it_line[nit], "unterminated export")
  if (nmod > 0) finish_module()
  for (i = 1; i <= nit; i++) analyse(i)
  if (mode == "check") {
    for (m = 1; m <= nmod; m++) {
      if (mod_legacy[m]) continue
      has = 0
      for (i = 1; i <= nit; i++) if (it_mod[i] == m) has = 1
      if (has && trim(mod_doc[m]) == "" ) err(mod_path[m], 1, "no //! module doc")
    }
    for (i = 1; i <= nit; i++) if (!mod_legacy[it_mod[i]]) check_item(i)
    for (k = 1; k <= nerr; k++) print errs[k]
    exit(nerr > 0)
  }
  printf "# MistPlot API reference\n\n"
  printf "Generated by `tools/apidoc.sh` from the `//!` and `///` comments in `src/` and\n"
  printf "`integrations/*/mp_*.mettle`. Do not edit by hand: change the comments and run\n"
  printf "`tools/apidoc.sh`.\n\n"
  for (pass = 1; pass <= 2; pass++) {
    part = (pass == 1) ? "pub" : "int"
    printf "- %s\n", (pass == 1) ? "[Public API](#public-api)" : "[Internals](#internals)"
    for (m = 1; m <= nmod; m++) {
      if (!module_in_part(m, part)) continue
      t = "`" mod_path[m] "`" ((part == "int") ? " (internals)" : "")
      printf "  - [%s](#%s)\n", mod_path[m], slug(t)
    }
  }
  for (pass = 1; pass <= 2; pass++) {
    part = (pass == 1) ? "pub" : "int"
    printf "\n# %s\n", (pass == 1) ? "Public API" : "Internals"
    for (m = 1; m <= nmod; m++) {
      if (!module_in_part(m, part)) continue
      s = render_module(m, part)
      sub(/\n+$/, "\n", s)
      printf "\n%s", s
    }
  }
}
AWK

# Prints the input files, relative to $1.
inputs() {
  (cd "$1" && {
    [ -d src ] && find src -name '*.mettle' ! -name '*_test.mettle'
    [ -d integrations ] && find integrations -mindepth 2 -maxdepth 2 -name 'mp_*.mettle'
  } | sort)
}

# Legacy list as |a|b|; a listed file that does not exist is a finding.
legacy_set() { # list-file root
  local f="$1" r="$2" n=0 line set="|"
  [ -f "$f" ] || { echo "|"; return 0; }
  while IFS= read -r line || [ -n "$line" ]; do
    n=$((n + 1))
    line="${line%%#*}"
    line="$(echo "$line" | sed 's/[[:space:]]*$//; s/^[[:space:]]*//')"
    [ -z "$line" ] && continue
    if [ ! -f "$r/$line" ]; then
      echo "${f#"$r"/}:$n: $line is listed but does not exist" >&2
    fi
    set="$set$line|"
  done < "$f"
  echo "$set"
}

run() { # mode root legacy-file
  local m="$1" r="$2" lf="$3" set files
  LEGACY_BAD=0
  set="$(legacy_set "$lf" "$r" 2>"$TMPD/legacy.err")"
  if [ -s "$TMPD/legacy.err" ]; then
    cat "$TMPD/legacy.err" >&2
    [ "$m" = check ] && LEGACY_BAD=1
  fi
  mapfile -t files < <(inputs "$r")
  [ "${#files[@]}" -gt 0 ] || { echo "apidoc: no inputs under $r" >&2; return 2; }
  (cd "$r" && awk -v mode="$m" -v legacy="$set" \
    -v OBJ_RE='^(MpChart|MpRaize[A-Za-z0-9_]*|MpMythic[A-Za-z0-9_]*|MpMeo[A-Za-z0-9_]*)[*]$' \
    "$AWK_PROG" "${files[@]}" > "$TMPD/awk.out"); local rc=$?
  if [ "$m" = check ]; then sort -s -t: -k1,1 -k2,2n "$TMPD/awk.out"; else cat "$TMPD/awk.out"; fi
  [ "$rc" = 0 ] || return 1
  [ "$LEGACY_BAD" = 0 ]
}

TMPD="$(mktemp -d)"
trap 'rm -rf "$TMPD"' EXIT

case "$mode" in
  gen)
    [ -n "$legacy" ] || legacy="$root/tools/apidoc_legacy.txt"
    [ -n "$out" ] || out="$root/docs/API.md"
    mkdir -p "$(dirname "$out")"
    run gen "$root" "$legacy" > "$TMPD/API.md" || exit 1
    mv "$TMPD/API.md" "$out"
    ;;
  check)
    [ -n "$legacy" ] || legacy="$root/tools/apidoc_legacy.txt"
    fail=0
    run check "$root" "$legacy" || fail=1
    mkdir -p "$root/build/apidoc"
    if run gen "$root" "$legacy" > "$root/build/apidoc/API.md" 2>/dev/null; then
      if ! cmp -s "$root/build/apidoc/API.md" "$root/docs/API.md"; then
        echo "docs/API.md: stale; run tools/apidoc.sh (diff build/apidoc/API.md docs/API.md)"
        fail=1
      fi
    else
      fail=1
    fi
    exit "$fail"
    ;;
  selftest)
    td="$TOOLS/testdata/apidoc"
    fail=0
    run gen "$td" "$td/legacy.txt" > "$TMPD/got.md" 2>/dev/null
    if cmp -s "$TMPD/got.md" "$td/expected.md"; then echo "ok    apidoc selftest: reference"
    else echo "FAIL  apidoc selftest: reference"; diff "$td/expected.md" "$TMPD/got.md" | head -40; fail=1; fi
    run check "$td" "$td/legacy.txt" > "$TMPD/got.txt" 2>&1
    if cmp -s "$TMPD/got.txt" "$td/expected_check.txt"; then echo "ok    apidoc selftest: check ($(wc -l < "$TMPD/got.txt") findings)"
    else echo "FAIL  apidoc selftest: check"; diff "$td/expected_check.txt" "$TMPD/got.txt" | head -40; fail=1; fi
    exit "$fail"
    ;;
esac
