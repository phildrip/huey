const std = @import("std");
const vs = @import("virtual_scroll.zig");
const core = @import("core.zig");

test "SumTree resolves visible viewport over 1,000,000 variable-height rows in sub-millisecond time" {
    const N: usize = 1_000_000;
    var tree = try vs.SumTree.initUniform(std.testing.allocator, N, 48.0);
    defer tree.deinit();

    try std.testing.expectApproxEqAbs(@as(f64, 48_000_000.0), tree.totalHeight(), 0.01);

    // Mutate several rows to variable heights in O(log N)
    tree.setRowHeight(0, 100.0);
    tree.setRowHeight(500_000, 120.0);
    tree.setRowHeight(500_001, 24.0);
    try std.testing.expectApproxEqAbs(@as(f64, 48_000_000.0 + 52.0 + 72.0 - 24.0), tree.totalHeight(), 0.01);

    // Query middle of 1M rows
    const y_mid = tree.prefixSum(500_000);
    const vis = tree.visibleRange(y_mid, 300.0);
    try std.testing.expectEqual(@as(usize, 500_000), vis.first_idx);
    try std.testing.expect(vis.end_idx > 500_001 and vis.end_idx <= 500_010);
    try std.testing.expectApproxEqAbs(y_mid, vis.first_y_offset, 0.01);

    // Query past end returns empty range safely
    const past = tree.visibleRange(99_000_000.0, 300.0);
    try std.testing.expectEqual(past.first_idx, past.end_idx);
}

test "InertialScroller handles drag, fling decay, edge bounce-back, and settles to zero-tick sleep" {
    var scroller = vs.InertialScroller.init(1000.0); // max_scroll = 1000dp
    try std.testing.expect(!scroller.isAnimating());

    // Drag upward (scrolls down)
    scroller.beginDrag(500.0, 0.0);
    scroller.updateDrag(450.0, 0.016);
    scroller.updateDrag(380.0, 0.032);
    scroller.endDrag();
    try std.testing.expect(scroller.offset > 100.0);
    try std.testing.expect(scroller.isAnimating());

    // Step 60Hz frames until settled
    var steps: usize = 0;
    while (scroller.isAnimating() and steps < 600) : (steps += 1) {
        _ = scroller.step(1.0 / 60.0);
    }
    try std.testing.expect(!scroller.isAnimating()); // must settle for zero-tick sleep!
    try std.testing.expect(steps > 5 and steps < 600);
    try std.testing.expect(scroller.offset >= 0.0 and scroller.offset <= 1000.0);

    // Overscroll past top (< 0) bounces cleanly back to 0.0 and settles
    scroller.offset = -80.0;
    scroller.velocity = 0.0;
    scroller.animating = true;
    var bounce_steps: usize = 0;
    while (scroller.isAnimating() and bounce_steps < 300) : (bounce_steps += 1) {
        _ = scroller.step(1.0 / 60.0);
    }
    try std.testing.expect(!scroller.isAnimating());
    try std.testing.expectApproxEqAbs(@as(f64, 0.0), scroller.offset, 0.5);
}

test "SumTree handles empty, zero-height, negative/NaN sanitization, and negative scroll_y" {
    var empty = try vs.SumTree.initUniform(std.testing.allocator, 0, 48.0);
    defer empty.deinit();
    try std.testing.expectEqual(@as(f64, 0.0), empty.totalHeight());
    try std.testing.expectEqual(@as(usize, 0), empty.findRowAtY(10.0));
    const empty_vis = empty.visibleRange(0.0, 300.0);
    try std.testing.expectEqual(@as(usize, 0), empty_vis.first_idx);
    try std.testing.expectEqual(@as(usize, 0), empty_vis.end_idx);

    var tree = try vs.SumTree.initUniform(std.testing.allocator, 5, 40.0);
    defer tree.deinit();
    tree.setRowHeight(2, -10.0);
    tree.setRowHeight(3, std.math.nan(f32));
    try std.testing.expectEqual(@as(f32, 0.0), tree.getRowHeight(2));
    try std.testing.expectEqual(@as(f32, 0.0), tree.getRowHeight(3));
    try std.testing.expectApproxEqAbs(@as(f64, 120.0), tree.totalHeight(), 0.01);

    // Negative scroll_y (top bounce) clamps start to row 0 and shrinks visible window
    const neg_vis = tree.visibleRange(-20.0, 50.0);
    try std.testing.expectEqual(@as(usize, 0), neg_vis.first_idx);
    try std.testing.expectEqual(@as(usize, 1), neg_vis.end_idx);
}

