const std = @import("std");
const builtin = @import("builtin");
const linux = std.os.linux;
const events = @import("events.zig");
const aq = @import("async_queue.zig");
const wl = @import("wayland.zig");

const native_endian = builtin.cpu.arch.endian();

test "Wayland wire codec encodes and decodes messages (header, strings, fixed 24.8, arrays) accurately" {
    var buf: [256]u8 = undefined;
    var enc = wl.WireEncoder.init(&buf);
    try enc.writeU32(42);
    try enc.writeString("zwlr_layer_shell_v1");
    try enc.writeFixed(128.5);
    const msg = try enc.finish(1, 0); // object_id=1, opcode=0

    var dec = try wl.WireDecoder.init(msg);
    try std.testing.expectEqual(@as(u32, 1), dec.object_id);
    try std.testing.expectEqual(@as(u16, 0), dec.opcode);
    try std.testing.expectEqual(@as(u32, 42), try dec.readU32());
    try std.testing.expectEqualStrings("zwlr_layer_shell_v1", try dec.readString());
    try std.testing.expectApproxEqAbs(@as(f32, 128.5), try dec.readFixed(), 0.01);
}

test "WaylandClient binds globals, handles zwlr_layer_shell_v1 configure, wp_fractional_scale_v1, and translates pointer/key to InputEvent" {
    var client = try wl.WaylandClient.initLoopback(std.testing.allocator);
    defer client.deinit();

    // Simulate compositor advertising globals
    try client.simulateRegistryGlobal(1, "wl_compositor", 5);
    try client.simulateRegistryGlobal(2, "xdg_wm_base", 3);
    try client.simulateRegistryGlobal(3, "zwlr_layer_shell_v1", 4);
    try client.simulateRegistryGlobal(4, "wp_fractional_scale_manager_v1", 1);
    try client.simulateRegistryGlobal(5, "wl_seat", 7);

    try std.testing.expect(client.hasLayerShell());
    try std.testing.expect(client.hasFractionalScale());

    // Create a stratifi top status bar layer-surface (height 32dp, anchored top+left+right, exclusive_zone=32)
    const surf = try client.createLayerSurface(.{
        .layer = .top,
        .anchor = .{ .top = true, .left = true, .right = true },
        .width = 0,
        .height = 32,
        .exclusive_zone = 32,
        .namespace = "stratifi-bar",
    });
    try std.testing.expect(surf.surface_id != 0);

    // Compositor sends fractional scale 180/120 = 1.50x and configure(1920, 32)
    client.handleFractionalScale(surf.surface_id, 180);
    try std.testing.expectApproxEqAbs(@as(f32, 1.5), client.getSurfaceScale(surf.surface_id).?, 0.001);

    try client.handleLayerConfigure(surf.layer_surface_id, 99, 1920, 32);
    const cfg = client.getSurfaceSize(surf.surface_id).?;
    try std.testing.expectEqual(@as(u32, 1920), cfg[0]);
    try std.testing.expectEqual(@as(u32, 32), cfg[1]);

    // Pointer motion + button press translate cleanly into logical InputEvent
    client.handlePointerMotion(120.5, 16.0);
    client.handlePointerButton(wl.BTN_LEFT, true);
    const evs = client.drainInputEvents();
    try std.testing.expectEqual(@as(usize, 2), evs.len);
    try std.testing.expect(evs[0] == .pointer_move);
    try std.testing.expectApproxEqAbs(@as(f32, 120.5), evs[0].pointer_move.x, 0.01);
    try std.testing.expect(evs[1] == .pointer_down);
    try std.testing.expectEqual(events.PointerButton.primary, evs[1].pointer_down.button);
}

