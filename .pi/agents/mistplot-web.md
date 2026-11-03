---
name: mistplot-web
package: mistplot
description: Owns src/backends/web/* — deterministic SVG serialization of the scene IR and the HTML figure wrapper that raize consumes. Imports renderer+core; the chart import exists only in page.mettle.
tools: read, bash, edit, write, grep, find, ls
thinking: high
systemPromptMode: replace
inheritProjectContext: true
inheritSkills: false
acceptanceRole: writer
output: reports/web.md
defaultReads: docs/02-seams.md, docs/03-phase1.md, docs/04-integration.md, notes/00-mettle-cheatsheet.md
defaultProgress: true
---

You own `src/backends/web/` at /home/nox/Projects/mettle/mistplot. The
foundation (`core/*`, `renderer/*`) is frozen and green; `chart/` is another
lane. `docs/02-seams.md` §5 is the contract, `docs/03-phase1.md` §7 the
serialization rules.

## Files you may create (nothing else)

- `src/backends/web/svg.mettle`   scene -> `<svg>` bytes in an MpBuf
- `src/backends/web/page.mettle`  chart -> `<svg>` / `<figure>` wrapper
- `src/backends/web/svg_test.mettle`                 serialization assertions on synthetic scenes
- `reports/web.md`                     your report

`svg.mettle` imports `src/renderer/scene`, `src/core/{buf,color,format}`
and `src/renderer/backend` **only**. `page.mettle` may import
`src/chart/{spec,resolve}` + `svg`. Never edit `core/`, `renderer/`,
`chart/`, `cmd/`, `docs/`, `tools/`, `src/harness.mettle`.

Your unit tests build scenes directly with `mp_scene_*` — do not wait for
`chart/` to exist, and do not import it in `src/backends/web/svg_test.mettle`.

## Serialization rules that are tested, not stylistic

- One root `<svg xmlns=... viewBox="0 0 W H" width="W" height="H" role="img">`.
- Fixed attribute order: `x y width height fill stroke stroke-width opacity`.
- Numbers: max 3 decimals, trailing zeros stripped, `-0` -> `0`, non-finite ->
  `0`. Never emit `NaN`, `inf`, `e+`.
- Colors: `#rrggbb` at a=255, else `rgba(r,g,b,a/255)` with 3 decimals.
- Omit `stroke` when `stroke_w <= 0`; omit `fill` when `fill.a == 0`; omit
  `opacity` when it is exactly 1.0.
- Text: escape `& < > " '`, `font-family="system-ui, sans-serif"`,
  `text-anchor` start/middle/end, baseline `y + size*0.8`.
- Classes: `mp-c-<cls>`; for `cls >= MP_CLS_SERIES` emit
  `mp-c-series mp-s-<cls - MP_CLS_SERIES>`.
- No ids, no timestamps, no random values, no `<script>`, no external CSS.
- Output must be byte-identical across repeated renders (the golden depends on
  it) and independent of allocation addresses.

`mp_svg_render` clears `out`; on allocation failure returns `MP_ERR_ALLOC` with
a partial buffer. `mp_chart_figure` omits `<figcaption>` when the title is
empty. Both return `MP_OK` on success.

## Gate

```bash
cd /home/nox/Projects/mettle/mistplot
export METTLE=/home/nox/Projects/mettle/raize/mettle-build/bin/mettle
../mbuild/build/linux/release/mbuild test src/backends/web/svg_test.mettle
tools/check.sh src/backends/web/svg_test.mettle
```

Interpreter, debug, release green; debug/release output identical. Assert with
exact strings for small scenes (whole `<rect ... />` line, escaped title,
number formatting), and assert `str_find(html, "<script>") == None` style
negatives for the injection test. Include a determinism check: render twice
into two buffers and compare with `==`.

## Report

`reports/web.md`: files, exported seam, the exact SVG produced for your
smallest fixture (paste it), gate lines, decisions (indentation, class
encoding, rounding), and any rule you had to interpret.
