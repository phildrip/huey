---
name: ziggui
description: Author, test, inspect, and auto-fix UIs using the Zig UberQuad GUI Toolkit (SoA LayoutArena, single-pass SDF+text UberQuads, 2-stage InputEvent->UiEvent, HeadlessSession PNG+Oklab lints, AF_UNIX IPC, C ABI, and declarative JSON layouts).
---

# ZigGui Agentic Skill & Flat-API Cookbook

## Core Invariants (Never Violate)
1. **Logical-First Coordinates (`f32`):** All layout widths, heights, paddings, gaps, and pointer coordinates are DPI-agnostic logical points (`dp`). Physical pixel snapping happens strictly at quad emission (`snapRectToPhysical`).
2. **Zero-Allocation Frame Render:** `LayoutArena.emitQuads` / `emitQuadsWithAtlas` writes directly into a pre-allocated `[]QuadInstance` buffer (96 bytes/quad). Never allocate inside render/layout hot paths.
3. **Single-Pass UberQuads:** Shapes (`params[3] == 0.0`), foreground ambient indicators (`0.25`), and glyph atlas quads (`1.0`) share one `QuadInstance` struct and one instanced draw call (`clip_rect` per-instance scissor discard in `fs_source`).
4. **Zero-Tick Sleep:** Block in `ALooper_pollOnce(-1)` / `epoll_wait(-1)` when idle; pace animations strictly on hardware VSync (`AChoreographer` / `wl_surface.frame`) and stop immediately on settle.
5. **No Custom Scripting DSL:** Use flat Zig struct literals, the C ABI (`include/ziggui.h`), or declarative JSON (`src/declarative.zig`) wired to `EventRouter.pollEvents()`.

---

## 1. Flat Zig API Quick Reference

```zig
const core = @import("core.zig");
const events = @import("events.zig");
const headless = @import("headless.zig");

var session = try headless.HeadlessSession.init(allocator, 768.0, 976.0, 2.0);
defer session.deinit();

const root = try session.arena.addNode(.{
    .kind = .vstack,           // .vstack | .hstack | .zstack | .grid | .card | .toggle | .slider | .bar
    .role = .container,        // .container | .panel | .switch_control | .slider | .progress_bar | .swatch
    .test_id = "settings.root",
    .padding = 16.0,
    .gap = 12.0,
    .clip_children = true,     // enables per-instance scissor clipping + scrolling
    .fill = core.Nord.polar_night_0,
});

_ = try session.arena.addChild(root, .{
    .kind = .toggle,
    .role = .switch_control,
    .test_id = "settings.gpu_cache",
    .label = "GPU Glyph Atlas",
    .height = 56.0,
    .corner_radius = 14.0,
    .border_width = 1.5,
    .shadow_blur = 6.0,
    .fill = core.Nord.polar_night_1,
    .border = core.Nord.polar_night_3,
    .accent = core.Nord.frost_1,
    .checked = true,
});
```

### Layout Fields on `core.NodeDesc`
- **Flexbox:** `width`, `height`, `min_width`, `max_width`, `min_height`, `max_height`, `flex`, `flex_shrink`, `flex_wrap`, `justify` (`.start`|`.center`|`.end`|`.space_between`|`.space_around`|`.space_evenly`), `align_items` (`.start`|`.center`|`.end`|`.stretch`), `padding`, `gap`.
- **2D Grid (`.grid`):** `grid_cols` (`1..64`), `grid_col_gap`, `grid_row_gap`, `col_span`, `row_span`.
- **Focus & State:** `disabled`, `focusable`, `roving_group`, `checked`, `slider_val`.

---

## 2. Headless `act -> step -> inspect` Agent Loop

```zig
_ = session.step(16.67);
try session.act(.{ .click_id = "settings.gpu_cache" });
const res = session.step(16.67); // res.events -> []const events.UiEvent

// Automatic UI lints (ZERO GPU required):
var diags: [64]headless.Diagnostic = undefined;
const n_diag = session.runDiagnostics(&diags);
// Codes: .overflow, .zero_size, .occluded_target, .small_touch_target (<44dp), .low_contrast (Oklab ΔL < 0.25)

// Pixel-exact + bbox-annotated PNG snapshot:
const rgba = try session.renderSnapshotRgba(allocator, true);
defer allocator.free(rgba);
try headless.encodePng(writer, phys_w, phys_h, rgba);
```

---

## 3. Live `AF_UNIX` NDJSON IPC Protocol (`src/ipc_bridge.zig`)
Connect to the app's `0600` `AF_UNIX` socket (same-UID `SO_PEERCRED` verified) and send newline-terminated JSON:
- `{"cmd":"inspect"}\n` → `{"ok":true,"tree":{...}}` (AT-SPI/AccessKit-compatible semantic tree)
- `{"cmd":"toggle","id":"settings.gpu_cache"}\n` → `{"ok":true}`
- `{"cmd":"set_value","id":"settings.threads","value":0.75}\n` → `{"ok":true}`
- `{"cmd":"scroll","id":"dashboard.root","x":0,"y":240}\n` → `{"ok":true}`
- `{"cmd":"focus","id":"settings.gpu_cache"}\n` → `{"ok":true}`

---

## 4. Declarative JSON Layouts (`src/declarative.zig`)
Two-pass atomic hot-reload (invalid JSON preserves the existing live UI untouched):
```json
{
  "type": "hstack",
  "id": "bloxwm.bar",
  "height": 32,
  "padding": 6,
  "gap": 8,
  "fill": "bg_base",
  "children": [
    { "type": "bar", "id": "sys.cpu", "width": 120, "value": 0.42, "accent": "accent_primary", "label": "CPU" },
    { "type": "toggle", "id": "notify.dnd", "width": 110, "checked": false, "accent": "accent_success", "label": "DND" }
  ]
}
```
Supported color tokens: `bg_base`, `bg_surface`, `bg_elevated`, `border_default`, `border_focus`, `text_primary`, `text_muted`, `accent_primary`, `accent_success`, `accent_warn`, `accent_danger`, `transparent`, Nord aliases (`polar_night_0..3`, `frost_0..3`, `aurora_*`, `snow_storm_0..2`), and `#RRGGBB`/`#RRGGBBAA`.

---

## 5. C ABI (`include/ziggui.h`)
For Go, Rust, Python, Lua, or C consumers:
```c
ZigguiContext *ctx = ziggui_create(768.0f, 976.0f, 2.0f);
uint32_t root = ziggui_add_vstack(ctx, 0, "root", 16.0f, 12.0f);
uint32_t tog  = ziggui_add_toggle(ctx, root, "c.tog", "Cache", 56.0f, false);
ziggui_layout(ctx);
ZigguiEvent ev;
while (ziggui_poll_event(ctx, &ev)) { /* handle ev.kind / ev.test_id */ }
```

---

## 6. Verification Commands
- Run all unit tests + Android APK build/verify: `./build_apk.sh`
- Run single module test in milliseconds: `zig test src/<module>_test.zig`
- Deploy & visually verify on Android/Nexus 9:
  `adb install -r build/ziggui-spike.apk && adb shell am start -n com.ziggui.spike/android.app.NativeActivity`