test "WireDecoder rejects truncated, unaligned, and malformed string messages" {
    // Truncated header (< 8 bytes)
    try std.testing.expectError(error.TruncatedHeader, wl.WireDecoder.init(&[_]u8{ 1, 2, 3, 4, 5, 6, 7 }));

    // Size < 8 in header
    var bad_size: [8]u8 = undefined;
    std.mem.writeInt(u32, bad_size[0..4], 1, native_endian);
    std.mem.writeInt(u32, bad_size[4..8], (@as(u32, 4) << 16) | 0, native_endian);
    try std.testing.expectError(error.InvalidMessageSize, wl.WireDecoder.init(&bad_size));

    // Size > buffer length (truncated message)
    var trunc_msg: [12]u8 = [_]u8{0} ** 12;
    std.mem.writeInt(u32, trunc_msg[0..4], 1, native_endian);
    std.mem.writeInt(u32, trunc_msg[4..8], (@as(u32, 16) << 16) | 0, native_endian);
    try std.testing.expectError(error.TruncatedMessage, wl.WireDecoder.init(&trunc_msg));

    // Unaligned message size (not a multiple of 4)
    var unaligned_msg: [16]u8 = [_]u8{0} ** 16;
    std.mem.writeInt(u32, unaligned_msg[0..4], 1, native_endian);
    std.mem.writeInt(u32, unaligned_msg[4..8], (@as(u32, 10) << 16) | 0, native_endian);
    try std.testing.expectError(error.UnalignedMessageSize, wl.WireDecoder.init(&unaligned_msg));

    // String with length == 0 (Wayland strings must include trailing NUL, so len >= 1)
    var zero_str: [12]u8 = [_]u8{0} ** 12;
    std.mem.writeInt(u32, zero_str[0..4], 1, native_endian);
    std.mem.writeInt(u32, zero_str[4..8], (@as(u32, 12) << 16) | 0, native_endian);
    std.mem.writeInt(u32, zero_str[8..12], 0, native_endian);
    var dec_zero = try wl.WireDecoder.init(&zero_str);
    try std.testing.expectError(error.InvalidStringLength, dec_zero.readString());

    // String missing NUL terminator
    var nonul_str: [16]u8 = [_]u8{0} ** 16;
    std.mem.writeInt(u32, nonul_str[0..4], 1, native_endian);
    std.mem.writeInt(u32, nonul_str[4..8], (@as(u32, 16) << 16) | 0, native_endian);
    std.mem.writeInt(u32, nonul_str[8..12], 4, native_endian);
    @memcpy(nonul_str[12..16], "abcd");
    var dec_nonul = try wl.WireDecoder.init(&nonul_str);
    try std.testing.expectError(error.MissingNulTerminator, dec_nonul.readString());

    // String length exceeding message payload bounds (including 4-byte padding)
    var over_str: [16]u8 = [_]u8{0} ** 16;
    std.mem.writeInt(u32, over_str[0..4], 1, native_endian);
    std.mem.writeInt(u32, over_str[4..8], (@as(u32, 16) << 16) | 0, native_endian);
    std.mem.writeInt(u32, over_str[8..12], 6, native_endian);
    @memcpy(over_str[12..16], "abc\x00");
    var dec_over = try wl.WireDecoder.init(&over_str);
    try std.testing.expectError(error.TruncatedString, dec_over.readString());

    // Huge string length (0xFFFFFFFF) must not overflow alignForward
    var huge_str: [16]u8 = [_]u8{0} ** 16;
    std.mem.writeInt(u32, huge_str[0..4], 1, native_endian);
    std.mem.writeInt(u32, huge_str[4..8], (@as(u32, 16) << 16) | 0, native_endian);
    std.mem.writeInt(u32, huge_str[8..12], 0xFFFF_FFFF, native_endian);
    var dec_huge = try wl.WireDecoder.init(&huge_str);
    try std.testing.expectError(error.TruncatedString, dec_huge.readString());

    // WireEncoder array roundtrip and negative fixed point + non-finite guard
    var buf: [64]u8 = undefined;
    var enc = wl.WireEncoder.init(&buf);
    try enc.writeFixed(-42.25);
    try enc.writeArray(&[_]u8{ 0xAA, 0xBB, 0xCC });
    const msg = try enc.finish(9, 3);
    var dec_arr = try wl.WireDecoder.init(msg);
    try std.testing.expectApproxEqAbs(@as(f32, -42.25), try dec_arr.readFixed(), 0.01);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0xAA, 0xBB, 0xCC }, try dec_arr.readArray());

    var enc_nan = wl.WireEncoder.init(&buf);
    try std.testing.expectError(error.InvalidFixedPoint, enc_nan.writeFixed(std.math.nan(f32)));
    try std.testing.expectError(error.InvalidString, enc_nan.writeString("bad\x00str"));
}

test "EpollLoop wakes immediately on AsyncWakeQueue.wakeFd() and returns 0 when idle" {
    var q = try aq.AsyncWakeQueue.init();
    defer q.deinit();

    var ep = try wl.EpollLoop.init();
    defer ep.deinit();

    const WAKE_TAG: u64 = 0xCAFE;
    try ep.addFd(q.wakeFd(), WAKE_TAG);

    // Idle queue -> non-blocking wait (timeout_ms = 0) returns 0 tags
    const idle_tags = try ep.wait(0);
    try std.testing.expectEqual(@as(usize, 0), idle_tags.len);

    // Push item -> wakeFd signals -> epoll_wait(-1) wakes immediately at 0% CPU
    try std.testing.expect(q.push(.{ .tag = 77 }));
    const woken = try ep.wait(-1);
    try std.testing.expectEqual(@as(usize, 1), woken.len);
    try std.testing.expectEqual(WAKE_TAG, woken[0]);

    // Acknowledge and drain -> epoll returns 0 again
    try std.testing.expect(q.acknowledgeWake());
    var msgs: [4]aq.AsyncMessage = undefined;
    try std.testing.expectEqual(@as(usize, 1), q.drain(&msgs));
    try std.testing.expectEqual(@as(u32, 77), msgs[0].tag);

    const idle_again = try ep.wait(0);
    try std.testing.expectEqual(@as(usize, 0), idle_again.len);
}

test "WaylandClient translates handlePointerAxis and evdev handleKey (ESC, ENTER, TAB) and bounds queue" {
    var client = try wl.WaylandClient.initLoopback(std.testing.allocator);
    defer client.deinit();

    client.handlePointerMotion(400.0, 24.0);
    client.handlePointerAxis(1.5, -3.0);
    client.handlePointerButton(wl.BTN_RIGHT, true);
    client.handlePointerButton(wl.BTN_MIDDLE, false);

    const mods_ctrl_shift = events.Modifiers{ .ctrl = true, .shift = true };
    client.handleKey(1, true, .{}); // KEY_ESC
    client.handleKey(28, true, .{ .ctrl = true }); // KEY_ENTER
    client.handleKey(15, true, mods_ctrl_shift); // KEY_TAB
    client.handleKey(15, false, mods_ctrl_shift); // KEY_TAB release

    const evs = client.drainInputEvents();
    try std.testing.expectEqual(@as(usize, 8), evs.len);

    try std.testing.expect(evs[1] == .wheel);
    try std.testing.expectApproxEqAbs(@as(f32, 400.0), evs[1].wheel.x, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 24.0), evs[1].wheel.y, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 1.5), evs[1].wheel.dx, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, -3.0), evs[1].wheel.dy, 0.01);

    try std.testing.expect(evs[2] == .pointer_down);
    try std.testing.expectEqual(events.PointerButton.secondary, evs[2].pointer_down.button);
    try std.testing.expect(evs[3] == .pointer_up);
    try std.testing.expectEqual(events.PointerButton.middle, evs[3].pointer_up.button);

    try std.testing.expect(evs[4] == .key_down);
    try std.testing.expectEqual(events.Key.escape, evs[4].key_down.key);

    try std.testing.expect(evs[5] == .key_down);
    try std.testing.expectEqual(events.Key.enter, evs[5].key_down.key);
    try std.testing.expect(evs[5].key_down.mods.ctrl);

    try std.testing.expect(evs[6] == .key_down);
    try std.testing.expectEqual(events.Key.tab, evs[6].key_down.key);
    try std.testing.expect(evs[6].key_down.mods.ctrl and evs[6].key_down.mods.shift);

    try std.testing.expect(evs[7] == .key_up);
    try std.testing.expectEqual(events.Key.tab, evs[7].key_up.key);

    // Subsequent drain must be empty
    try std.testing.expectEqual(@as(usize, 0), client.drainInputEvents().len);

    // Bounded queue overflow check (> 128 events drops cleanly without crashing)
    var i: usize = 0;
    while (i < 140) : (i += 1) {
        client.handleKey(1, true, .{});
    }
    const capped = client.drainInputEvents();
    try std.testing.expectEqual(wl.INPUT_QUEUE_CAPACITY, capped.len);
    try std.testing.expectEqual(@as(usize, 140 - wl.INPUT_QUEUE_CAPACITY), client.dropped_input_events);
}

