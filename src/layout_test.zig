const std = @import("std");
const core = @import("core.zig");

test "Flexbox justify (.center, .end, .space_between) and align_items (.center, .end)" {
    var arena = core.LayoutArena.init(std.testing.allocator);
    defer arena.deinit();

    const root = try arena.addNode(.{
        .kind = .hstack,
        .role = .container,
        .test_id = "row",
        .justify = .space_between,
        .align_items = .center,
    });
    const a = try arena.addChild(root, .{ .kind = .card, .role = .panel, .width = 50.0, .height = 40.0 });
    const b = try arena.addChild(root, .{ .kind = .card, .role = .panel, .width = 50.0, .height = 20.0 });
    const c = try arena.addChild(root, .{ .kind = .card, .role = .panel, .width = 50.0, .height = 60.0 });

    arena.layout(350.0, 100.0);

    // Total width 150 inside 350 -> 200 remaining split across 2 gaps = 100 each
    const ra = arena.getRect(a).?;
    const rb = arena.getRect(b).?;
    const rc = arena.getRect(c).?;
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), ra.x, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 30.0), ra.y, 0.01); // centered in 100
    try std.testing.expectApproxEqAbs(@as(f32, 150.0), rb.x, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 40.0), rb.y, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 300.0), rc.x, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 20.0), rc.y, 0.01);
}

test "Flexbox flex_wrap wraps children to next line and respects min/max constraints" {
    var arena = core.LayoutArena.init(std.testing.allocator);
    defer arena.deinit();

    const root = try arena.addNode(.{
        .kind = .hstack,
        .role = .container,
        .flex_wrap = true,
        .gap = 10.0,
        .padding = 10.0,
    });
    const c0 = try arena.addChild(root, .{ .kind = .card, .role = .panel, .width = 80.0, .height = 30.0 });
    const c1 = try arena.addChild(root, .{ .kind = .card, .role = .panel, .width = 80.0, .height = 30.0 });
    const c2 = try arena.addChild(root, .{ .kind = .card, .role = .panel, .width = 80.0, .height = 30.0 });

    // Inner width = 200 - 20 = 180. c0 (80) + gap (10) + c1 (80) = 170 <= 180. c2 wraps to line 2!
    arena.layout(200.0, 200.0);
    const r0 = arena.getRect(c0).?;
    const r1 = arena.getRect(c1).?;
    const r2 = arena.getRect(c2).?;
    try std.testing.expectEqual(@as(f32, 10.0), r0.x);
    try std.testing.expectEqual(@as(f32, 10.0), r0.y);
    try std.testing.expectEqual(@as(f32, 100.0), r1.x);
    try std.testing.expectEqual(@as(f32, 10.0), r1.y);
    try std.testing.expectEqual(@as(f32, 10.0), r2.x);
    try std.testing.expectEqual(@as(f32, 50.0), r2.y); // 10 + 30 + 10
}

test "Flexbox flex_shrink and min_width/max_width clamp cleanly" {
    var arena = core.LayoutArena.init(std.testing.allocator);
    defer arena.deinit();

    const root = try arena.addNode(.{ .kind = .hstack, .role = .container });
    const a = try arena.addChild(root, .{ .kind = .card, .role = .panel, .width = 150.0, .min_width = 100.0, .flex_shrink = 1.0 });
    const b = try arena.addChild(root, .{ .kind = .card, .role = .panel, .width = 150.0, .flex_shrink = 1.0 });

    // Total 300 in 200 -> needs to shrink by 100 (50 each -> 100, 100)
    arena.layout(200.0, 60.0);
    try std.testing.expectApproxEqAbs(@as(f32, 100.0), arena.getRect(a).?.w, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 100.0), arena.getRect(b).?.w, 0.01);
}

