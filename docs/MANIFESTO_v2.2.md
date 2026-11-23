# The Huey GUI Manifesto (v2.2 — Zig-Native Edition)

Every major GUI toolkit failed by either over-abstracting the hardware, drowning in state synchronization, or dragging a bloated document-object runtime into what should be an interactive rendering loop. **Huey** is a clean synthesis: a lean, hardware-accelerated, data-oriented Zig toolkit built for human ergonomics, autonomous agentic workflows, desktop window managers (`huey-stratifi`), mobile tablets (`huey-showcase.apk`), and Wear OS (`huey-wear.apk`).

---

## 1. The DNA Extraction

| Toolkit | What to Steal | What to Burn |
| :--- | :--- | :--- |
| **Dear ImGui** | Immediate-mode ergonomics, zero state synchronization for transient UI, flat frame declaration, tiny footprint. | Constant frame churn on idle apps; weak text shaping/layout semantics. |
| **HTML / CSS** | Flexbox + 2D Grid box model, tokenized theming, subpixel text flow. | The DOM, JS runtimes, runtime CSS string parsing, reflow thrashing. |
| **SwiftUI / Cocoa** | Two-way bindings (`&state.field` in Zig = `$binding` without ARC), Gesture Recognizer arbitration, responder chain, native accessibility. | ARC `@escaping` retain cycles (`[weak self]`), opaque `AttributeGraph` magic, Objective-C overhead. |
| **Qt / QML** | Clean dirty-flagged updates, explicit focus scopes, high-quality canvas abstractions. | Custom scripting DSLs/MOC preprocessors, C++ OOP hierarchies, massive binaries, dual-licensing traps. |
| **GTK / Win32** | Clean C ABI boundaries, deterministic OS event loops (`epoll` / `ALooper`), raw input control. | GObject boilerplate, legacy non-DPI-aware handles. |

---

## 2. Core Architecture: The Data-Oriented Hybrid Engine

### 2.1 Retained SoA Arena Layout, Zero-Allocation Immediate Frame
- **Flat SoA Layout Tree (`std.MultiArrayList(Node)`):** Nodes live in contiguous, cache-coherent Struct-of-Arrays arenas indexed by generational `NodeId` (`index: u16, gen: u16`). Dirty-flagged incremental relayout skips clean passes when viewport and tree are unchanged.
- **Hybrid Identity & End-of-Frame GC (`WidgetStateStore`):** Hierarchical `Wyhash` keys preserve retained state (scroll offsets, cursors, animations) across dynamic list insertions, while unvisited widgets are swept in O(N) zero-alloc `swapRemoveAt` at `endFrame()`.
- **Zero-Allocation Frame Render:** Widgets emit `96`-byte `QuadInstance`s directly into a pre-allocated buffer—mechanically enforcing **zero heap allocations per frame**.
- **Sum-Tree Viewport Virtualization (`1M+` rows):** Flat bottom-up binary segment tree resolves visible rows in `O(log N)` with zero floating-point drift.
- **Zero-Tick Sleep & Hardware Display-Link Pacing:** Idle loops block cleanly in `ALooper_pollOnce(-1)` / `epoll_wait(-1)` (**0% CPU**). Active animations pace strictly off hardware VSync (`AChoreographer` `DispSync` on Android, `wl_surface.frame` on Wayland) and drop straight back to sleep on settle.

### 2.2 DPI-Agnostic Coordinates & Mixed-DPI Multi-Monitor
- **Logical-First (`f32`):** All layout constraints, paddings, and pointer coordinates operate in resolution-independent logical points (`dp`).
- **Hardware-Boundary Snapping & Multi-Scale Atlases:** Per-output `scale_factor` (including fractional scales `1.25x`, `1.5x`, `1.75x`, `2.0x` via `wp_fractional_scale_v1`) is applied strictly at vertex emission and glyph/icon atlas lookup.

