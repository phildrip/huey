const std = @import("std");
const reconcile = @import("reconcile.zig");

test "WidgetStateStore preserves retained state across dynamic index-0 insertion and GCs unvisited nodes" {
    var store = reconcile.WidgetStateStore.init(std.testing.allocator);
    defer store.deinit();

    const root_key = reconcile.deriveKey(0, "list.root");
    const k_alpha = reconcile.deriveKey(root_key, "row.alpha");
    const k_beta = reconcile.deriveKey(root_key, "row.beta");
    const k_gamma = reconcile.deriveKey(root_key, "row.gamma");

    // Frame 1: render [alpha, beta], set scroll_y & cursor on alpha
    store.beginFrame(1);
    const s_alpha1 = try store.touch(k_alpha);
    s_alpha1.scroll_y = 142.5;
    s_alpha1.cursor_pos = 7;
    _ = try store.touch(k_beta);
    try std.testing.expectEqual(@as(usize, 0), store.endFrame());
    try std.testing.expectEqual(@as(usize, 2), store.count());

    // Frame 2: insert gamma at index 0 ([gamma, alpha, beta]) -> alpha keeps exact retained state!
    store.beginFrame(2);
    const s_gamma = try store.touch(k_gamma);
    try std.testing.expectEqual(@as(f32, 0.0), s_gamma.scroll_y);
    const s_alpha2 = try store.touch(k_alpha);
    try std.testing.expectEqual(@as(f32, 142.5), s_alpha2.scroll_y);
    try std.testing.expectEqual(@as(usize, 7), s_alpha2.cursor_pos);
    _ = try store.touch(k_beta);
    try std.testing.expectEqual(@as(usize, 0), store.endFrame());
    try std.testing.expectEqual(@as(usize, 3), store.count());

    // Frame 3: remove beta ([gamma, alpha]) -> endFrame GCs beta!
    store.beginFrame(3);
    _ = try store.touch(k_gamma);
    _ = try store.touch(k_alpha);
    const swept = store.endFrame();
    try std.testing.expectEqual(@as(usize, 1), swept);
    try std.testing.expectEqual(@as(usize, 2), store.count());
    try std.testing.expectEqual(@as(?*reconcile.RetainedState, null), store.get(k_beta));
    try std.testing.expectEqual(@as(f32, 142.5), store.get(k_alpha).?.scroll_y);
}

test "deriveKey isolates identical local IDs under different parent subtrees" {
    const p1 = reconcile.deriveKey(0, "panel.left");
    const p2 = reconcile.deriveKey(0, "panel.right");
    const c1 = reconcile.deriveKey(p1, "btn.ok");
    const c2 = reconcile.deriveKey(p2, "btn.ok");
    try std.testing.expect(c1 != c2);
}

test "repeated beginFrame(0) and non-monotonic frame IDs GC cleanly" {
    var store = reconcile.WidgetStateStore.init(std.testing.allocator);
    defer store.deinit();

    const k1 = reconcile.deriveKey(0, "widget.a");
    const k2 = reconcile.deriveKey(0, "widget.b");

    // Repeated 0 frame indices
    store.beginFrame(0);
    (try store.touch(k1)).slider_val = 0.75;
    _ = try store.touch(k2);
    try std.testing.expectEqual(@as(usize, 0), store.endFrame());
    try std.testing.expectEqual(@as(usize, 2), store.count());

    store.beginFrame(0);
    _ = try store.touch(k1);
    try std.testing.expectEqual(@as(usize, 1), store.endFrame());
    try std.testing.expectEqual(@as(usize, 1), store.count());
    try std.testing.expectEqual(@as(?*reconcile.RetainedState, null), store.get(k2));
    try std.testing.expectEqual(@as(f32, 0.75), store.get(k1).?.slider_val);

    // Non-monotonic decreasing and maxInt frame IDs
    store.beginFrame(100);
    _ = try store.touch(k1);
    _ = try store.touch(k2);
    try std.testing.expectEqual(@as(usize, 0), store.endFrame());
    try std.testing.expectEqual(@as(usize, 2), store.count());

    store.beginFrame(5);
    _ = try store.touch(k2);
    try std.testing.expectEqual(@as(usize, 1), store.endFrame());
    try std.testing.expectEqual(@as(?*reconcile.RetainedState, null), store.get(k1));
    try std.testing.expect(store.get(k2) != null);

    store.beginFrame(std.math.maxInt(u64));
    _ = try store.touch(k2);
    try std.testing.expectEqual(@as(usize, 0), store.endFrame());

    store.beginFrame(0);
    try std.testing.expectEqual(@as(usize, 1), store.endFrame());
    try std.testing.expectEqual(@as(usize, 0), store.count());
}