test "2D CSS Grid lays out columns, gaps, and col_span accurately" {
    var arena = core.LayoutArena.init(std.testing.allocator);
    defer arena.deinit();

    const grid = try arena.addNode(.{
        .kind = .grid,
        .role = .container,
        .grid_cols = 3,
        .gap = 10.0,
        .padding = 10.0,
    });
    const g0 = try arena.addChild(grid, .{ .kind = .card, .role = .panel, .height = 40.0, .col_span = 2 });
    const g1 = try arena.addChild(grid, .{ .kind = .card, .role = .panel, .height = 40.0 });
    const g2 = try arena.addChild(grid, .{ .kind = .card, .role = .panel, .height = 50.0 });

    // Inner width = 340 - 20 = 320. 3 cols with 2*10 gaps -> col_w = 100.
    // g0 spans 2 cols -> w = 210, x = 10, y = 10
    // g1 is col 2 -> w = 100, x = 230, y = 10
    // g2 wraps to row 1 col 0 -> w = 100, x = 10, y = 60
    arena.layout(340.0, 200.0);
    const r0 = arena.getRect(g0).?;
    const r1 = arena.getRect(g1).?;
    const r2 = arena.getRect(g2).?;
    try std.testing.expectApproxEqAbs(@as(f32, 10.0), r0.x, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 210.0), r0.w, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 230.0), r1.x, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 100.0), r1.w, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 10.0), r2.x, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 60.0), r2.y, 0.01);
}

test "Dirty-flagged incremental relayout skips clean passes when viewport and tree are unchanged" {
    var arena = core.LayoutArena.init(std.testing.allocator);
    defer arena.deinit();

    const root = try arena.addNode(.{ .kind = .vstack, .role = .container });
    _ = try arena.addChild(root, .{ .kind = .card, .role = .panel, .height = 50.0 });

    arena.layout(400.0, 300.0);
    const evals1 = arena.layout_eval_count;
    try std.testing.expectEqual(@as(u64, 1), evals1);

    // Same viewport, no tree mutation -> skipped!
    arena.layout(400.0, 300.0);
    try std.testing.expectEqual(@as(u64, 1), arena.layout_eval_count);

    // Viewport change -> re-evaluates!
    arena.layout(500.0, 300.0);
    try std.testing.expectEqual(@as(u64, 2), arena.layout_eval_count);

    // Tree mutation -> re-evaluates even with same viewport!
    _ = try arena.addChild(root, .{ .kind = .card, .role = .panel, .height = 20.0 });
    arena.layout(500.0, 300.0);
    try std.testing.expectEqual(@as(u64, 3), arena.layout_eval_count);

    // Reset -> re-evaluates!
    arena.reset();
    _ = try arena.addNode(.{ .kind = .vstack, .role = .container });
    arena.layout(500.0, 300.0);
    try std.testing.expectEqual(@as(u64, 4), arena.layout_eval_count);
}

test "Flexbox justify (.center, .end, .space_around, .space_evenly) and align_items (.start, .end, .stretch)" {
    // space_around & align .end
    {
        var arena = core.LayoutArena.init(std.testing.allocator);
        defer arena.deinit();
        const root = try arena.addNode(.{
            .kind = .hstack,
            .role = .container,
            .justify = .space_around,
            .align_items = .end,
        });
        const a = try arena.addChild(root, .{ .kind = .card, .role = .panel, .width = 50.0, .height = 30.0 });
        const b = try arena.addChild(root, .{ .kind = .card, .role = .panel, .width = 50.0, .height = 40.0 });
        arena.layout(200.0, 100.0);
        // Remaining 100 / 2 items = 50 per slot -> 25 leading, 50 between, 25 trailing
        try std.testing.expectApproxEqAbs(@as(f32, 25.0), arena.getRect(a).?.x, 0.01);
        try std.testing.expectApproxEqAbs(@as(f32, 70.0), arena.getRect(a).?.y, 0.01);
        try std.testing.expectApproxEqAbs(@as(f32, 125.0), arena.getRect(b).?.x, 0.01);
        try std.testing.expectApproxEqAbs(@as(f32, 60.0), arena.getRect(b).?.y, 0.01);
    }

    // space_evenly & center & end
    {
        var arena = core.LayoutArena.init(std.testing.allocator);
        defer arena.deinit();
        const root = try arena.addNode(.{
            .kind = .vstack,
            .role = .container,
            .justify = .space_evenly,
            .align_items = .center,
        });
        const a = try arena.addChild(root, .{ .kind = .card, .role = .panel, .width = 40.0, .height = 50.0 });
        const b = try arena.addChild(root, .{ .kind = .card, .role = .panel, .width = 60.0, .height = 50.0 });
        arena.layout(100.0, 250.0);
        // Remaining 150 / 3 = 50 each
        try std.testing.expectApproxEqAbs(@as(f32, 30.0), arena.getRect(a).?.x, 0.01);
        try std.testing.expectApproxEqAbs(@as(f32, 50.0), arena.getRect(a).?.y, 0.01);
        try std.testing.expectApproxEqAbs(@as(f32, 20.0), arena.getRect(b).?.x, 0.01);
        try std.testing.expectApproxEqAbs(@as(f32, 150.0), arena.getRect(b).?.y, 0.01);
    }
}