test "InertialScroller handles onWheel, rubber-band damping, and demo scene contentHeight" {
    var scroller = vs.InertialScroller.init(500.0);
    scroller.onWheel(120.0);
    try std.testing.expectApproxEqAbs(@as(f64, 120.0), scroller.offset, 0.01);
    try std.testing.expect(!scroller.isAnimating());
    scroller.onWheel(9000.0);
    try std.testing.expectApproxEqAbs(@as(f64, 500.0), scroller.offset, 0.01);

    // Drag past 0 applies 0.35x rubber-band damping
    scroller.onWheel(-9000.0);
    scroller.beginDrag(100.0, 0.0);
    scroller.updateDrag(200.0, 0.016); // pulling down by 100dp at top edge
    try std.testing.expectApproxEqAbs(@as(f64, -35.0), scroller.offset, 0.01);
    scroller.endDrag();
    try std.testing.expect(scroller.isAnimating());

    // Build demo scene and verify scrollable contentHeight is ~2,200dp and invariant under scroll
    var arena = core.LayoutArena.init(std.testing.allocator);
    defer arena.deinit();
    try core.buildDemoScene(&arena);
    arena.layout(768.0, 976.0);
    const root = arena.getRoot().?;
    const ch0 = arena.contentHeight(root);
    try std.testing.expect(ch0 >= 2150.0 and ch0 <= 2350.0);

    arena.setScroll(root, 0.0, 400.0);
    arena.layout(768.0, 976.0);
    const ch1 = arena.contentHeight(root);
    try std.testing.expectApproxEqAbs(ch0, ch1, 0.01);
}

test "Regression: SumTree zero-drift cancellation (1e18 -> 10.0), count=1/8/13, zero-height rows, non-finite scroll_y" {
    // 1. 1e18 -> 10.0 cancellation drift (Fenwick would leave huge error; Segment Tree is exact)
    var big = try vs.SumTree.initUniform(std.testing.allocator, 4, 10.0);
    defer big.deinit();
    big.setRowHeight(0, 1e18);
    big.setRowHeight(0, 10.0);
    try std.testing.expectApproxEqAbs(@as(f64, 40.0), big.totalHeight(), 0.001);
    try std.testing.expectApproxEqAbs(@as(f64, 20.0), big.prefixSum(2), 0.001);
    try std.testing.expectEqual(@as(usize, 2), big.findRowAtY(20.0));

    // 2. count == 1, 8 (pow2), 13 (non-pow2)
    for ([_]usize{ 1, 8, 13 }) |n| {
        var t = try vs.SumTree.initUniform(std.testing.allocator, n, 25.0);
        defer t.deinit();
        try std.testing.expectApproxEqAbs(@as(f64, @as(f64, @floatFromInt(n)) * 25.0), t.totalHeight(), 0.001);
        t.setRowHeight(n - 1, 50.0);
        try std.testing.expectApproxEqAbs(@as(f64, @as(f64, @floatFromInt(n - 1)) * 25.0 + 50.0), t.totalHeight(), 0.001);
        const vis = t.visibleRange(0.0, 30.0);
        try std.testing.expectEqual(@as(usize, 0), vis.first_idx);
        try std.testing.expect(vis.end_idx >= 1 and vis.end_idx <= n);
    }

    // 3. Zero-height interior rows on exact boundaries
    var zt = try vs.SumTree.initUniform(std.testing.allocator, 6, 30.0);
    defer zt.deinit();
    zt.setRowHeight(2, 0.0);
    zt.setRowHeight(3, 0.0);
    // Row 0: [0,30), Row 1: [30,60), Row 2: [60,60), Row 3: [60,60), Row 4: [60,90), Row 5: [90,120)
    const vis_zero = zt.visibleRange(0.0, 61.0);
    try std.testing.expectEqual(@as(usize, 0), vis_zero.first_idx);
    try std.testing.expectEqual(@as(usize, 5), vis_zero.end_idx);

    const idx_at_60 = zt.findRowAtY(60.0);
    try std.testing.expectEqual(@as(usize, 4), idx_at_60);

    // 4. Non-finite scroll_y (-inf / +inf / NaN)
    const inf_pos = zt.visibleRange(std.math.inf(f64), 50.0);
    try std.testing.expectEqual(inf_pos.first_idx, inf_pos.end_idx);
    const inf_neg = zt.visibleRange(-std.math.inf(f64), 50.0);
    try std.testing.expectEqual(inf_neg.first_idx, inf_neg.end_idx);
    const nan_scroll = zt.visibleRange(std.math.nan(f64), 50.0);
    try std.testing.expectEqual(nan_scroll.first_idx, nan_scroll.end_idx);
}