fn readPeerBytes(peer_fd: i32, out: []u8) !usize {
    var total: usize = 0;
    while (total < out.len) {
        const rc = linux.recvfrom(peer_fd, out[total..].ptr, out.len - total, 0, null, null);
        const err = linux.errno(rc);
        switch (err) {
            .SUCCESS => {
                if (rc == 0) break;
                total += rc;
            },
            .AGAIN => break,
            .INTR => continue,
            else => return error.RecvFailed,
        }
    }
    return total;
}

test "createLayerSurface and handleLayerConfigure write real Wayland wire frames to loopback peer socket" {
    var client = try wl.WaylandClient.initLoopback(std.testing.allocator);
    defer client.deinit();

    try std.testing.expect(client.fd() >= 0);
    try std.testing.expect(client.peerFd() >= 0);

    try client.simulateRegistryGlobal(10, "wl_compositor", 5);
    try client.simulateRegistryGlobal(20, "zwlr_layer_shell_v1", 4);
    try client.simulateRegistryGlobal(30, "wp_fractional_scale_manager_v1", 1);
    try client.simulateRegistryGlobal(40, "xdg_wm_base", 3);
    try client.simulateRegistryGlobal(50, "wl_output", 4);
    try std.testing.expect(client.hasXdgShell());
    try std.testing.expectEqual(@as(usize, 1), client.outputs.items.len);

    // Drain initial registry + global bind wire bytes first
    var discard_buf: [2048]u8 = undefined;
    const init_bytes = try readPeerBytes(client.peerFd(), &discard_buf);
    try std.testing.expect(init_bytes > 0);

    // Verify first wire frame was wl_display.get_registry(2)
    var dec0 = try wl.WireDecoder.init(discard_buf[0..init_bytes]);
    try std.testing.expectEqual(@as(u32, 1), dec0.object_id);
    try std.testing.expectEqual(@as(u16, 1), dec0.opcode);
    try std.testing.expectEqual(@as(u32, 2), try dec0.readU32());

    // Now create layer surface and configure it, then read & decode every emitted wire frame
    const surf = try client.createLayerSurface(.{
        .layer = .top,
        .anchor = .{ .top = true, .left = true, .right = true },
        .width = 0,
        .height = 36,
        .exclusive_zone = 36,
        .keyboard_interactivity = 1,
        .namespace = "stratifi-panel",
    });
    try client.handleLayerConfigure(surf.layer_surface_id, 4242, 2560, 36);

    // Fractional scale bounds check (valid vs invalid)
    client.handleFractionalScale(surf.surface_id, 150);
    try std.testing.expectApproxEqAbs(@as(f32, 1.25), client.getSurfaceScale(surf.surface_id).?, 0.001);
    client.handleFractionalScale(surf.surface_id, 20); // < 60 ignored
    client.handleFractionalScale(surf.surface_id, 2000); // > 1200 ignored
    try std.testing.expectApproxEqAbs(@as(f32, 1.25), client.getSurfaceScale(surf.surface_id).?, 0.001);

    var wire_buf: [2048]u8 = undefined;
    const n = try readPeerBytes(client.peerFd(), &wire_buf);
    try std.testing.expect(n > 0);

    var opcodes_seen: [16]struct { obj: u32, op: u16 } = undefined;
    var msg_count: usize = 0;
    var off: usize = 0;
    var saw_get_layer_surface = false;
    var saw_ack_configure = false;

    while (off < n) {
        var dec = try wl.WireDecoder.init(wire_buf[off..n]);
        opcodes_seen[msg_count] = .{ .obj = dec.object_id, .op = dec.opcode };
        msg_count += 1;

        if (dec.object_id == client.layer_shell_id and dec.opcode == 0) {
            const new_layer_id = try dec.readU32();
            const surf_id = try dec.readU32();
            const out_id = try dec.readU32();
            const layer_val = try dec.readU32();
            const ns = try dec.readString();
            try std.testing.expectEqual(surf.layer_surface_id, new_layer_id);
            try std.testing.expectEqual(surf.surface_id, surf_id);
            try std.testing.expectEqual(@as(u32, 0), out_id);
            try std.testing.expectEqual(@as(u32, @intFromEnum(wl.Layer.top)), layer_val);
            try std.testing.expectEqualStrings("stratifi-panel", ns);
            saw_get_layer_surface = true;
        } else if (dec.object_id == surf.layer_surface_id and dec.opcode == 6) {
            const ack_serial = try dec.readU32();
            try std.testing.expectEqual(@as(u32, 4242), ack_serial);
            saw_ack_configure = true;
        }
        off += dec.size;
    }

    // Expected 9 messages:
    // 1. wl_compositor.create_surface
    // 2. wp_fractional_scale_manager_v1.get_fractional_scale
    // 3. zwlr_layer_shell_v1.get_layer_surface
    // 4. zwlr_layer_surface_v1.set_size
    // 5. zwlr_layer_surface_v1.set_anchor
    // 6. zwlr_layer_surface_v1.set_exclusive_zone
    // 7. zwlr_layer_surface_v1.set_keyboard_interactivity
    // 8. wl_surface.commit
    // 9. zwlr_layer_surface_v1.ack_configure
    try std.testing.expectEqual(@as(usize, 9), msg_count);
    try std.testing.expect(saw_get_layer_surface);
    try std.testing.expect(saw_ack_configure);
    try std.testing.expectEqual(@as(u16, 6), opcodes_seen[7].op); // wl_surface.commit
    try std.testing.expectEqual(surf.surface_id, opcodes_seen[7].obj);
}