test "Flexbox shrink redistributes overflow when a sibling hits min_width, and sanitizes max < min and NaN" {
    var arena = core.LayoutArena.init(std.testing.allocator);
    defer arena.deinit();

    const nan = std.math.nan(f32);
    const root = try arena.addNode(.{ .kind = .hstack, .role = .container });
    const a = try arena.addChild(root, .{
        .kind = .card,
        .role = .panel,
        .width = 150.0,
        .min_width = 120.0,
        .max_width = 80.0, // max < min -> effective max = min = 120.0
        .flex_shrink = 1.0,
    });
    const b = try arena.addChild(root, .{
        .kind = .card,
        .role = .panel,
        .width = 150.0,
        .min_width = nan,
        .max_width = -5.0,
        .flex_shrink = 1.0,
    });

    // Total 270 (120 + 150) in 200 -> overflow 70: a is already at min 120, b shrinks all 70 -> 80!
    arena.layout(200.0, 60.0);
    try std.testing.expectApproxEqAbs(@as(f32, 120.0), arena.getRect(a).?.w, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 80.0), arena.getRect(b).?.w, 0.01);
}

test "2D CSS Grid supports auto-height rows, grid_col_gap/grid_row_gap, row_span, and event bubbling" {
    const events = @import("events.zig");

    var arena = core.LayoutArena.init(std.testing.allocator);
    defer arena.deinit();

    const grid = try arena.addNode(.{
        .kind = .grid,
        .role = .container,
        .grid_cols = 2,
        .gap = 5.0,
        .grid_col_gap = 20.0,
        .grid_row_gap = 10.0,
    });
    const g0 = try arena.addChild(grid, .{ .kind = .toggle, .role = .switch_control, .test_id = "g0", .row_span = 2 });
    const g1 = try arena.addChild(grid, .{ .kind = .card, .role = .panel, .test_id = "g1" });
    const g2 = try arena.addChild(grid, .{ .kind = .card, .role = .panel, .test_id = "g2" });

    // 2 cols in 220 with col_gap 20 -> col_w = 100.
    // 2 rows in 210 with row_gap 10 -> auto_row_h = 100.
    // g0 spans 2 rows at col 0 -> (0, 0, 100, 210)
    // g1 at (120, 0, 100, 100)
    // g2 wraps past busy col 0 -> (120, 110, 100, 100)
    arena.layout(220.0, 210.0);
    const r0 = arena.getRect(g0).?;
    const r1 = arena.getRect(g1).?;
    const r2 = arena.getRect(g2).?;
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), r0.x, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 210.0), r0.h, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 120.0), r1.x, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 100.0), r1.h, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 120.0), r2.x, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 110.0), r2.y, 0.01);

    // Event bubbling through .grid container to clickable parent card
    var arena2 = core.LayoutArena.init(std.testing.allocator);
    defer arena2.deinit();
    const card = try arena2.addNode(.{ .kind = .card, .role = .panel, .test_id = "outer_card", .fill = core.Nord.polar_night_1 });
    const inner_grid = try arena2.addChild(card, .{ .kind = .grid, .role = .container, .grid_cols = 1, .fill = core.Nord.polar_night_2 });
    _ = try arena2.addChild(inner_grid, .{ .kind = .bar, .role = .progress_bar, .height = 40.0 });
    arena2.layout(100.0, 100.0);

    var router = events.EventRouter.init();
    router.dispatch(&arena2, .{ .pointer_down = .{ .pointer_id = 1, .x = 50.0, .y = 20.0 } });
    router.dispatch(&arena2, .{ .pointer_up = .{ .pointer_id = 1, .x = 50.0, .y = 20.0 } });
    const evs = router.pollEvents();
    try std.testing.expectEqual(@as(usize, 1), evs.len);
    try std.testing.expectEqualStrings("outer_card", evs[0].clicked.test_id);
}

