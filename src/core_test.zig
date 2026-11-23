const std = @import("std");
const core = @import("core.zig");

test "QuadInstance is 96-byte ABI aligned for UberQuad shader" {
    try std.testing.expectEqual(@as(usize, 96), @sizeOf(core.QuadInstance));
}

test "physical pixel snapping preserves crisp edges at fractional and 2x DPI" {
    const r = core.Rect{ .x = 10.3, .y = 20.4, .w = 100.2, .h = 44.3 };
    const snapped_2x = core.snapRectToPhysical(r, 2.0);
    // x0 = round(20.6) = 21, y0 = round(40.8) = 41
    // x1 = round(221.0) = 221, y1 = round(129.4) = 129
    try std.testing.expectEqual(@as(f32, 21.0), snapped_2x.x);
    try std.testing.expectEqual(@as(f32, 41.0), snapped_2x.y);
    try std.testing.expectEqual(@as(f32, 200.0), snapped_2x.w);
    try std.testing.expectEqual(@as(f32, 88.0), snapped_2x.h);

    const snapped_125 = core.snapRectToPhysical(.{ .x = 1.0, .y = 1.0, .w = 10.0, .h = 10.0 }, 1.25);
    try std.testing.expectEqual(@as(f32, 1.0), snapped_125.x);
    try std.testing.expectEqual(@as(f32, 13.0), snapped_125.w); // round(11*1.25)=14, 14-1=13
}

test "Oklab to sRGB produces valid clamped Nord-like colors" {
    const bg = core.oklabToSrgb(0.28, -0.01, -0.02, 1.0);
    for (bg) |c| {
        try std.testing.expect(c >= 0.0 and c <= 1.0);
    }
    try std.testing.expectEqual(@as(f32, 1.0), bg[3]);
}

test "SoA arena layout, zero-alloc quad emission, hit-testing, and zero-tick sleep" {
    var arena = core.LayoutArena.init(std.testing.allocator);
    defer arena.deinit();

    const root = try arena.addNode(.{
        .kind = .vstack,
        .role = .container,
        .test_id = "root",
        .padding = 16.0,
        .gap = 12.0,
        .fill = core.Nord.polar_night_0,
    });
    const toggle = try arena.addChild(root, .{
        .kind = .toggle,
        .role = .switch_control,
        .test_id = "settings.gpu_cache",
        .height = 56.0,
        .corner_radius = 12.0,
        .border_width = 1.5,
        .fill = core.Nord.polar_night_1,
        .border = core.Nord.frost_2,
        .checked = false,
    });
    const slider = try arena.addChild(root, .{
        .kind = .slider,
        .role = .slider,
        .test_id = "settings.threads",
        .height = 56.0,
        .corner_radius = 12.0,
        .fill = core.Nord.polar_night_1,
        .slider_val = 0.25,
    });

    try std.testing.expect(arena.needsRedraw());
    arena.layout(768.0, 1024.0);

    const t_rect = arena.getRect(toggle).?;
    try std.testing.expectEqual(@as(f32, 16.0), t_rect.x);
    try std.testing.expectEqual(@as(f32, 16.0), t_rect.y);
    try std.testing.expectEqual(@as(f32, 736.0), t_rect.w);
    try std.testing.expectEqual(@as(f32, 56.0), t_rect.h);

    const s_rect = arena.getRect(slider).?;
    try std.testing.expectEqual(@as(f32, 16.0), s_rect.x);
    try std.testing.expectEqual(@as(f32, 84.0), s_rect.y); // 16 + 56 + 12

    // Zero-allocation emission into stack buffer
    var quad_buf: [64]core.QuadInstance = undefined;
    const count = arena.emitQuads(&quad_buf, 2.0);
    try std.testing.expect(count >= 4); // root + toggle bg + toggle knob + slider bg + slider fill

    // Zero-tick sleep: once consumed, idle until event
    arena.consumeRedraw();
    try std.testing.expect(!arena.needsRedraw());

    // Tap on toggle in logical coordinates
    const hit = arena.handlePointerDown(100.0, 40.0);
    try std.testing.expectEqual(toggle, hit.?);
    try std.testing.expect(arena.isChecked(toggle).?);
    try std.testing.expect(arena.needsRedraw());

    // Drag on slider in logical coordinates (midpoint of 16..752 is 384 -> ~0.5)
    arena.consumeRedraw();
    _ = arena.handlePointerDown(384.0, 100.0);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), arena.getSliderValue(slider).?, 0.02);
    try std.testing.expect(arena.needsRedraw());

    // Semantic tree dump for Agent-Native inspection
    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    try arena.dumpSemanticTree(&aw.writer);
    const dumped = aw.written();
    try std.testing.expect(std.mem.indexOf(u8, dumped, "settings.gpu_cache") != null);
    try std.testing.expect(std.mem.indexOf(u8, dumped, "checked=true") != null);
    try std.testing.expect(std.mem.indexOf(u8, dumped, "settings.threads") != null);
}