test "WaylandClient.readAndDispatch handles incoming compositor events over socketpair" {
    var client = try wl.WaylandClient.initLoopback(std.testing.allocator);
    defer client.deinit();

    // Helper to send a server->client wire message via peerFd
    const sendServer = struct {
        fn send(peer: i32, obj: u32, op: u16, build: *const fn (*wl.WireEncoder) anyerror!void) !void {
            var buf: [256]u8 = undefined;
            var enc = wl.WireEncoder.init(&buf);
            try build(&enc);
            const msg = try enc.finish(obj, op);
            const rc = linux.sendto(peer, msg.ptr, msg.len, linux.MSG.NOSIGNAL, null, 0);
            try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(rc));
        }
    }.send;

    const peer = client.peerFd();
    try sendServer(peer, client.registry_id, 0, struct {
        fn f(e: *wl.WireEncoder) !void {
            try e.writeU32(1);
            try e.writeString("wl_compositor");
            try e.writeU32(5);
        }
    }.f);
    try sendServer(peer, client.registry_id, 0, struct {
        fn f(e: *wl.WireEncoder) !void {
            try e.writeU32(2);
            try e.writeString("zwlr_layer_shell_v1");
            try e.writeU32(4);
        }
    }.f);
    try sendServer(peer, client.registry_id, 0, struct {
        fn f(e: *wl.WireEncoder) !void {
            try e.writeU32(3);
            try e.writeString("wp_fractional_scale_manager_v1");
            try e.writeU32(1);
        }
    }.f);
    try sendServer(peer, client.registry_id, 0, struct {
        fn f(e: *wl.WireEncoder) !void {
            try e.writeU32(4);
            try e.writeString("wl_seat");
            try e.writeU32(7);
        }
    }.f);

    const n1 = try client.readAndDispatch();
    try std.testing.expectEqual(@as(usize, 4), n1);
    try std.testing.expect(client.hasLayerShell());
    try std.testing.expect(client.hasFractionalScale());

    const surf = try client.createLayerSurface(.{ .height = 32, .namespace = "stratifi" });

    // Server sends seat capabilities (pointer + keyboard), preferred_scale, and layer configure
    try sendServer(peer, client.seat_id, 0, struct {
        fn f(e: *wl.WireEncoder) !void {
            try e.writeU32(3); // pointer | keyboard
        }
    }.f);
    var scale_buf: [32]u8 = undefined;
    var scale_enc = wl.WireEncoder.init(&scale_buf);
    try scale_enc.writeU32(240); // 2.0x
    const scale_msg = try scale_enc.finish(surf.fractional_scale_id, 0);
    _ = linux.sendto(peer, scale_msg.ptr, scale_msg.len, linux.MSG.NOSIGNAL, null, 0);

    var cfg_buf: [32]u8 = undefined;
    var cfg_enc = wl.WireEncoder.init(&cfg_buf);
    try cfg_enc.writeU32(777);
    try cfg_enc.writeU32(1280);
    try cfg_enc.writeU32(40);
    const cfg_msg = try cfg_enc.finish(surf.layer_surface_id, 0);
    _ = linux.sendto(peer, cfg_msg.ptr, cfg_msg.len, linux.MSG.NOSIGNAL, null, 0);

    const n2 = try client.readAndDispatch();
    try std.testing.expectEqual(@as(usize, 3), n2);
    try std.testing.expectApproxEqAbs(@as(f32, 2.0), client.getSurfaceScale(surf.surface_id).?, 0.001);
    const sz = client.getSurfaceSize(surf.surface_id).?;
    try std.testing.expectEqual(@as(u32, 1280), sz[0]);
    try std.testing.expectEqual(@as(u32, 40), sz[1]);
    try std.testing.expect(client.pointer_id != 0);
    try std.testing.expect(client.keyboard_id != 0);
}

fn sendAllPeer(peer: i32, data: []const u8) !void {
    var sent: usize = 0;
    while (sent < data.len) {
        const rc = linux.sendto(peer, data.ptr + sent, data.len - sent, linux.MSG.NOSIGNAL, null, 0);
        const err = linux.errno(rc);
        switch (err) {
            .SUCCESS => sent += rc,
            .INTR => continue,
            else => return error.SendFailed,
        }
    }
}

test "C1: readAndDispatch detects clean EOF, trailing truncated frames, and stops spinning" {
    // 1. Clean EOF with 0 bytes -> ConnectionClosed repeatedly
    {
        var client = try wl.WaylandClient.initLoopback(std.testing.allocator);
        defer client.deinit();

        _ = linux.shutdown(client.peerFd(), linux.SHUT.WR);
        try std.testing.expectError(error.ConnectionClosed, client.readAndDispatch());
        try std.testing.expectError(error.ConnectionClosed, client.readAndDispatch());
    }

    // 2. Complete message followed by clean EOF -> returns 1, then ConnectionClosed
    {
        var client = try wl.WaylandClient.initLoopback(std.testing.allocator);
        defer client.deinit();

        var buf: [64]u8 = undefined;
        var enc = wl.WireEncoder.init(&buf);
        try enc.writeU32(1);
        try enc.writeString("wl_compositor");
        try enc.writeU32(5);
        const msg = try enc.finish(client.registry_id, 0);
        try sendAllPeer(client.peerFd(), msg);
        _ = linux.shutdown(client.peerFd(), linux.SHUT.WR);

        try std.testing.expectEqual(@as(usize, 1), try client.readAndDispatch());
        try std.testing.expect(client.compositor_id != 0);
        try std.testing.expectError(error.ConnectionClosed, client.readAndDispatch());
    }

    // 3. Complete message + truncated trailing bytes followed by EOF -> dispatches complete, returns TruncatedMessage
    {
        var client = try wl.WaylandClient.initLoopback(std.testing.allocator);
        defer client.deinit();

        var buf: [64]u8 = undefined;
        var enc = wl.WireEncoder.init(&buf);
        try enc.writeU32(1);
        try enc.writeString("wl_compositor");
        try enc.writeU32(5);
        const msg = try enc.finish(client.registry_id, 0);
        try sendAllPeer(client.peerFd(), msg);
        // Send 4 trailing bytes (truncated header)
        try sendAllPeer(client.peerFd(), &[_]u8{ 1, 0, 0, 0 });
        _ = linux.shutdown(client.peerFd(), linux.SHUT.WR);

        try std.testing.expectError(error.TruncatedMessage, client.readAndDispatch());
        try std.testing.expect(client.compositor_id != 0);
        try std.testing.expectError(error.ConnectionClosed, client.readAndDispatch());
    }
}