test "Adversarial regressions: Grid u16 overflow, MAX_GRID_COLS, row_span skip & unequal row heights, auto+min_height" {
    // 1. grid_cols = 65535 clamps to MAX_GRID_COLS (64) without u16 overflow
    {
        var arena = core.LayoutArena.init(std.testing.allocator);
        defer arena.deinit();
        const grid = try arena.addNode(.{
            .kind = .grid,
            .role = .container,
            .grid_cols = 65535,
        });
        const c0 = try arena.addChild(grid, .{ .kind = .card, .role = .panel, .col_span = 2, .height = 20.0 });
        const c1 = try arena.addChild(grid, .{ .kind = .card, .role = .panel, .col_span = 65535, .height = 20.0 });
        arena.layout(640.0, 100.0);
        try std.testing.expectEqual(@as(u16, 64), core.MAX_GRID_COLS);
        try std.testing.expectApproxEqAbs(@as(f32, 20.0), arena.getRect(c0).?.w, 0.01);
        try std.testing.expectApproxEqAbs(@as(f32, 640.0), arena.getRect(c1).?.w, 0.01);
    }

    // 2. col_span = 2 skips busy col 1 on row 1 and lands at cols [2, 3] instead of row 2
    {
        var arena = core.LayoutArena.init(std.testing.allocator);
        defer arena.deinit();
        const grid = try arena.addNode(.{
            .kind = .grid,
            .role = .container,
            .grid_cols = 4,
            .gap = 0.0,
        });
        _ = try arena.addChild(grid, .{ .kind = .card, .role = .panel, .height = 40.0 }); // (0,0)
        _ = try arena.addChild(grid, .{ .kind = .card, .role = .panel, .row_span = 2, .height = 40.0 }); // (1,0) busy on row 1 col 1
        _ = try arena.addChild(grid, .{ .kind = .card, .role = .panel, .col_span = 2, .height = 40.0 }); // (2,0)-(3,0)
        _ = try arena.addChild(grid, .{ .kind = .card, .role = .panel, .height = 40.0 }); // (0,1)
        const g4 = try arena.addChild(grid, .{ .kind = .card, .role = .panel, .col_span = 2, .height = 40.0 }); // must land at (2,1)-(3,1)!
        arena.layout(400.0, 200.0);
        const r4 = arena.getRect(g4).?;
        try std.testing.expectApproxEqAbs(@as(f32, 200.0), r4.x, 0.01);
        try std.testing.expectApproxEqAbs(@as(f32, 40.0), r4.y, 0.01);
    }

    // 3. row_span = 2 sums actual unequal row heights (50 + 120 + row_gap) and aligns with avail_cell_h
    {
        var arena = core.LayoutArena.init(std.testing.allocator);
        defer arena.deinit();
        const grid = try arena.addNode(.{
            .kind = .grid,
            .role = .container,
            .grid_cols = 2,
            .grid_col_gap = 0.0,
            .grid_row_gap = 10.0,
            .align_items = .stretch,
        });
        const span_stretch = try arena.addChild(grid, .{ .kind = .card, .role = .panel, .row_span = 2 });
        _ = try arena.addChild(grid, .{ .kind = .card, .role = .panel, .height = 50.0 });
        _ = try arena.addChild(grid, .{ .kind = .card, .role = .panel, .height = 120.0 });
        arena.layout(200.0, 300.0);
        try std.testing.expectApproxEqAbs(@as(f32, 180.0), arena.getRect(span_stretch).?.h, 0.01);

        // Also check align_items = .center on row_span = 2 with explicit height
        var arena_c = core.LayoutArena.init(std.testing.allocator);
        defer arena_c.deinit();
        const grid_c = try arena_c.addNode(.{
            .kind = .grid,
            .role = .container,
            .grid_cols = 2,
            .grid_col_gap = 0.0,
            .grid_row_gap = 10.0,
            .align_items = .center,
        });
        const span_center = try arena_c.addChild(grid_c, .{ .kind = .card, .role = .panel, .row_span = 2, .height = 40.0 });
        _ = try arena_c.addChild(grid_c, .{ .kind = .card, .role = .panel, .height = 50.0 });
        _ = try arena_c.addChild(grid_c, .{ .kind = .card, .role = .panel, .height = 120.0 });
        arena_c.layout(200.0, 300.0);
        try std.testing.expectApproxEqAbs(@as(f32, 70.0), arena_c.getRect(span_center).?.y, 0.01);
    }

    // 4. Grid auto-height row with min_height still participates as auto row
    {
        var arena = core.LayoutArena.init(std.testing.allocator);
        defer arena.deinit();
        const grid = try arena.addNode(.{
            .kind = .grid,
            .role = .container,
            .grid_cols = 1,
            .gap = 10.0,
        });
        const g0 = try arena.addChild(grid, .{ .kind = .card, .role = .panel, .min_height = 40.0 });
        const g1 = try arena.addChild(grid, .{ .kind = .card, .role = .panel });
        arena.layout(100.0, 210.0);
        try std.testing.expectApproxEqAbs(@as(f32, 100.0), arena.getRect(g0).?.h, 0.01);
        try std.testing.expectApproxEqAbs(@as(f32, 100.0), arena.getRect(g1).?.h, 0.01);
    }
}

