# Huey

**Huey** (*Hue + UI*) is a data-oriented, single-pass UberQuad GUI toolkit written in **Zig 0.16** for **Linux Wayland**, **Android**, and **Wear OS**.

Designed around zero-tick idle sleep (`0%` idle CPU), flat Structure-of-Arrays (SoA) layout, perceptual **Oklab** theming, and exact IEC 61966-2-1 linear-space SDF rendering — delivering locked **60 Hz** UIs in **~330 KB** native APKs on constrained hardware (tested live on a 2014 Nexus 9 and a OnePlus Watch 3).

---

## Highlights

- **Single-Pass UberQuad SDF Renderer (`src/renderer.zig`)**: Instanced rounded rectangles, anti-aliased borders, soft shadows, per-instance scissor clipping, optional hardware-AA circular viewport masking (`u_round_clip` for round Wear OS OLEDs), and R8 glyph atlas sampling (`src/glyph_atlas.zig`) in one draw call via `sokol_gfx` (GLES 3.1).
- **Zero-Tick Idle Sleep**: Event-driven `ALooper` / `AChoreographer` (Android/Wear OS) and `epoll` (Wayland) loops sleep indefinitely when settled (`0%` idle CPU) and wake at VSync only during active scrolling or spring animations.
- **Perceptual Oklab Theming & OS Theme Hooks (`src/tokens.zig`, `src/theme.zig`)**: Built-in WCAG-verified presets (`nord_dark`, `nord_light`, `oled_dark`, `high_contrast_dark`, `high_contrast_light`), gamut-preserving Oklab dynamic seed generation, zero-copy `mmap` hot-reload, and Android/Linux OS dark-mode detection.
- **Analytical Spring & Tween Animation Engine (`src/animation.zig`)**: Unconditionally stable closed-form damped harmonic oscillator (`SpringState`), easing tweens, perceptual `lerpColorOklab`, and zero-allocation `AnimationPool` with `reduced_motion` support.
- **Zero-Alloc SoA Layout & 1M+ Row Virtual Scroll (`src/core.zig`, `src/virtual_scroll.zig`)**: Flexbox + 2D CSS Grid, dirty-flagged incremental relayout, O(log N) bottom-up segment-tree `SumTree`, and critically damped inertial fling scrolling.
- **Pure-Zig Wayland Client (`src/wayland.zig`, `src/overlay.zig`, `src/multi_window.zig`)**: Zero C Wayland headers required — speaks wire protocol directly over `AF_UNIX` with `zwlr_layer_shell_v1`, `xdg_shell` / `xdg_positioner`, `wp_fractional_scale_v1`, and mixed-DPI multi-monitor hotplug.
- **Wear OS Native Support (`src/wearos.zig`, `src/hold_confirm.zig`)**: Round inscribed-square safe insets, rigid per-card curved edge scroll scaling, rotating crown (`AMOTION_EVENT_AXIS_SCROLL`), OLED ambient burn-in-safe transform, and a 360° perimeter firework hold-to-confirm control.
- **Composable Widgets & Platform Bridges (`src/widgets/`, `src/android_platform.zig`)**: `TextInput` / `TextArea` / `InputOtp` (UAX #29 graphemes + IME), `Button` (with spring press shape morph), `Checkbox`, `RadioGroup`, spring `Switch`, `ToggleGroup`, `Badge`, `Progress`, `Spinner`, `Skeleton`, `Alert`, `ToastQueue`, procedural SDF icons, and Android Soft Keyboard / JNI Vibrator / `KEEP_SCREEN_ON`.
- **Deterministic Headless Testing & Thin C ABI (`src/headless.zig`, `include/huey.h`)**: Pure-Zig CPU UberQuad rasterizer, PNG output, automatic layout & Oklab contrast lints, declarative JSON scene loading (`src/declarative.zig`), and a `-fshort-enums`-safe C ABI.

---

## Quick Start

Requires **Zig 0.16.0** (and Android SDK/NDK 21+ for Android/Wear OS APKs).

```bash
# Run all 35 host unit test suites
zig build test

# Build & run the Wayland status bar / command-palette prototype (headless check)
zig build bloxwm-demo
./zig-out/bin/huey-bloxwm --headless

# Build the Android tablet showcase APK (arm64-v8a, ~350 KB)
./build_apk.sh

# Build the Wear OS round OLED showcase APK (armeabi-v7a, ~340 KB)
./build_wear_apk.sh
```

---

## Documentation

- [`SKILL.md`](SKILL.md) — Flat-API cookbook & agentic usage guide
- [`docs/MANIFESTO_v2.2.md`](docs/MANIFESTO_v2.2.md) — Architecture & design philosophy
- [`include/huey.h`](include/huey.h) — Flat C ABI header

---

## License

Dual-licensed under either of:

- **MIT License** ([`LICENSE-MIT`](LICENSE-MIT))
- **Apache License, Version 2.0** ([`LICENSE-APACHE`](LICENSE-APACHE))

at your option.