test "C2: readAndDispatch compacts consumed frames on error and send_buf preserves partial-write framing" {
    // 1. Re-dispatch on error: [pointer_motion, wl_display.error] -> error compacts pointer_motion
    {
        var client = try wl.WaylandClient.initLoopback(std.testing.allocator);
        defer client.deinit();

        try client.simulateRegistryGlobal(1, "wl_seat", 7);
        var cap_buf: [16]u8 = undefined;
        var cap_enc = wl.WireEncoder.init(&cap_buf);
        try cap_enc.writeU32(1); // pointer capability
        try sendAllPeer(client.peerFd(), try cap_enc.finish(client.seat_id, 0));
        try std.testing.expectEqual(@as(usize, 1), try client.readAndDispatch());

        var motion_buf: [32]u8 = undefined;
        var motion_enc = wl.WireEncoder.init(&motion_buf);
        try motion_enc.writeU32(100); // time
        try motion_enc.writeFixed(42.5);
        try motion_enc.writeFixed(84.25);
        const motion_msg = try motion_enc.finish(client.pointer_id, 2);

        var err_buf: [16]u8 = undefined;
        var err_enc = wl.WireEncoder.init(&err_buf);
        const err_msg = try err_enc.finish(wl.WL_DISPLAY_ID, 0);

        try sendAllPeer(client.peerFd(), motion_msg);
        try sendAllPeer(client.peerFd(), err_msg);

        try std.testing.expectError(error.WaylandProtocolError, client.readAndDispatch());
        try std.testing.expectEqual(@as(usize, 1), client.drainInputEvents().len);

        // Second call hits the error frame directly without re-dispatching pointer_motion
        try std.testing.expectError(error.WaylandProtocolError, client.readAndDispatch());
        try std.testing.expectEqual(@as(usize, 0), client.drainInputEvents().len);
    }

    // 2. Partial-write framing: saturate small SO_SNDBUF, buffer in send_buf, flush intact frames
    {
        var client = try wl.WaylandClient.initLoopback(std.testing.allocator);
        defer client.deinit();

        // Drain initial get_registry
        var init_drain: [128]u8 = undefined;
        _ = try readPeerBytes(client.peerFd(), &init_drain);

        var sndbuf: i32 = 4096;
        _ = linux.setsockopt(client.fd(), linux.SOL.SOCKET, linux.SO.SNDBUF, @ptrCast(&sndbuf), @sizeOf(i32));

        try client.simulateRegistryGlobal(1, "wl_compositor", 5);
        try client.simulateRegistryGlobal(2, "zwlr_layer_shell_v1", 4);

        // Create surfaces until kernel send buffer fills and send_buf buffers the unsent tail
        var created: usize = 0;
        var saw_pending = false;
        while (created < 64) : (created += 1) {
            _ = try client.createLayerSurface(.{ .width = 100, .height = 32, .namespace = "partial-frame-test-namespace" });
            if (client.hasPendingSend()) {
                saw_pending = true;
                break;
            }
        }
        try std.testing.expect(saw_pending);
        try std.testing.expectError(error.WouldBlock, client.flushSend());

        // Drain peer socket, then flush remaining buffered bytes from send_buf
        var all_bytes: [65536]u8 = undefined;
        var total_read: usize = 0;
        while (true) {
            const n = try readPeerBytes(client.peerFd(), all_bytes[total_read..]);
            total_read += n;
            if (!client.hasPendingSend()) break;
            client.flushSend() catch |err| switch (err) {
                error.WouldBlock => continue,
                else => return err,
            };
        }
        try std.testing.expect(!client.hasPendingSend());
        try std.testing.expect(total_read > 0);

        // Every single wire frame must decode cleanly with zero torn packets
        var off: usize = 0;
        var frames: usize = 0;
        while (off < total_read) {
            const dec = try wl.WireDecoder.init(all_bytes[off..total_read]);
            off += dec.size;
            frames += 1;
        }
        try std.testing.expectEqual(total_read, off);
        try std.testing.expect(frames >= 2 + (created + 1) * 7);
    }
}