test "zero-alloc steady-state touch and endFrame" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var store = reconcile.WidgetStateStore.init(failing.allocator());
    defer store.deinit();

    const root = reconcile.deriveKey(0, "steady.root");
    const keys = [_]reconcile.WidgetKey{
        reconcile.deriveIndexKey(root, 0),
        reconcile.deriveIndexKey(root, 1),
        reconcile.deriveIndexKey(root, 2),
        reconcile.deriveIndexKey(root, 3),
    };

    // Warm-up frame populates the store.
    store.beginFrame(1);
    for (keys) |k| {
        const st = try store.touch(k);
        st.checked = true;
    }
    try std.testing.expectEqual(@as(usize, 0), store.endFrame());
    try std.testing.expectEqual(@as(usize, keys.len), store.count());

    // Lock allocator against any further allocations or resizes.
    const allocs_after_warmup = failing.alloc_index;
    const resizes_after_warmup = failing.resize_index;
    failing.fail_index = allocs_after_warmup;
    failing.resize_fail_index = resizes_after_warmup;

    // Steady-state frames: touching cached keys and sweeping stale keys must not allocate.
    for (0..5) |_| {
        store.beginFrame(0);
        for (keys) |k| {
            const st = try store.touch(k);
            try std.testing.expect(st.checked);
        }
        try std.testing.expectEqual(@as(usize, 0), store.endFrame());
    }

    // Sweeping subset via backward swap-remove also does zero allocations.
    store.beginFrame(0);
    _ = try store.touch(keys[0]);
    _ = try store.touch(keys[2]);
    try std.testing.expectEqual(@as(usize, 2), store.endFrame());
    try std.testing.expectEqual(@as(usize, 2), store.count());

    try std.testing.expectEqual(allocs_after_warmup, failing.alloc_index);
    try std.testing.expectEqual(resizes_after_warmup, failing.resize_index);
    try std.testing.expect(!failing.has_induced_failure);
}

test "deriveIndexKey produces distinct deterministic non-zero keys" {
    const p1 = reconcile.deriveKey(0, "list.a");
    const p2 = reconcile.deriveKey(0, "list.b");

    var seen: [64]reconcile.WidgetKey = undefined;
    for (&seen, 0..) |*slot, idx| {
        const k = reconcile.deriveIndexKey(p1, idx);
        try std.testing.expect(k != 0);
        try std.testing.expectEqual(k, reconcile.deriveIndexKey(p1, idx));
        try std.testing.expect(k != reconcile.deriveIndexKey(p2, idx));
        for (seen[0..idx]) |prev| {
            try std.testing.expect(k != prev);
        }
        slot.* = k;
    }

    // Index key does not trivially collide with local_id string or raw little-endian bytes.
    const raw_zero = [_]u8{0} ** 8;
    try std.testing.expect(reconcile.deriveIndexKey(p1, 0) != reconcile.deriveKey(p1, &raw_zero));
    try std.testing.expect(reconcile.deriveIndexKey(p1, 0) != reconcile.deriveKey(p1, "0"));
}

test "clear removes all entries and allows clean reuse" {
    var store = reconcile.WidgetStateStore.init(std.testing.allocator);
    defer store.deinit();

    const k1 = reconcile.deriveKey(0, "item.1");
    const k2 = reconcile.deriveKey(0, "item.2");

    store.beginFrame(1);
    (try store.touch(k1)).hovered = true;
    (try store.touch(k2)).pressed = true;
    try std.testing.expectEqual(@as(usize, 2), store.count());

    store.clear();
    try std.testing.expectEqual(@as(usize, 0), store.count());
    try std.testing.expectEqual(@as(?*reconcile.RetainedState, null), store.get(k1));
    try std.testing.expectEqual(@as(?*reconcile.RetainedState, null), store.get(k2));
    try std.testing.expectEqual(@as(usize, 0), store.endFrame());

    store.beginFrame(2);
    const s1 = try store.touch(k1);
    try std.testing.expect(!s1.hovered);
    try std.testing.expectEqual(@as(f32, 0.0), s1.scroll_x);
    try std.testing.expectEqual(@as(f32, 0.0), s1.anim_t);
    try std.testing.expectEqual(@as(usize, 0), store.endFrame());
    try std.testing.expectEqual(@as(usize, 1), store.count());
}

