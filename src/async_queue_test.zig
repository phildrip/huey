const std = @import("std");
const aq = @import("async_queue.zig");

test "AsyncWakeQueue delivers multi-producer background messages and wakes Linux eventfd" {
    var q = try aq.AsyncWakeQueue.init();
    defer q.deinit();

    try std.testing.expect(q.wakeFd() >= 0);

    // Push from background worker threads
    const WorkerCtx = struct {
        q: *aq.AsyncWakeQueue,
        base: u32,
    };
    const worker = struct {
        fn run(ctx: WorkerCtx) void {
            var i: u32 = 0;
            while (i < 16) : (i += 1) {
                _ = ctx.q.push(.{ .tag = ctx.base + i, .f32_val = @floatFromInt(ctx.base + i) });
            }
        }
    }.run;

    var t1 = try std.Thread.spawn(.{}, worker, .{WorkerCtx{ .q = &q, .base = 100 }});
    var t2 = try std.Thread.spawn(.{}, worker, .{WorkerCtx{ .q = &q, .base = 200 }});
    t1.join();
    t2.join();

    // Drain wakeup fd (non-blocking) and all 32 messages
    try std.testing.expect(q.acknowledgeWake());
    var out: [64]aq.AsyncMessage = undefined;
    const n = q.drain(&out);
    try std.testing.expectEqual(@as(usize, 32), n);

    // Second drain is empty and wake fd is quiet
    try std.testing.expectEqual(@as(usize, 0), q.drain(&out));
    try std.testing.expect(!q.acknowledgeWake());
}

test "AsyncWakeQueue handles bounded ring overflow cleanly without blocking" {
    var q = try aq.AsyncWakeQueue.init();
    defer q.deinit();

    var pushed: usize = 0;
    var i: u32 = 0;
    while (i < 512) : (i += 1) {
        if (q.push(.{ .tag = i, .f32_val = 0.0 })) pushed += 1;
    }
    try std.testing.expectEqual(aq.CAPACITY, pushed);
    try std.testing.expectEqual(@as(usize, 512 - aq.CAPACITY), q.droppedCount());
    try std.testing.expectEqual(aq.CAPACITY, q.pendingCount());
}

test "AsyncMessage.payloadSlice returns exact slice and clamps oversized lengths" {
    var msg = aq.AsyncMessage{ .tag = 7, .u64_val = 42 };
    try std.testing.expectEqualSlices(u8, "", msg.payloadSlice());

    const text = "hello-async";
    @memcpy(msg.payload[0..text.len], text);
    msg.payload_len = text.len;
    try std.testing.expectEqualSlices(u8, text, msg.payloadSlice());

    // Out-of-bounds payload_len must safely clamp to MAX_PAYLOAD_BYTES
    msg.payload_len = 255;
    try std.testing.expectEqual(aq.MAX_PAYLOAD_BYTES, msg.payloadSlice().len);
}

test "AsyncWakeQueue preserves FIFO order across partial drains and wrap-around" {
    var q = try aq.AsyncWakeQueue.init();
    defer q.deinit();

    try std.testing.expectEqual(@as(usize, 0), q.pendingCount());

    // Push 5 items, partially drain 2, verify remaining 3 and FIFO order
    var i: u32 = 0;
    while (i < 5) : (i += 1) {
        try std.testing.expect(q.push(.{ .tag = i + 10, .u64_val = i + 100 }));
    }
    try std.testing.expectEqual(@as(usize, 5), q.pendingCount());

    var empty_out: [0]aq.AsyncMessage = .{};
    try std.testing.expectEqual(@as(usize, 0), q.drain(&empty_out));
    try std.testing.expectEqual(@as(usize, 5), q.pendingCount());

    var batch1: [2]aq.AsyncMessage = undefined;
    try std.testing.expectEqual(@as(usize, 2), q.drain(&batch1));
    try std.testing.expectEqual(@as(u32, 10), batch1[0].tag);
    try std.testing.expectEqual(@as(u32, 11), batch1[1].tag);
    try std.testing.expectEqual(@as(usize, 3), q.pendingCount());

    var batch2: [4]aq.AsyncMessage = undefined;
    try std.testing.expectEqual(@as(usize, 3), q.drain(&batch2));
    try std.testing.expectEqual(@as(u32, 12), batch2[0].tag);
    try std.testing.expectEqual(@as(u32, 13), batch2[1].tag);
    try std.testing.expectEqual(@as(u32, 14), batch2[2].tag);
    try std.testing.expectEqual(@as(usize, 0), q.pendingCount());

    // Wrap around the ring buffer beyond CAPACITY
    var round: u32 = 0;
    while (round < aq.CAPACITY + 20) : (round += 1) {
        try std.testing.expect(q.push(.{ .tag = round, .u64_val = round * 2 }));
        try std.testing.expectEqual(@as(usize, 1), q.pendingCount());
        var single: [1]aq.AsyncMessage = undefined;
        try std.testing.expectEqual(@as(usize, 1), q.drain(&single));
        try std.testing.expectEqual(round, single[0].tag);
        try std.testing.expectEqual(@as(u64, round * 2), single[0].u64_val);
        try std.testing.expectEqual(@as(usize, 0), q.pendingCount());
    }
}