test "C3 & C4: double deinit is idempotent and connect() cleans up fd cleanly on failure and success" {
    // Double deinit on loopback client
    var client = try wl.WaylandClient.initLoopback(std.testing.allocator);
    try client.simulateRegistryGlobal(1, "wl_output", 4);
    try client.simulateRegistryGlobal(2, "wl_compositor", 5);
    try client.simulateRegistryGlobal(3, "zwlr_layer_shell_v1", 4);
    _ = try client.createLayerSurface(.{ .namespace = "double-deinit" });

    client.deinit();
    try std.testing.expectEqual(@as(i32, -1), client.fd());
    try std.testing.expectEqual(@as(i32, -1), client.peerFd());
    try std.testing.expectEqual(@as(usize, 0), client.recv_buf.len);
    try std.testing.expectEqual(@as(usize, 0), client.send_buf.len);
    client.deinit(); // Second deinit must be safe and leak-free

    // Nonexistent socket path must fail cleanly without double-close
    try std.testing.expectError(
        error.FileNotFound,
        wl.WaylandClient.connect(std.testing.allocator, "/tmp/ziggui-nonexistent-wl-test-99999.sock"),
    );

    // Real AF_UNIX listening socket connect() roundtrip
    var path_buf: [108]u8 = undefined;
    const sock_path = try std.fmt.bufPrint(&path_buf, "/tmp/ziggui-wl-conn-{d}.sock", .{linux.getpid()});
    path_buf[sock_path.len] = 0;
    const sock_path_z: [*:0]const u8 = @ptrCast(path_buf[0..sock_path.len :0]);
    _ = linux.unlink(sock_path_z);
    defer _ = linux.unlink(sock_path_z);

    const srv_rc = linux.socket(linux.AF.UNIX, linux.SOCK.STREAM | linux.SOCK.NONBLOCK | linux.SOCK.CLOEXEC, 0);
    try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(srv_rc));
    const srv_fd: i32 = @intCast(srv_rc);
    defer _ = linux.close(srv_fd);

    var addr = linux.sockaddr.un{ .family = linux.AF.UNIX, .path = [_]u8{0} ** 108 };
    @memcpy(addr.path[0..sock_path.len], sock_path);
    const addr_len: linux.socklen_t = @intCast(@offsetOf(linux.sockaddr.un, "path") + sock_path.len + 1);
    try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(linux.bind(srv_fd, @ptrCast(&addr), addr_len)));
    try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(linux.listen(srv_fd, 4)));

    var real_client = try wl.WaylandClient.connect(std.testing.allocator, sock_path_z);
    defer real_client.deinit();

    const acc_rc = linux.accept4(srv_fd, null, null, linux.SOCK.NONBLOCK | linux.SOCK.CLOEXEC);
    try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(acc_rc));
    const acc_fd: i32 = @intCast(acc_rc);
    defer _ = linux.close(acc_fd);

    var req_buf: [64]u8 = undefined;
    const n = try readPeerBytes(acc_fd, &req_buf);
    try std.testing.expect(n >= 12);
    const dec = try wl.WireDecoder.init(req_buf[0..n]);
    try std.testing.expectEqual(wl.WL_DISPLAY_ID, dec.object_id);
    try std.testing.expectEqual(@as(u16, 1), dec.opcode); // get_registry
}

test "H6: recv_buf handles 16KB wire messages and fragmented multi-read packets" {
    var client = try wl.WaylandClient.initLoopback(std.testing.allocator);
    defer client.deinit();

    // 1. 16KB+ valid Wayland wire message (e.g. wl_registry.global with long interface name)
    var big_iface: [16384]u8 = undefined;
    @memset(&big_iface, 'x');
    var big_buf: [20480]u8 = undefined;
    var enc = wl.WireEncoder.init(&big_buf);
    try enc.writeU32(99);
    try enc.writeString(&big_iface);
    try enc.writeU32(1);
    const big_msg = try enc.finish(client.registry_id, 0);
    try std.testing.expect(big_msg.len > 16384);

    // Deliver in two fragments across two readAndDispatch() calls
    const split = 4096;
    try sendAllPeer(client.peerFd(), big_msg[0..split]);
    try std.testing.expectEqual(@as(usize, 0), try client.readAndDispatch());
    try sendAllPeer(client.peerFd(), big_msg[split..]);
    try std.testing.expectEqual(@as(usize, 1), try client.readAndDispatch());

    // 2. Small packet split mid-header (3 bytes then remainder)
    var small_buf: [64]u8 = undefined;
    var small_enc = wl.WireEncoder.init(&small_buf);
    try small_enc.writeU32(1);
    try small_enc.writeString("wl_compositor");
    try small_enc.writeU32(5);
    const small_msg = try small_enc.finish(client.registry_id, 0);

    try sendAllPeer(client.peerFd(), small_msg[0..3]);
    try std.testing.expectEqual(@as(usize, 0), try client.readAndDispatch());
    try sendAllPeer(client.peerFd(), small_msg[3..]);
    try std.testing.expectEqual(@as(usize, 1), try client.readAndDispatch());
    try std.testing.expect(client.compositor_id != 0);
}

test "H7: findSurfaceBy*Id rejects id == 0 across surface types" {
    var client = try wl.WaylandClient.initLoopback(std.testing.allocator);
    defer client.deinit();

    try client.simulateRegistryGlobal(1, "wl_compositor", 5);
    try client.simulateRegistryGlobal(2, "xdg_wm_base", 3);
    try client.simulateRegistryGlobal(3, "zwlr_layer_shell_v1", 4);

    const xdg = try client.createXdgSurface(.{ .title = "win", .app_id = "dev.test" });
    const layer = try client.createLayerSurface(.{ .namespace = "bar" });

    // xdg surface has layer_surface_id == 0; layer surface has xdg_surface_id == 0
    try std.testing.expectError(error.UnknownSurface, client.handleLayerConfigure(0, 1, 500, 500));
    try std.testing.expectError(error.UnknownSurface, client.handleXdgConfigure(0, 2));

    client.handleFractionalScale(0, 240);
    try std.testing.expectEqual(@as(?f32, null), client.getSurfaceScale(0));
    try std.testing.expectEqual(@as(?[2]u32, null), client.getSurfaceSize(0));
    try std.testing.expect(!client.destroySurface(0));

    // Real IDs still resolve cleanly
    try client.handleXdgConfigure(xdg.xdg_surface_id, 10);
    try client.handleLayerConfigure(layer.layer_surface_id, 11, 800, 40);
}