test "ensureTotalCapacity and >= 64 entries hash-indexed GC churn with FailingAllocator" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var store = reconcile.WidgetStateStore.init(failing.allocator());
    defer store.deinit();

    const n: usize = 96;
    try store.ensureTotalCapacity(n);

    // Lock allocator against further allocations or resizes after pre-sizing.
    const allocs_after_reserve = failing.alloc_index;
    const resizes_after_reserve = failing.resize_index;
    failing.fail_index = allocs_after_reserve;
    failing.resize_fail_index = resizes_after_reserve;

    const root = reconcile.deriveKey(0, "virtual.grid");
    var keys: [n]reconcile.WidgetKey = undefined;
    for (&keys, 0..) |*k, i| {
        k.* = reconcile.deriveIndexKey(root, i);
    }

    // Frame 1: populate >= 64 entries (triggers AutoArrayHashMap index header) with zero extra allocs.
    store.beginFrame(1);
    for (keys, 0..) |k, i| {
        const st = try store.touch(k);
        st.scroll_y = @floatFromInt(i);
    }
    try std.testing.expectEqual(@as(usize, 0), store.endFrame());
    try std.testing.expectEqual(n, store.count());

    // Frame 2: touch only even indices -> sweep all 48 odd indices via backward swap-remove.
    store.beginFrame(2);
    for (keys, 0..) |k, i| {
        if (i % 2 == 0) {
            const st = try store.touch(k);
            try std.testing.expectEqual(@as(f32, @floatFromInt(i)), st.scroll_y);
        }
    }
    try std.testing.expectEqual(@as(usize, n / 2), store.endFrame());
    try std.testing.expectEqual(@as(usize, n / 2), store.count());

    // Frame 3: churn — re-insert odd indices while dropping half of evens, still zero allocs.
    store.beginFrame(3);
    for (keys, 0..) |k, i| {
        if (i % 2 == 1 or i % 4 == 0) {
            const st = try store.touch(k);
            st.cursor_pos = i;
        }
    }
    try std.testing.expectEqual(@as(usize, n / 4), store.endFrame());
    try std.testing.expectEqual(@as(usize, (n * 3) / 4), store.count());

    try std.testing.expectEqual(allocs_after_reserve, failing.alloc_index);
    try std.testing.expectEqual(resizes_after_reserve, failing.resize_index);
    try std.testing.expect(!failing.has_induced_failure);
}

test "touch(0) returns InvalidWidgetKey and get(0) returns null" {
    var store = reconcile.WidgetStateStore.init(std.testing.allocator);
    defer store.deinit();

    store.beginFrame(1);
    try std.testing.expectError(error.InvalidWidgetKey, store.touch(0));
    try std.testing.expectEqual(@as(?*reconcile.RetainedState, null), store.get(0));
    try std.testing.expectEqual(@as(usize, 0), store.endFrame());
    try std.testing.expectEqual(@as(usize, 0), store.count());
}

test "in_frame lifecycle guard rejects touch before beginFrame and double endFrame returns 0" {
    var store = reconcile.WidgetStateStore.init(std.testing.allocator);
    defer store.deinit();

    const k = reconcile.deriveKey(0, "guarded.btn");
    try std.testing.expectError(error.FrameNotActive, store.touch(k));
    try std.testing.expectEqual(@as(usize, 0), store.endFrame());

    store.beginFrame(1);
    _ = try store.touch(k);
    try std.testing.expectEqual(@as(usize, 0), store.endFrame());
    // Second endFrame without beginFrame must be a no-op and NOT sweep k!
    try std.testing.expectEqual(@as(usize, 0), store.endFrame());
    try std.testing.expectEqual(@as(usize, 1), store.count());
    try std.testing.expect(store.get(k) != null);

    // Touch after endFrame before next beginFrame must fail.
    try std.testing.expectError(error.FrameNotActive, store.touch(k));

    // Mid-frame clear leaves in_frame active so endFrame completes the frame normally.
    store.beginFrame(2);
    _ = try store.touch(k);
    store.clear();
    const k2 = reconcile.deriveKey(0, "guarded.after_clear");
    _ = try store.touch(k2);
    try std.testing.expectEqual(@as(usize, 0), store.endFrame());
    try std.testing.expectEqual(@as(usize, 1), store.count());
}

test "epoch wraparound from maxInt(u64) wraps to 1 and sweeps stale entries" {
    var store = reconcile.WidgetStateStore.init(std.testing.allocator);
    defer store.deinit();

    const k_keep = reconcile.deriveKey(0, "wrap.keep");
    const k_stale = reconcile.deriveKey(0, "wrap.stale");

    store.epoch = std.math.maxInt(u64) - 1;
    store.beginFrame(0); // epoch == maxInt(u64)
    try std.testing.expectEqual(std.math.maxInt(u64), store.epoch);
    (try store.touch(k_keep)).anim_t = 0.5;
    _ = try store.touch(k_stale);
    try std.testing.expectEqual(@as(usize, 0), store.endFrame());

    store.beginFrame(0); // wraps to epoch == 1 (never 0)
    try std.testing.expectEqual(@as(u64, 1), store.epoch);
    _ = try store.touch(k_keep);
    try std.testing.expectEqual(@as(usize, 1), store.endFrame());
    try std.testing.expectEqual(@as(usize, 1), store.count());
    try std.testing.expectEqual(@as(?*reconcile.RetainedState, null), store.get(k_stale));
    try std.testing.expectEqual(@as(f32, 0.5), store.get(k_keep).?.anim_t);
}

test "struct replacement on RetainedState pointer does not cause premature GC" {
    var store = reconcile.WidgetStateStore.init(std.testing.allocator);
    defer store.deinit();

    const k = reconcile.deriveKey(0, "replace.state");
    store.beginFrame(1);
    const st = try store.touch(k);
    st.* = .{ .scroll_y = 99.0 };
    try std.testing.expectEqual(@as(usize, 0), store.endFrame());
    try std.testing.expectEqual(@as(usize, 1), store.count());
    try std.testing.expectEqual(@as(f32, 99.0), store.get(k).?.scroll_y);
}