test "emitQuads clamps cleanly when output buffer is smaller than scene" {
    var arena = core.LayoutArena.init(std.testing.allocator);
    defer arena.deinit();
    const root = try arena.addNode(.{ .kind = .vstack, .role = .container, .test_id = "r" });
    _ = try arena.addChild(root, .{ .kind = .toggle, .role = .switch_control, .height = 48.0 });
    arena.layout(400.0, 400.0);

    var tiny: [2]core.QuadInstance = undefined;
    const count = arena.emitQuads(&tiny, 2.0);
    try std.testing.expectEqual(@as(usize, 2), count);
}

test "buildDemoScene emits >= 40 UberQuads cleanly and supports slider drag" {
    var arena = core.LayoutArena.init(std.testing.allocator);
    defer arena.deinit();
    try core.buildDemoScene(&arena);
    arena.layout(768.0, 1024.0);

    var quad_buf: [256]core.QuadInstance = undefined;
    const count = arena.emitQuads(&quad_buf, 2.0);
    try std.testing.expect(count >= 40);
    try std.testing.expect(count <= 256);

    // Drag first slider around y ~ 390
    arena.consumeRedraw();
    const hit = arena.handlePointerDown(200.0, 390.0);
    try std.testing.expect(hit != null);
    const val_before = arena.getSliderValue(hit.?).?;
    _ = arena.handlePointerMove(600.0, 390.0);
    const val_after = arena.getSliderValue(hit.?).?;
    try std.testing.expect(val_after > val_before);
    arena.handlePointerUp();

    // Semantic tree uses distinct test_ids for status cards, labels, and bars
    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    try arena.dumpSemanticTree(&aw.writer);
    const dumped = aw.written();
    try std.testing.expect(std.mem.indexOf(u8, dumped, "status.cpu_idle.card") != null);
    try std.testing.expect(std.mem.indexOf(u8, dumped, "status.cpu_idle.label") != null);
    try std.testing.expect(std.mem.indexOf(u8, dumped, "status.cpu_idle.bar") != null);
}

test "stale NodeId is rejected after arena reset" {
    var arena = core.LayoutArena.init(std.testing.allocator);
    defer arena.deinit();

    const root = try arena.addNode(.{ .kind = .vstack, .role = .container, .test_id = "r1" });
    const old_toggle = try arena.addChild(root, .{ .kind = .toggle, .role = .switch_control, .height = 48.0, .checked = true });
    arena.layout(400.0, 400.0);
    try std.testing.expectEqual(true, arena.isChecked(old_toggle).?);

    arena.reset();
    const new_root = try arena.addNode(.{ .kind = .vstack, .role = .container, .test_id = "r2" });
    const new_toggle = try arena.addChild(new_root, .{ .kind = .toggle, .role = .switch_control, .height = 48.0, .checked = false });
    arena.layout(400.0, 400.0);

    try std.testing.expectEqual(@as(?core.Rect, null), arena.getRect(old_toggle));
    try std.testing.expectEqual(@as(?bool, null), arena.isChecked(old_toggle));
    try std.testing.expectEqual(@as(?f32, null), arena.getSliderValue(old_toggle));
    try std.testing.expectError(error.InvalidNodeId, arena.addChild(old_toggle, .{ .kind = .bar }));
    try std.testing.expectEqual(false, arena.isChecked(new_toggle).?);
}

test "slider hit and drag math matches visual track inset" {
    var arena = core.LayoutArena.init(std.testing.allocator);
    defer arena.deinit();

    const root = try arena.addNode(.{ .kind = .vstack, .role = .container, .padding = 16.0 });
    const slider = try arena.addChild(root, .{
        .kind = .slider,
        .role = .slider,
        .height = 56.0,
        .slider_val = 0.5,
    });
    arena.layout(768.0, 400.0);

    // rect is x=16, w=736 -> track inset=16 -> track_x=32, track_w=704, track_end=736
    _ = arena.handlePointerDown(32.0, 40.0);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), arena.getSliderValue(slider).?, 0.001);

    _ = arena.handlePointerMove(736.0, 40.0);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), arena.getSliderValue(slider).?, 0.001);

    _ = arena.handlePointerMove(384.0, 40.0);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), arena.getSliderValue(slider).?, 0.001);
    arena.handlePointerUp();
}