test "partial drain re-signals eventfd so poll sees POLLIN and acknowledgeWake returns true" {
    var q = try aq.AsyncWakeQueue.init();
    defer q.deinit();

    var i: u32 = 0;
    while (i < 5) : (i += 1) {
        try std.testing.expect(q.push(.{ .tag = i + 1 }));
    }

    // Consume initial wake, then drain only 2 of 5 items
    try std.testing.expect(q.acknowledgeWake());
    var partial: [2]aq.AsyncMessage = undefined;
    try std.testing.expectEqual(@as(usize, 2), q.drain(&partial));
    try std.testing.expectEqual(@as(usize, 3), q.pendingCount());

    // Remaining items must keep wakeFd POLLIN-ready for level-triggered loops
    var pfd = [_]std.os.linux.pollfd{.{
        .fd = q.wakeFd(),
        .events = std.os.linux.POLL.IN,
        .revents = 0,
    }};
    const rc = std.os.linux.poll(&pfd, 1, 0);
    try std.testing.expectEqual(std.os.linux.E.SUCCESS, std.os.linux.errno(rc));
    try std.testing.expectEqual(@as(usize, 1), rc);
    try std.testing.expect((pfd[0].revents & std.os.linux.POLL.IN) != 0);
    try std.testing.expect(q.acknowledgeWake());

    // Drain remaining 3 items -> wakeFd is now quiet
    var rest: [4]aq.AsyncMessage = undefined;
    try std.testing.expectEqual(@as(usize, 3), q.drain(&rest));
    try std.testing.expectEqual(@as(usize, 0), q.pendingCount());
    try std.testing.expect(!q.acknowledgeWake());
}

test "AsyncWakeQueue concurrent producers and polling consumer lose zero wakeups" {
    var q = try aq.AsyncWakeQueue.init();
    defer q.deinit();

    const per_producer: u32 = 128;
    const total_expected: usize = per_producer * 2;

    const WorkerCtx = struct {
        q: *aq.AsyncWakeQueue,
        base: u32,
        count: u32,
    };
    const worker = struct {
        fn run(ctx: WorkerCtx) void {
            var i: u32 = 0;
            while (i < ctx.count) : (i += 1) {
                while (!ctx.q.push(.{ .tag = ctx.base + i })) {
                    std.atomic.spinLoopHint();
                }
            }
        }
    }.run;

    var t1 = try std.Thread.spawn(.{}, worker, .{WorkerCtx{ .q = &q, .base = 1000, .count = per_producer }});
    var t2 = try std.Thread.spawn(.{}, worker, .{WorkerCtx{ .q = &q, .base = 2000, .count = per_producer }});

    var received: usize = 0;
    var tag_sum: u64 = 0;
    while (received < total_expected) {
        var pfd = [_]std.os.linux.pollfd{.{
            .fd = q.wakeFd(),
            .events = std.os.linux.POLL.IN,
            .revents = 0,
        }};
        const rc = std.os.linux.poll(&pfd, 1, 1000);
        if (std.os.linux.errno(rc) == .INTR) continue;
        try std.testing.expect(rc > 0);
        try std.testing.expect(q.acknowledgeWake());

        var batch: [16]aq.AsyncMessage = undefined;
        const n = q.drain(&batch);
        for (batch[0..n]) |msg| {
            tag_sum += msg.tag;
        }
        received += n;
    }

    t1.join();
    t2.join();

    try std.testing.expectEqual(total_expected, received);
    try std.testing.expectEqual(@as(usize, 0), q.pendingCount());
    try std.testing.expectEqual(@as(usize, 0), q.droppedCount());

    var expected_sum: u64 = 0;
    var i: u32 = 0;
    while (i < per_producer) : (i += 1) {
        expected_sum += (1000 + i) + (2000 + i);
    }
    try std.testing.expectEqual(expected_sum, tag_sum);
}

test "AsyncWakeQueue double deinit is safe and resets wakeFd" {
    var q = try aq.AsyncWakeQueue.init();
    try std.testing.expect(q.wakeFd() >= 0);

    q.deinit();
    try std.testing.expectEqual(@as(i32, -1), q.wakeFd());
    try std.testing.expect(!q.acknowledgeWake());

    // Second deinit must be a no-op
    q.deinit();
    try std.testing.expectEqual(@as(i32, -1), q.wakeFd());
}

test "AsyncWakeQueue post-overflow drain and re-push preserves FIFO order" {
    var q = try aq.AsyncWakeQueue.init();
    defer q.deinit();

    var i: u32 = 0;
    while (i < aq.CAPACITY) : (i += 1) {
        try std.testing.expect(q.push(.{ .tag = i }));
    }
    // Overflow by 10
    var extra: u32 = 0;
    while (extra < 10) : (extra += 1) {
        try std.testing.expect(!q.push(.{ .tag = 9999 + extra }));
    }
    try std.testing.expectEqual(@as(usize, 10), q.droppedCount());
    try std.testing.expectEqual(aq.CAPACITY, q.pendingCount());

    // Drain all CAPACITY items and verify FIFO 0..CAPACITY-1
    var drained: [aq.CAPACITY]aq.AsyncMessage = undefined;
    try std.testing.expectEqual(aq.CAPACITY, q.drain(&drained));
    try std.testing.expectEqual(@as(usize, 0), q.pendingCount());
    for (drained, 0..) |msg, idx| {
        try std.testing.expectEqual(@as(u32, @intCast(idx)), msg.tag);
    }
    _ = q.acknowledgeWake();

    // Re-push new items and verify FIFO order
    var j: u32 = 0;
    while (j < 8) : (j += 1) {
        try std.testing.expect(q.push(.{ .tag = 9000 + j }));
    }
    try std.testing.expectEqual(@as(usize, 8), q.pendingCount());
    try std.testing.expect(q.acknowledgeWake());

    var out: [8]aq.AsyncMessage = undefined;
    try std.testing.expectEqual(@as(usize, 8), q.drain(&out));
    for (out, 0..) |msg, idx| {
        try std.testing.expectEqual(@as(u32, 9000 + @as(u32, @intCast(idx))), msg.tag);
    }
    try std.testing.expectEqual(@as(usize, 0), q.pendingCount());
}