### 2.3 Single-Pass Hardware Rendering (`sokol_gfx` + Native Event Loops)
- **Zero Backend Maintenance Hell:** Use standalone **`sokol_gfx`** (zlib/MIT, ~150 KB, zero per-frame allocations) strictly for GPU rendering (**GLES 3.0/3.1**, OpenGL 4.1, Metal, D3D11, WebGPU) while owning thin native OS event loops (Android `NativeActivity`/`SurfaceView`, pure-Zig Wayland `xdg_shell` + `zwlr_layer_shell_v1` for `stratifi`).
- **Single-Pass Instanced UberQuads (96 bytes/quad):** One instanced draw call renders SDF rounded rects, crisp borders, analytic drop shadows, per-instance hierarchical `clip_rect` scissor clipping, and `R8` LRU glyph atlas text—composited in **IEC 61966-2-1 linear space** to eliminate gamma-crushed dark halos.
- **Hardware-Proven on 2014 Nexus 9 (2-core Denver, 1.84 GB RAM, GLES 3.1 / no Vulkan):** `~235 KB` stripped `.so`, **344 instanced UberQuads (shapes + Roboto text) at locked 60.0 FPS VSync (`2.1–3.0 ms` CPU+submit)**, **`0%` idle CPU**.

### 2.4 2-Stage Event Model, Focus Engine & Accessibility
- **Stage 1 (Internal Routing):** Platform input normalizes into flat `InputEvent`s → Gesture Recognizer / `TouchArbiter` (44dp touch hit-slop, 8dp drag-slop, axis-locked scroll vs. slider drag) → reverse-DFS z-order hit-test respecting `clip_children` and modal traps.
- **Stage 2 (Zero-Callback-Hell Consumption):** Two-way `&state.field` bindings + pre-allocated per-frame `UiEvent` queue (`pollEvents()`)—working identically in Zig, C ABI, declarative JSON, `stratifi`, and headless tests.
- **Focus & Accessibility:** Trapped modal/launcher focus scopes, roving tabindex, `:focus-visible`, focus restoration, and an iterative OOM-atomic `A11yTree` coupled directly to `LayoutArena` + `FocusManager`.

### 2.5 No Custom Scripting DSL: Thin C ABI + Declarative Data Schema
- **Thin Flat C ABI (`include/huey.h`):** ~21 plain `extern fn` calls with fixed-width `uint32_t` enums (`-fshort-enums` safe) and `huey_poll_event(&ev)` for Go, Rust, Python, Lua, and C consumers.
- **Declarative JSON Schema (`src/declarative.zig`):** Two-pass atomic hot-reload of static widget trees and Oklab design tokens (`MmapTokenBuffer` with `pread` SIGBUS safety and CRC32 validation)—ideal for `huey-stratifi` bars, HUDs, and launchers with zero custom language maintenance.

---

## 3. Agent-Native Ergonomics & Observability
- **Flat Zig Umbrella & Struct-Literal API (`@import("huey")`) + Repo `SKILL.md`:** Zero macro DSLs, minimal hallucination surface.
- **Pure-CPU Headless Runner (`HeadlessSession`):** `act → step(dt_ms) → inspect` across arbitrary DPI matrices, pure-Zig CPU UberQuad PNG snapshots (with optional `bbox` overlays), and automatic UI lints (`OVERFLOW`, `ZERO_SIZE`, `OCCLUDED_TARGET`, `SMALL_TOUCH_TARGET < 44dp`, Oklab `LOW_CONTRAST`).
- **Local `AF_UNIX` NDJSON IPC (`IpcServer`):** 100% non-blocking, `0600` + `SO_PEERCRED`-authenticated semantic inspection & control without pixel-scraping.

---

## 4. Non-Negotiable Operational Pillars
1. **Permissive Licensing:** MIT / Apache-2.0 / zlib across the entire stack.
2. **Sub-5 MB Stripped Binaries:** Currently `~235 KB` stripped `libhuey.so` on Android ARM64 (`huey-showcase.apk` / `huey-wear.apk`).
3. **True DPI Agnosticism & Linear-Space Quality.**
4. **Agent-First Operability & First-Class Accessibility.**
5. **Instant Token & Layout Hot-Reloading.**