test "H8: wl_pointer.enter updates coordinates and wl_pointer.leave does not emit focus_lost" {
    var client = try wl.WaylandClient.initLoopback(std.testing.allocator);
    defer client.deinit();

    try client.simulateRegistryGlobal(1, "wl_seat", 7);

    var cap_buf: [16]u8 = undefined;
    var cap_enc = wl.WireEncoder.init(&cap_buf);
    try cap_enc.writeU32(1); // pointer
    try sendAllPeer(client.peerFd(), try cap_enc.finish(client.seat_id, 0));
    try std.testing.expectEqual(@as(usize, 1), try client.readAndDispatch());
    try std.testing.expect(client.pointer_id != 0);

    // wl_pointer.enter (opcode 0: serial, surface, x, y)
    var enter_buf: [32]u8 = undefined;
    var enter_enc = wl.WireEncoder.init(&enter_buf);
    try enter_enc.writeU32(101);
    try enter_enc.writeU32(10);
    try enter_enc.writeFixed(250.5);
    try enter_enc.writeFixed(140.25);
    try sendAllPeer(client.peerFd(), try enter_enc.finish(client.pointer_id, 0));

    // wl_pointer.leave (opcode 1: serial, surface) - must NOT emit focus_lost
    var leave_buf: [16]u8 = undefined;
    var leave_enc = wl.WireEncoder.init(&leave_buf);
    try leave_enc.writeU32(102);
    try leave_enc.writeU32(10);
    try sendAllPeer(client.peerFd(), try leave_enc.finish(client.pointer_id, 1));

    // wl_pointer.button (opcode 3: serial, time, button, state)
    var btn_buf: [32]u8 = undefined;
    var btn_enc = wl.WireEncoder.init(&btn_buf);
    try btn_enc.writeU32(103);
    try btn_enc.writeU32(55);
    try btn_enc.writeU32(wl.BTN_LEFT);
    try btn_enc.writeU32(1);
    try sendAllPeer(client.peerFd(), try btn_enc.finish(client.pointer_id, 3));

    try std.testing.expectEqual(@as(usize, 3), try client.readAndDispatch());
    const evs = client.drainInputEvents();
    try std.testing.expectEqual(@as(usize, 2), evs.len);
    try std.testing.expect(evs[0] == .pointer_move);
    try std.testing.expectApproxEqAbs(@as(f32, 250.5), evs[0].pointer_move.x, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 140.25), evs[0].pointer_move.y, 0.01);
    try std.testing.expect(evs[1] == .pointer_down);
    try std.testing.expectApproxEqAbs(@as(f32, 250.5), evs[1].pointer_down.x, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 140.25), evs[1].pointer_down.y, 0.01);
}

test "H9: object ID ceiling, global_remove + re-bind, destroySurface, and dispatch/resource caps" {
    var client = try wl.WaylandClient.initLoopback(std.testing.allocator);
    defer client.deinit();

    // 1. global_remove removes output and allows re-bind
    try client.simulateRegistryGlobal(50, "wl_output", 4);
    try std.testing.expectEqual(@as(usize, 1), client.outputs.items.len);

    var rem_buf: [16]u8 = undefined;
    var rem_enc = wl.WireEncoder.init(&rem_buf);
    try rem_enc.writeU32(50);
    try sendAllPeer(client.peerFd(), try rem_enc.finish(client.registry_id, 1));
    try std.testing.expectEqual(@as(usize, 1), try client.readAndDispatch());
    try std.testing.expectEqual(@as(usize, 0), client.outputs.items.len);

    try client.simulateRegistryGlobal(50, "wl_output", 4);
    try std.testing.expectEqual(@as(usize, 1), client.outputs.items.len);

    // 2. MAX_OUTPUTS cap
    var g: u32 = 100;
    while (g < 170) : (g += 1) {
        try client.simulateRegistryGlobal(g, "wl_output", 4);
    }
    try std.testing.expectEqual(wl.MAX_OUTPUTS, client.outputs.items.len);

    // 3. MAX_SURFACES cap + destroySurface
    try client.simulateRegistryGlobal(1, "wl_compositor", 5);
    try client.simulateRegistryGlobal(2, "zwlr_layer_shell_v1", 4);

    var first_id: u32 = 0;
    var s_idx: usize = 0;
    while (s_idx < wl.MAX_SURFACES) : (s_idx += 1) {
        const h = try client.createLayerSurface(.{ .namespace = "cap-test" });
        if (s_idx == 0) first_id = h.surface_id;
        // Keep peer drained so kernel send buffer doesn't fill
        var drain: [2048]u8 = undefined;
        _ = try readPeerBytes(client.peerFd(), &drain);
    }
    try std.testing.expectError(error.TooManySurfaces, client.createLayerSurface(.{ .namespace = "overflow" }));
    try std.testing.expect(client.destroySurface(first_id));
    try std.testing.expect(!client.destroySurface(first_id));
    _ = try client.createLayerSurface(.{ .namespace = "after-destroy" });
    var drain2: [2048]u8 = undefined;
    _ = try readPeerBytes(client.peerFd(), &drain2);

    // 4. MAX_DISPATCH_PER_CALL = 256 cap
    var m_idx: usize = 0;
    while (m_idx < 260) : (m_idx += 1) {
        var rbuf: [16]u8 = undefined;
        var renc = wl.WireEncoder.init(&rbuf);
        try renc.writeU32(9999); // non-existent global remove (harmless)
        try sendAllPeer(client.peerFd(), try renc.finish(client.registry_id, 1));
    }
    try std.testing.expectEqual(wl.MAX_DISPATCH_PER_CALL, try client.readAndDispatch());
    try std.testing.expectEqual(@as(usize, 4), try client.readAndDispatch());

    // 5. Object ID ceiling
    client.next_id = wl.CLIENT_OBJECT_ID_LIMIT;
    try std.testing.expectError(error.ObjectIdExhausted, client.simulateRegistryGlobal(3, "wl_seat", 7));
}