test "Regression: InertialScroller mid-fling beginDrag, backward/batched dt, setMaxScroll shrink, max_scroll=0 bounce, non-finite step" {
    var scroller = vs.InertialScroller.init(1000.0);

    // 1. Batched microsecond dt (<= 0.0001) + backward timestamp
    scroller.beginDrag(500.0, 1.0);
    scroller.updateDrag(480.0, 1.00001); // microsecond batch (dt=10us)
    scroller.updateDrag(460.0, 1.00002); // microsecond batch (dt=10us)
    scroller.updateDrag(440.0, 0.5); // backward time_s: must not move last_drag_t backward!
    scroller.updateDrag(400.0, 1.016); // real dt from 1.0 is 0.016s, accum delta is 100dp -> ~6250 clamped to 6000!
    scroller.endDrag();
    try std.testing.expect(scroller.velocity > 1000.0);
    try std.testing.expect(scroller.isAnimating());

    // beginDrag mid-fling stops velocity and animation cleanly
    scroller.beginDrag(300.0, 1.05);
    try std.testing.expect(!scroller.isAnimating());
    try std.testing.expectEqual(@as(f64, 0.0), scroller.velocity);
    scroller.endDrag();

    // 2. Shrinking setMaxScroll clamps large >200dp excess directly
    scroller.onWheel(900.0);
    scroller.setMaxScroll(200.0);
    try std.testing.expectApproxEqAbs(@as(f64, 200.0), scroller.offset, 0.01);

    // 3. max_scroll == 0 high-velocity bounce settles cleanly at 0
    var zero_sc = vs.InertialScroller.init(0.0);
    zero_sc.offset = 120.0;
    zero_sc.velocity = 3500.0;
    zero_sc.animating = true;
    var steps: usize = 0;
    while (zero_sc.isAnimating() and steps < 300) : (steps += 1) {
        _ = zero_sc.step(1.0 / 60.0);
    }
    try std.testing.expect(!zero_sc.isAnimating());
    try std.testing.expectApproxEqAbs(@as(f64, 0.0), zero_sc.offset, 0.5);

    // 4. Non-finite offset or velocity in step resets cleanly
    zero_sc.offset = std.math.nan(f64);
    zero_sc.velocity = std.math.inf(f64);
    zero_sc.animating = true;
    try std.testing.expect(!zero_sc.step(1.0 / 60.0));
    try std.testing.expectEqual(@as(f64, 0.0), zero_sc.offset);
    try std.testing.expectEqual(@as(f64, 0.0), zero_sc.velocity);
}

test "Regression: LayoutArena.contentHeight includes bottom padding" {
    var arena = core.LayoutArena.init(std.testing.allocator);
    defer arena.deinit();

    const root = try arena.addNode(.{
        .kind = .vstack,
        .role = .container,
        .padding = 24.0,
    });
    _ = try arena.addChild(root, .{
        .kind = .card,
        .role = .panel,
        .height = 100.0,
    });
    arena.layout(400.0, 400.0);
    // top pad 24 + child 100 + bottom pad 24 = 148
    try std.testing.expectApproxEqAbs(@as(f32, 148.0), arena.contentHeight(root), 0.01);
}
