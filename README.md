<p align="center">
  <img src="assets/huey-logo.png" alt="Huey logo" width="128" />
</p>

<h1 align="center">Huey</h1>

<p align="center">
  A small, cross-platform GUI library in Zig.
</p>

Huey is an experimental, data-oriented UI toolkit targeting desktop, mobile, and wearables. It currently runs on Linux (Wayland), Android, and Wear OS, with macOS, Windows, iOS, and Web planned.

## Goals

- **Small binaries**: Keep dependencies minimal (~350 KB signed Android/Wear OS showcase APKs).
- **Low idle power**: Event-driven wakeup (`epoll` / `ALooper` / `AChoreographer`) so idle apps use 0% CPU.
- **Simple rendering**: Draw rectangles, borders, shadows, clips, circular watch masks, and cached font glyphs in a single GPU pass via `sokol_gfx`.
- **Good color and motion**: Linear-space blending, Oklab themes with OS dark/light detection and contrast checks, and damped spring animations.
- **Testable without a display**: Includes a headless CPU renderer that outputs PNGs, layout trees, and basic layout/contrast checks.

## Design Notes

- **Flat data**: Layout nodes live in flat arrays (`LayoutArena`) rather than heap-allocated widget trees, with O(log N) virtual scrolling for large lists.
- **No custom UI language**: Build UIs in Zig, via the C ABI ([`include/huey.h`](include/huey.h)), or from declarative JSON scenes.
- **Platform fit**: Supports Wayland layer-shell (`zwlr_layer_shell_v1`) and `xdg_shell`, Android `NativeActivity`, and round Wear OS screens (circular clip, curved scrolling, rotary crown, ambient mode).

More background is in [`docs/MANIFESTO_v2.2.md`](docs/MANIFESTO_v2.2.md) and [`SKILL.md`](SKILL.md).

## Quick Start

Requires **Zig 0.17.1** (and Android SDK/NDK for Android/Wear OS APKs).

```bash
# Run unit tests
zig build test

# Build and run the Wayland bar/launcher demo headlessly
zig build stratifi-demo && ./zig-out/bin/huey-stratifi --headless

# Regenerate showcase icons and logo
zig build gen-icons

# Build Android and Wear OS showcase APKs
./demos/android-showcase/build_apk.sh
./demos/wear-showcase/build_wear_apk.sh
```

## Layout

```text
├── build.zig / build.zig.zon   # Zig package ("huey" module, tests, demos, tools)
├── src/                        # Huey library and unit tests
├── demos/
│   ├── stratifi-bar/           # Wayland status bar & launcher demo
│   ├── android-showcase/       # Android showcase app
│   └── wear-showcase/          # Wear OS showcase app
├── tools/                      # Icon/logo generator
├── include/huey.h              # C ABI header
├── vendor/                     # Vendored C headers (sokol_gfx, stb_truetype)
└── docs/                       # Design notes
```

## License

Dual-licensed under either the **MIT License** ([`LICENSE-MIT`](LICENSE-MIT)) or the **Apache License, Version 2.0** ([`LICENSE-APACHE`](LICENSE-APACHE)), at your option.
