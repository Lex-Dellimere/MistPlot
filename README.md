# MistPlot

Charts for [Mettle](https://github.com/suidvandiewereld/Mettle): line, bar and
scatter, static or live. One layout engine builds a display list (a scene of
rects, lines, polylines, circles and text), and small backends turn it into
SVG, an HTML `<figure>`, terminal text, or MythicUI paint calls. Output is
deterministic: the same chart renders the same bytes.

```
src/core/        buffers, colors, data series, scales, ticks, number format
src/renderer/    the scene (display list) and render options
src/chart/       spec -> layout -> scene
src/live/        ring buffers, min/max decimation, MpLive
src/backends/    web (SVG, figure, live embed) and terminal
src/export/      write an SVG file
integrations/    raize (RaizeWeb), mythic (MythicUI), meodb (MeoDB)
cmd/golden/      prints the tests/golden/ fixtures (tools/golden.sh --update rewrites them)
```

## Build

MistPlot needs the head Mettle compiler (`../Mettle/bin/mettle`), not the
v0.17.0 release.

```bash
./check.sh
```

`check.sh` runs every test in the interpreter, builds and runs each test in
debug and release, compares `cmd/golden` with every file in `tests/golden/`, and
runs the RaizeWeb, MythicUI and MeoDB integration builds. It prints `PASS`.
`MEODB_DIR` picks the MeoDB checkout (default `../meodb`); an
integration whose library isn't on disk is skipped.

To use MistPlot from an app, add it to the app's `mbuild.mettle`:

```mettle
mb_dep_path("mistplot", "../mistplot");
```

and import modules as `import "mistplot/chart/spec";`. The integrations live
outside `src/`, so an app imports one by path (for example
`import "../mistplot/integrations/raize/mp_raize";`) and maps its host
library itself.

## Static charts

```mettle
var s: MpSeries* = mp_series_new("latency", 0);
mp_series_push(s, 0.0, 12.0);
mp_series_push(s, 1.0, 15.0);

var spec: MpChartSpec = mp_chart_spec(MP_CHART_LINE, s, 1);
spec.title = "Latency";
spec.y_label = "ms";
var o: MpRenderOpts = mp_render_opts(spec.width, spec.height, spec.theme);

var out: MpBuf* = mp_buf_new(4096);
mp_chart_svg(&spec, &o, out);        // or mp_chart_figure for HTML
```

The spec borrows its series and strings, so keep them alive while it is used.
`mp_chart_render` gives you the scene itself, for `mp_ascii_render`,
`mp_export_svg` or your own backend. For a terminal, size the spec with
`mp_ascii_chart_width(cols)` / `mp_ascii_chart_height(rows)` and draw it with
`mp_ascii_render_grid`, so each line of chart text takes one row. Bars take category names through
`spec.categories` / `spec.n_categories`; `x_fixed` / `y_fixed` pin an axis
range; `MP_FMT_TIME` labels seconds as `mm:ss`.

## Live charts

```mettle
var lv: MpLive* = mp_live_new(MP_CHART_LINE, 1, 4096);  // kind, series, samples kept
mp_live_series_name(lv, 0, "cpu");
mp_live_window(lv, 60.0);                 // show the last 60 x units
mp_live_spec(lv)->x_format = MP_FMT_TIME;
mp_live_touch(lv);                        // after editing the spec

mp_live_push(lv, 0, t, value);            // O(1)
if (mp_live_update(lv)) {                 // re-renders only when something changed
  var sc: MpScene* = mp_live_scene(lv);
}
```

A frame costs O(plot width) however many samples there are: each pixel column
keeps its first, min, max and last sample, so peaks survive. `mp_live_seq`
counts changes and is what the web and MythicUI integrations use to skip work.
`MpLive` is not thread-safe; share it under your own lock.

## RaizeWeb

`integrations/raize/mp_raize.mettle`. Your app maps RaizeWeb's `raize_core` and `raize_realtime`.

```mettle
fn h_chart(ctx: RzContext*) -> int32 { return mp_raize_svg(ctx, g_spec, g_opts); }
fn h_live(ctx: RzContext*) -> int32 { return mp_raize_live_serve(ctx, g_rl); }
```

- Every helper returns the HTTP status it built, as RaizeWeb's router
  requires.
- To put a chart in a template, use a raw placeholder (`{{{chart}}}`) and
  `mp_raize_tpl_figure`. The buffer it fills must outlive
  `rz_template_render_into`.
- The page embeds the current frame plus a small script (`mp_raize_tpl_live`)
  that polls with `If-None-Match`. An unchanged chart costs a 304 and no render.
- With channels, the page is told about new frames instead:
  `mp_raize_live_channel` registers the chart on a topic, `mp_raize_live_notify`
  (after a batch of pushes) broadcasts the new ETag, and the page
  (`mp_raize_tpl_live_ws`) fetches the frame through the same ETag route. The
  socket carries only the tag because RaizeWeb's outgoing WebSocket data has no
  backpressure. While the socket is down, the page polls.
- `MpRaizeLive` wraps an `MpLive` with a lock and an SVG cache.
  `mp_raize_live_push` and `mp_raize_live_serve` lock for you. Anything else
  that touches the `MpLive` goes between `mp_raize_live_lock` and
  `mp_raize_live_unlock`, followed by `mp_live_touch`.

Example: `integrations/raize/examples/dashboard.mettle` (port 8088,
`--run-for N` to stop on its own).

## MythicUI

`integrations/mythic/mp_mythic.mettle`. Your app maps MythicUI as `mythic`.

```mettle
fn frame(ui: MythicUi*, ud: rawptr) {
  var app: App* = (App*)ud;
  if (ui->pass == 0) {                    // MythicUI may run a frame 3 times
    mp_live_push(app->lv, 0, now_seconds(ui), read_sensor());
  }
  mp_mythic_live(ui, app->live_chart, app->lv, mythic_grow(), mythic_fixed(300));
  mp_mythic_chart(ui, app->bar_chart, &app->bars, mythic_grow(), mythic_fixed(300));
}
```

Each chart keeps its state in an `MpMythicChart` (`mp_mythic_chart_new`/`_free`).
Charts follow the MythicUI theme, measure text with MythicUI's fonts, and show
a hover readout on live charts. Change state only on pass 0; declare the
widgets on every pass. A producer thread pushes under a lock the UI also takes.

Example: `integrations/mythic/examples/live_dashboard.mettle`.

## MeoDB

`integrations/meodb/mp_meo.mettle`, on MeoDB's committed-change feed. Your
app maps MeoDB as `meodb`.

```mettle
var w: MpMeoWatch* = mp_meo_watch_new(feed);
mp_meo_watch_table(w, READINGS, lv, &reload_readings, (rawptr)app);

mp_meo_poll(w);                           // each frame, or in a loop

fn reload_readings(ctx: rawptr, table_id: uint32, lv: MpLive*) -> int32 {
  mp_live_clear(lv);
  // re-scan the table and mp_live_push each row
  return MP_OK;
}
```

Only committed changes count: a rolled-back transaction reloads nothing, and
a reader that fell behind the feed reloads everything. The watcher doesn't read
row values from events yet, so the chart re-queries the table on each change.
`mp_meo_table_stats` says when a table last changed and at which commit, and
`mp_meo_fmt_subtitle` formats that as `updated 10:42:07 · commit 57`. When the
writer is another process, `mp_meo_probe_check` watches the file's commit
counter instead.

Example: `integrations/meodb/examples/meo_live_chart.mettle`.

## Compiler issues

Known head-compiler bugs MistPlot works around:

- `--release`: assigning a struct returned by value to a module-scope
  variable fails (`global_access`) when it nests a struct from another module,
  e.g. `g = mp_chart_spec(...)`. Keep such globals on the heap.
- Debug: an exported function with a `string` parameter, called through a
  function pointer, receives a garbage string. Text-measure callbacks passed
  to `mp_text_set_measure` should not be exported.
- A literal `0` can't be passed for a function-pointer parameter; use
  `mp_text_reset_measure()` instead of `mp_text_set_measure(0, 0)`.

## License

Apache License 2.0. See [LICENSE](LICENSE).
