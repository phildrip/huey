# Huey

**A tiny, fast, data-oriented GUI toolkit in Zig — for Linux Wayland, Android, and Wear OS.**

> *~340 KB signed Android & Wear OS APKs · 60 Hz on a 2014 Nexus 9 & OnePlus Watch 3 · 0% idle CPU*

---

## Why Huey?

Modern GUI toolkits got heavy. A simple watch key app or desktop launcher shouldn't ship a 40 MB runtime, burn battery polling at 60 Hz when nothing is moving, or drop frames on a modest mobile GPU.

Huey solves five everyday GUI problems:

- **Bloat & slow cold starts** — compiles to a single ~300 KB native library with zero JVM/Electron/Compose overhead.
- **Idle battery drain** — sleeps at **0% CPU** via `ALooper` / `AChoreographer` / `epoll` and wakes only on input, scroll, or active springs.
- **Fragile draw-call soup** — draws rounded rects, borders, soft shadows, clips, circular OLED masks, and text glyphs in **one instanced UberQuad pass**.
- **Muddy colors & jarring motion** — blends in exact linear sRGB, themes in perceptual **Oklab** (with WCAG contrast guards & OS dark/light hooks), and animates with unconditionally stable analytical springs.
- **Untestable UIs** — includes a deterministic pure-Zig headless rasterizer (`HeadlessSession`) that outputs PNGs, layout trees, and automatic contrast/overlap lints in milliseconds.

---

## The Short Manifesto

1. **One Shader, One Pass.** Instanced SDF UberQuads + a single R8 glyph atlas (`sokol_gfx` / GLES 3.1).
2. **Zero-Tick Sleep.** If nothing is moving, the app does nothing.
3. **Flat Data, Not Deep Objects.** Structure-of-Arrays (`LayoutArena`), zero per-frame heap churn, O(log N) virtual scrolling (`SumTree`).
4. **Perceptual Color & Real Physics.** Oklab palettes + closed-form damped springs, never hardcoded themes.
5. **Native Everywhere That Matters.** Pure-Zig Wayland (`zwlr_layer_shell_v1` / `xdg_shell`), Android, and natively circular Wear OS (round SDF clip, curved scroll scaling, rotary crown, OLED ambient mode), plus a thin C ABI ([`include/huey.h`](include/huey.h)).
6. **Built for Humans & Agents.** Flat APIs, declarative JSON scenes, and deterministic headless verification — no custom scripting DSL.

Read the full version in [`docs/MANIFESTO_v2.2.md`](docs/MANIFESTO_v2.2.md) and the API cookbook in [`SKILL.md`](SKILL.md).

---

## Quick Start

Requires **Zig 0.16.0** (plus Android SDK/NDK for mobile/watch builds).

```bash
# Run all 35 host unit test suites
zig build test

# Build & run the Wayland status bar / launcher prototype
zig build bloxwm-demo && ./zig-out/bin/huey-bloxwm --headless

# Build Android tablet & Wear OS showcase APKs
./build_apk.sh
./build_wear_apk.sh
```

---

## License

Dual-licensed under either the **MIT License** ([`LICENSE-MIT`](LICENSE-MIT)) or the **Apache License, Version 2.0** ([`LICENSE-APACHE`](LICENSE-APACHE)), at your option.