test "H10: input queue coalesces pointer_move and evicts stale pointer_move for critical events" {
    var client = try wl.WaylandClient.initLoopback(std.testing.allocator);
    defer client.deinit();

    // 1. 130 consecutive pointer_move events coalesce to 1, followed by pointer_up
    var i: usize = 0;
    while (i < 130) : (i += 1) {
        client.handlePointerMotion(@floatFromInt(i), @floatFromInt(i * 2));
    }
    client.handlePointerButton(wl.BTN_LEFT, false);

    const evs1 = client.drainInputEvents();
    try std.testing.expectEqual(@as(usize, 2), evs1.len);
    try std.testing.expectEqual(@as(usize, 0), client.dropped_input_events);
    try std.testing.expect(evs1[0] == .pointer_move);
    try std.testing.expectApproxEqAbs(@as(f32, 129.0), evs1[0].pointer_move.x, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 258.0), evs1[0].pointer_move.y, 0.01);
    try std.testing.expect(evs1[1] == .pointer_up);

    // 2. Full queue with interleaved pointer_move evicts most recent pointer_move on pointer_up
    var j: usize = 0;
    while (j < wl.INPUT_QUEUE_CAPACITY) : (j += 1) {
        if (j % 2 == 0) {
            client.handleKey(wl.KEY_TAB, true, .{});
        } else {
            client.handlePointerMotion(@floatFromInt(j), 10.0);
        }
    }
    client.handlePointerButton(wl.BTN_LEFT, false);

    const evs2 = client.drainInputEvents();
    try std.testing.expectEqual(wl.INPUT_QUEUE_CAPACITY, evs2.len);
    try std.testing.expectEqual(@as(usize, 1), client.dropped_input_events);
    try std.testing.expect(evs2[evs2.len - 1] == .pointer_up);
}

test "M11-M13 & L15: surface pre-validation, output sanitization, socket path validation, NUL strings, and epoll timeout" {
    // M11: createLayerSurface & createXdgSurface validate strings before sending any wire bytes
    {
        var client = try wl.WaylandClient.initLoopback(std.testing.allocator);
        defer client.deinit();

        try client.simulateRegistryGlobal(1, "wl_compositor", 5);
        try client.simulateRegistryGlobal(2, "zwlr_layer_shell_v1", 4);
        try client.simulateRegistryGlobal(3, "xdg_wm_base", 3);

        var discard: [1024]u8 = undefined;
        _ = try readPeerBytes(client.peerFd(), &discard);

        try std.testing.expectError(error.InvalidString, client.createLayerSurface(.{ .namespace = "bad\x00ns" }));
        try std.testing.expectError(error.InvalidString, client.createXdgSurface(.{ .title = "bad\x00title" }));
        try std.testing.expectError(error.InvalidString, client.createXdgSurface(.{ .app_id = "bad\x00app" }));

        var huge_ns: [500]u8 = undefined;
        @memset(&huge_ns, 'a');
        try std.testing.expectError(error.MessageTooLarge, client.createLayerSurface(.{ .namespace = &huge_ns }));

        var check_empty: [128]u8 = undefined;
        try std.testing.expectEqual(@as(usize, 0), try readPeerBytes(client.peerFd(), &check_empty));
    }

    // M12: wl_output.mode and wl_output.scale sanitization
    {
        var client = try wl.WaylandClient.initLoopback(std.testing.allocator);
        defer client.deinit();

        try client.simulateRegistryGlobal(10, "wl_output", 4);
        const out_id = client.outputs.items[0].object_id;

        var mode_buf: [32]u8 = undefined;
        var mode_enc = wl.WireEncoder.init(&mode_buf);
        try mode_enc.writeU32(1); // current flag
        try mode_enc.writeI32(0); // invalid width
        try mode_enc.writeI32(-1080); // invalid height
        try mode_enc.writeI32(-60000); // invalid refresh
        try sendAllPeer(client.peerFd(), try mode_enc.finish(out_id, 1));

        var scale_buf: [16]u8 = undefined;
        var scale_enc = wl.WireEncoder.init(&scale_buf);
        try scale_enc.writeI32(0); // invalid scale
        try sendAllPeer(client.peerFd(), try scale_enc.finish(out_id, 3));

        try std.testing.expectEqual(@as(usize, 2), try client.readAndDispatch());
        try std.testing.expectEqual(@as(i32, 0), client.outputs.items[0].width_px);
        try std.testing.expectEqual(@as(i32, 0), client.outputs.items[0].height_px);
        try std.testing.expectEqual(@as(i32, 60000), client.outputs.items[0].refresh_mhz);
        try std.testing.expectEqual(@as(i32, 1), client.outputs.items[0].scale_int);
    }

    // M13: resolveSocketPath NUL rejection, absolute path, PathTooLong
    {
        var path_buf: [128]u8 = undefined;
        try std.testing.expectError(error.InvalidPath, wl.resolveSocketPath("/run\x00/user", "wayland-0", &path_buf));
        try std.testing.expectError(error.InvalidPath, wl.resolveSocketPath("/run/user", "wayland\x00-0", &path_buf));

        const abs = try wl.resolveSocketPath("", "/tmp/wayland-custom-0", &path_buf);
        try std.testing.expectEqualStrings("/tmp/wayland-custom-0", std.mem.span(abs));

        var long_dir: [110]u8 = undefined;
        @memset(&long_dir, 'd');
        try std.testing.expectError(error.PathTooLong, wl.resolveSocketPath(&long_dir, "wl-0", &path_buf));

        var tiny_buf: [8]u8 = undefined;
        try std.testing.expectError(error.PathTooLong, wl.resolveSocketPath("/run", "wayland-0", &tiny_buf));
    }

    // WireDecoder.readString embedded NUL rejection
    {
        var raw_str: [16]u8 = [_]u8{0} ** 16;
        std.mem.writeInt(u32, raw_str[0..4], 1, native_endian);
        std.mem.writeInt(u32, raw_str[4..8], (@as(u32, 16) << 16) | 0, native_endian);
        std.mem.writeInt(u32, raw_str[8..12], 4, native_endian);
        @memcpy(raw_str[12..16], "a\x00b\x00");
        var dec = try wl.WireDecoder.init(&raw_str);
        try std.testing.expectError(error.InvalidString, dec.readString());
    }

    // L15: EpollLoop.wait rejects timeout_ms < -1
    {
        var ep = try wl.EpollLoop.init();
        defer ep.deinit();
        try std.testing.expectError(error.InvalidArgument, ep.wait(-2));
    }
}