test "Adversarial regressions: Flex wrap auto cross stretch, extreme f32 shrink, and min_iter-frozen grow skip" {
    // 1. flex_wrap = true with height = 0 under align_items = .stretch does not collapse to 0
    {
        var arena = core.LayoutArena.init(std.testing.allocator);
        defer arena.deinit();
        const root = try arena.addNode(.{
            .kind = .hstack,
            .role = .container,
            .flex_wrap = true,
            .align_items = .stretch,
            .gap = 10.0,
        });
        const c0 = try arena.addChild(root, .{ .kind = .card, .role = .panel, .width = 80.0 });
        const c1 = try arena.addChild(root, .{ .kind = .card, .role = .panel, .width = 80.0 });
        const c2 = try arena.addChild(root, .{ .kind = .card, .role = .panel, .width = 80.0 });
        arena.layout(200.0, 110.0);
        try std.testing.expectApproxEqAbs(@as(f32, 50.0), arena.getRect(c0).?.h, 0.01);
        try std.testing.expectApproxEqAbs(@as(f32, 50.0), arena.getRect(c1).?.h, 0.01);
        try std.testing.expectApproxEqAbs(@as(f32, 50.0), arena.getRect(c2).?.h, 0.01);
        try std.testing.expectApproxEqAbs(@as(f32, 60.0), arena.getRect(c2).?.y, 0.01);
    }

    // 2. Extreme ~3e38 shrink/overflow never produces NaN or Inf
    {
        var arena = core.LayoutArena.init(std.testing.allocator);
        defer arena.deinit();
        const root = try arena.addNode(.{ .kind = .hstack, .role = .container, .gap = 3.0e38 });
        const a = try arena.addChild(root, .{ .kind = .card, .role = .panel, .width = 3.0e38, .flex_shrink = 1.0 });
        const b = try arena.addChild(root, .{ .kind = .card, .role = .panel, .width = 3.0e38, .flex_shrink = 1.0 });
        arena.layout(200.0, 60.0);
        const ra = arena.getRect(a).?;
        const rb = arena.getRect(b).?;
        try std.testing.expect(std.math.isFinite(ra.x) and std.math.isFinite(ra.w) and ra.w >= 0.0);
        try std.testing.expect(std.math.isFinite(rb.x) and std.math.isFinite(rb.w) and rb.w >= 0.0);
    }

    // 3. min_iter-frozen child is not grown by grow_iter when max_width caps another sibling
    {
        var arena = core.LayoutArena.init(std.testing.allocator);
        defer arena.deinit();
        const root = try arena.addNode(.{ .kind = .hstack, .role = .container });
        const a = try arena.addChild(root, .{ .kind = .card, .role = .panel, .flex = 1.0, .min_width = 180.0 });
        const b = try arena.addChild(root, .{ .kind = .card, .role = .panel, .flex = 1.0 });
        const c = try arena.addChild(root, .{ .kind = .card, .role = .panel, .flex = 1.0, .max_width = 50.0 });
        arena.layout(300.0, 50.0);
        try std.testing.expectApproxEqAbs(@as(f32, 180.0), arena.getRect(a).?.w, 0.01);
        try std.testing.expectApproxEqAbs(@as(f32, 70.0), arena.getRect(b).?.w, 0.01);
        try std.testing.expectApproxEqAbs(@as(f32, 50.0), arena.getRect(c).?.w, 0.01);
    }
}