test "NaN, non-positive scale_factor, and excessive padding are sanitized cleanly" {
    var arena = core.LayoutArena.init(std.testing.allocator);
    defer arena.deinit();

    const nan = std.math.nan(f32);
    const root = try arena.addNode(.{
        .kind = .vstack,
        .role = .container,
        .padding = 100.0,
        .gap = nan,
        .fill = core.Nord.polar_night_0,
    });
    const child = try arena.addChild(root, .{
        .kind = .toggle,
        .role = .switch_control,
        .height = 48.0,
        .corner_radius = -10.0,
        .border_width = -5.0,
        .shadow_blur = -3.0,
        .fill = core.Nord.polar_night_1,
    });
    // padding*2 (200) > viewport width (80)
    arena.layout(80.0, 300.0);

    const c_rect = arena.getRect(child).?;
    try std.testing.expectEqual(@as(f32, 40.0), c_rect.x);
    try std.testing.expectEqual(@as(f32, 0.0), c_rect.w);

    var quad_buf: [32]core.QuadInstance = undefined;
    // Non-finite or <= 0 scale_factor returns 0 quads without NaN
    try std.testing.expectEqual(@as(usize, 0), arena.emitQuads(&quad_buf, nan));
    try std.testing.expectEqual(@as(usize, 0), arena.emitQuads(&quad_buf, 0.0));
    try std.testing.expectEqual(@as(usize, 0), arena.emitQuads(&quad_buf, -2.0));

    // Valid scale_factor skips zero-width child quads and clamps negative params to >= 0
    const count = arena.emitQuads(&quad_buf, 2.0);
    try std.testing.expectEqual(@as(usize, 1), count); // only root emitted; zero-width child skipped
    for (quad_buf[0..count]) |q| {
        try std.testing.expect(q.pos_size[2] > 0.0 and q.pos_size[3] > 0.0);
        try std.testing.expect(q.params[0] >= 0.0 and q.params[1] >= 0.0 and q.params[2] >= 0.0);
    }
}

test "reverse-DFS hit testing respects opaque panel occlusion and zero-area rejection" {
    var arena = core.LayoutArena.init(std.testing.allocator);
    defer arena.deinit();

    const root = try arena.addNode(.{
        .kind = .zstack,
        .role = .container,
        .fill = core.Nord.polar_night_0,
    });
    const under_toggle = try arena.addChild(root, .{
        .kind = .toggle,
        .role = .switch_control,
        .checked = false,
        .fill = core.Nord.polar_night_1,
    });
    const zero_wrap = try arena.addChild(root, .{
        .kind = .vstack,
        .role = .container,
        .padding = 200.0,
    });
    // Zero-area toggle inside zero_wrap (rect is 100,100,0,0) should never be hit
    const zero_toggle = try arena.addChild(zero_wrap, .{
        .kind = .toggle,
        .role = .switch_control,
        .height = 48.0,
    });
    // Opaque panel covering the same area occludes under_toggle
    _ = try arena.addChild(root, .{
        .kind = .card,
        .role = .panel,
        .fill = core.Nord.polar_night_2,
    });

    arena.layout(200.0, 200.0);
    const z_rect = arena.getRect(zero_toggle).?;
    try std.testing.expectEqual(@as(f32, 0.0), z_rect.w);
    const hit = arena.handlePointerDown(100.0, 100.0);
    try std.testing.expectEqual(@as(?core.NodeId, null), hit);
    try std.testing.expectEqual(false, arena.isChecked(under_toggle).?);
    try std.testing.expectEqual(false, arena.isChecked(zero_toggle).?);
}

test "narrow toggle and slider sub-elements stay within widget rect bounds" {
    var arena = core.LayoutArena.init(std.testing.allocator);
    defer arena.deinit();

    const root = try arena.addNode(.{ .kind = .vstack, .role = .container });
    const t = try arena.addChild(root, .{
        .kind = .toggle,
        .role = .switch_control,
        .height = 48.0,
        .fill = core.Nord.polar_night_1,
    });
    const s = try arena.addChild(root, .{
        .kind = .slider,
        .role = .slider,
        .height = 48.0,
        .fill = core.Nord.polar_night_1,
        .slider_val = 0.5,
    });
    arena.layout(24.0, 120.0);

    var quad_buf: [32]core.QuadInstance = undefined;
    const count = arena.emitQuads(&quad_buf, 1.0);
    try std.testing.expect(count >= 2);

    const t_rect = arena.getRect(t).?;
    const s_rect = arena.getRect(s).?;
    const min_x = @min(t_rect.x, s_rect.x);
    const max_x = @max(t_rect.x + t_rect.w, s_rect.x + s_rect.w);

    for (quad_buf[0..count]) |q| {
        try std.testing.expect(q.pos_size[0] >= min_x);
        try std.testing.expect(q.pos_size[0] + q.pos_size[2] <= max_x);
    }
}
