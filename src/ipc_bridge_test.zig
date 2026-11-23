const std = @import("std");
const core = @import("core.zig");
const focus = @import("focus.zig");
const a11y = @import("a11y.zig");
const ipc = @import("ipc_bridge.zig");

test "IPC bridge handles inspect, toggle, set_value, and rejects invalid/disabled actions over JSON-RPC" {
    var arena = core.LayoutArena.init(std.testing.allocator);
    defer arena.deinit();
    const root = try arena.addNode(.{ .kind = .vstack, .role = .container, .test_id = "root" });
    const t1 = try arena.addChild(root, .{ .kind = .toggle, .role = .switch_control, .test_id = "settings.gpu_cache", .label = "GPU Cache", .height = 48.0, .checked = false });
    const s1 = try arena.addChild(root, .{ .kind = .slider, .role = .slider, .test_id = "settings.threads", .label = "Threads", .height = 48.0, .slider_val = 0.2 });
    arena.layout(400.0, 300.0);

    var fm = focus.FocusManager.init();
    var tree = a11y.A11yTree.init(std.testing.allocator);
    defer tree.deinit();

    // 1. Inspect returns valid JSON containing widget metadata
    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    try ipc.handleRequestJson(std.testing.allocator, &arena, &fm, &tree, "{\"cmd\":\"inspect\"}", &aw.writer);
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, aw.written(), .{});
    defer parsed.deinit();
    try std.testing.expect(parsed.value.object.get("ok").?.bool);
    try std.testing.expect(std.mem.indexOf(u8, aw.written(), "settings.gpu_cache") != null);

    // 2. Toggle via IPC mutates arena state cleanly
    aw.clearRetainingCapacity();
    try ipc.handleRequestJson(std.testing.allocator, &arena, &fm, &tree, "{\"cmd\":\"toggle\",\"id\":\"settings.gpu_cache\"}", &aw.writer);
    try std.testing.expect(arena.isChecked(t1).?);

    // 3. Set slider value via IPC
    aw.clearRetainingCapacity();
    try ipc.handleRequestJson(std.testing.allocator, &arena, &fm, &tree, "{\"cmd\":\"set_value\",\"id\":\"settings.threads\",\"value\":0.75}", &aw.writer);
    try std.testing.expectApproxEqAbs(@as(f32, 0.75), arena.getSliderValue(s1).?, 0.001);

    // 4. Unknown ID returns ok=false without crashing
    aw.clearRetainingCapacity();
    try ipc.handleRequestJson(std.testing.allocator, &arena, &fm, &tree, "{\"cmd\":\"toggle\",\"id\":\"nope\"}", &aw.writer);
    try std.testing.expect(std.mem.indexOf(u8, aw.written(), "\"ok\":false") != null);
}

test "IpcServer accepts real AF_UNIX client, serves NDJSON inspect + toggle, and cleans up socket" {
    var path_buf: [96]u8 = undefined;
    const pid = std.os.linux.getpid();
    const path = try std.fmt.bufPrintZ(&path_buf, "/tmp/ziggui_ipc_test_{d}.sock", .{pid});

    var server = try ipc.IpcServer.bind(std.testing.allocator, path);
    defer server.deinit();
    try std.testing.expect(server.listenFd() >= 0);

    var arena = core.LayoutArena.init(std.testing.allocator);
    defer arena.deinit();
    const root = try arena.addNode(.{ .kind = .vstack, .role = .container, .test_id = "root" });
    const t1 = try arena.addChild(root, .{ .kind = .toggle, .role = .switch_control, .test_id = "ipc.btn", .height = 48.0, .checked = false });
    arena.layout(300.0, 200.0);

    var fm = focus.FocusManager.init();
    var tree = a11y.A11yTree.init(std.testing.allocator);
    defer tree.deinit();

    // Connect a real AF_UNIX client and send NDJSON toggle command
    const resp = try ipc.sendClientCommand(std.testing.allocator, path, "{\"cmd\":\"toggle\",\"id\":\"ipc.btn\"}\n", &server, &arena, &fm, &tree);
    defer std.testing.allocator.free(resp);
    try std.testing.expect(std.mem.indexOf(u8, resp, "\"ok\":true") != null);
    try std.testing.expect(arena.isChecked(t1).?);

    // Inspect over real AF_UNIX client returns updated semantic tree JSON
    const inspect_resp = try ipc.sendClientCommand(std.testing.allocator, path, "{\"cmd\":\"inspect\"}\n", &server, &arena, &fm, &tree);
    defer std.testing.allocator.free(inspect_resp);
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, inspect_resp, .{});
    defer parsed.deinit();
    try std.testing.expect(parsed.value.object.get("ok").?.bool);
    try std.testing.expect(std.mem.indexOf(u8, inspect_resp, "ipc.btn") != null);

    // Double-deinit is safe and unlinks socket path
    server.deinit();
    server.deinit();
    try std.testing.expectEqual(@as(i32, -1), server.listenFd());
    try std.testing.expectError(error.ConnectFailed, ipc.sendClientCommand(std.testing.allocator, path, "{\"cmd\":\"inspect\"}\n", null, null, null, null));
}

test "IPC bridge rejects malformed JSON, oversized requests, and unknown commands" {
    var arena = core.LayoutArena.init(std.testing.allocator);
    defer arena.deinit();
    _ = try arena.addNode(.{ .kind = .vstack, .role = .container, .test_id = "root" });
    arena.layout(300.0, 200.0);

    var fm = focus.FocusManager.init();
    var tree = a11y.A11yTree.init(std.testing.allocator);
    defer tree.deinit();

    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();

    // 1. Malformed JSON syntax
    try ipc.handleRequestJson(std.testing.allocator, &arena, &fm, &tree, "{bad_json", &aw.writer);
    try std.testing.expect(std.mem.indexOf(u8, aw.written(), "\"ok\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, aw.written(), "invalid_json") != null);

    // 2. Non-object JSON
    aw.clearRetainingCapacity();
    try ipc.handleRequestJson(std.testing.allocator, &arena, &fm, &tree, "[1,2,3]", &aw.writer);
    try std.testing.expect(std.mem.indexOf(u8, aw.written(), "invalid_json") != null);

    // 3. Oversized request (> MAX_REQ_BYTES)
    aw.clearRetainingCapacity();
    var big_buf: [ipc.MAX_REQ_BYTES + 64]u8 = undefined;
    @memset(&big_buf, 'a');
    try ipc.handleRequestJson(std.testing.allocator, &arena, &fm, &tree, &big_buf, &aw.writer);
    try std.testing.expect(std.mem.indexOf(u8, aw.written(), "\"ok\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, aw.written(), "request_too_large") != null);

    // 4. Unknown command
    aw.clearRetainingCapacity();
    try ipc.handleRequestJson(std.testing.allocator, &arena, &fm, &tree, "{\"cmd\":\"frobnicate\"}", &aw.writer);
    try std.testing.expect(std.mem.indexOf(u8, aw.written(), "\"ok\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, aw.written(), "unknown_cmd") != null);

    // 5. Oversized request over real AF_UNIX socket
    var path_buf: [96]u8 = undefined;
    const pid = std.os.linux.getpid();
    const path = try std.fmt.bufPrintZ(&path_buf, "/tmp/ziggui_ipc_oversize_{d}.sock", .{pid});
    var server = try ipc.IpcServer.bind(std.testing.allocator, path);
    defer server.deinit();

    var big_line: [ipc.MAX_REQ_BYTES + 32]u8 = undefined;
    @memset(big_line[0 .. big_line.len - 1], 'x');
    big_line[big_line.len - 1] = '\n';
    const big_resp = try ipc.sendClientCommand(std.testing.allocator, path, &big_line, &server, &arena, &fm, &tree);
    defer std.testing.allocator.free(big_resp);
    try std.testing.expect(std.mem.indexOf(u8, big_resp, "request_too_large") != null);
}

test "IPC bridge rejects disabled and modal-trapped toggles and executes scroll command" {
    var arena = core.LayoutArena.init(std.testing.allocator);
    defer arena.deinit();

    const root = try arena.addNode(.{ .kind = .vstack, .role = .container, .test_id = "root" });
    const t_disabled = try arena.addChild(root, .{ .kind = .toggle, .role = .switch_control, .test_id = "toggle.disabled", .height = 48.0, .checked = false, .disabled = true });
    const t_outside = try arena.addChild(root, .{ .kind = .toggle, .role = .switch_control, .test_id = "toggle.outside", .height = 48.0, .checked = false });
    const modal = try arena.addChild(root, .{ .kind = .vstack, .role = .panel, .test_id = "modal", .height = 120.0 });
    const t_inside = try arena.addChild(modal, .{ .kind = .toggle, .role = .switch_control, .test_id = "toggle.inside", .height = 48.0, .checked = false });
    const scroller = try arena.addChild(modal, .{ .kind = .vstack, .role = .container, .test_id = "modal.list", .height = 60.0, .clip_children = true });
    _ = try arena.addChild(scroller, .{ .kind = .card, .role = .panel, .test_id = "modal.item", .height = 180.0, .fill = core.Nord.polar_night_1 });
    arena.layout(400.0, 400.0);

    var fm = focus.FocusManager.init();
    try fm.pushScope(&arena, modal, true);

    var tree = a11y.A11yTree.init(std.testing.allocator);
    defer tree.deinit();

    var path_buf: [96]u8 = undefined;
    const pid = std.os.linux.getpid();
    const path = try std.fmt.bufPrintZ(&path_buf, "/tmp/ziggui_ipc_scroll_{d}.sock", .{pid});
    var server = try ipc.IpcServer.bind(std.testing.allocator, path);
    defer server.deinit();

    // 1. Disabled toggle is rejected over IPC
    const resp_dis = try ipc.sendClientCommand(std.testing.allocator, path, "{\"cmd\":\"toggle\",\"id\":\"toggle.disabled\"}\n", &server, &arena, &fm, &tree);
    defer std.testing.allocator.free(resp_dis);
    try std.testing.expect(std.mem.indexOf(u8, resp_dis, "\"ok\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, resp_dis, "action_rejected") != null);
    try std.testing.expect(!arena.isChecked(t_disabled).?);

    // 2. Toggle outside modal trap is rejected over IPC
    const resp_out = try ipc.sendClientCommand(std.testing.allocator, path, "{\"cmd\":\"toggle\",\"id\":\"toggle.outside\"}\n", &server, &arena, &fm, &tree);
    defer std.testing.allocator.free(resp_out);
    try std.testing.expect(std.mem.indexOf(u8, resp_out, "\"ok\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, resp_out, "action_rejected") != null);
    try std.testing.expect(!arena.isChecked(t_outside).?);

    // 3. Toggle inside modal trap succeeds over IPC
    const resp_in = try ipc.sendClientCommand(std.testing.allocator, path, "{\"cmd\":\"toggle\",\"id\":\"toggle.inside\"}\n", &server, &arena, &fm, &tree);
    defer std.testing.allocator.free(resp_in);
    try std.testing.expect(std.mem.indexOf(u8, resp_in, "\"ok\":true") != null);
    try std.testing.expect(arena.isChecked(t_inside).?);

    // 4. Scroll command updates scroll offsets over IPC
    const resp_scroll = try ipc.sendClientCommand(std.testing.allocator, path, "{\"cmd\":\"scroll\",\"id\":\"modal.list\",\"x\":12.5,\"y\":45.0}\n", &server, &arena, &fm, &tree);
    defer std.testing.allocator.free(resp_scroll);
    try std.testing.expect(std.mem.indexOf(u8, resp_scroll, "\"ok\":true") != null);
    const sc = arena.getScroll(scroller).?;
    try std.testing.expectApproxEqAbs(@as(f32, 12.5), sc[0], 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 45.0), sc[1], 0.001);

    // 5. Scroll on non-scrollable container is rejected
    const resp_bad_scroll = try ipc.sendClientCommand(std.testing.allocator, path, "{\"cmd\":\"scroll\",\"id\":\"modal\",\"x\":0,\"y\":10}\n", &server, &arena, &fm, &tree);
    defer std.testing.allocator.free(resp_bad_scroll);
    try std.testing.expect(std.mem.indexOf(u8, resp_bad_scroll, "action_rejected") != null);

    // 6. Scroll with overflowing f32 float (1e40) is rejected
    const resp_inf_scroll = try ipc.sendClientCommand(std.testing.allocator, path, "{\"cmd\":\"scroll\",\"id\":\"modal.list\",\"x\":0,\"y\":1e40}\n", &server, &arena, &fm, &tree);
    defer std.testing.allocator.free(resp_inf_scroll);
    try std.testing.expect(std.mem.indexOf(u8, resp_inf_scroll, "\"ok\":false") != null);

    // 7. Focus and click commands over IPC
    const resp_focus = try ipc.sendClientCommand(std.testing.allocator, path, "{\"cmd\":\"focus\",\"id\":\"toggle.inside\"}\n", &server, &arena, &fm, &tree);
    defer std.testing.allocator.free(resp_focus);
    try std.testing.expect(std.mem.indexOf(u8, resp_focus, "\"ok\":true") != null);
    try std.testing.expectEqual(t_inside, fm.focused().?);

    const resp_click = try ipc.sendClientCommand(std.testing.allocator, path, "{\"cmd\":\"click\",\"id\":\"toggle.inside\"}\n", &server, &arena, &fm, &tree);
    defer std.testing.allocator.free(resp_click);
    try std.testing.expect(std.mem.indexOf(u8, resp_click, "\"ok\":true") != null);
    try std.testing.expect(!arena.isChecked(t_inside).?);

    // 8. pollOnce returns 0 when no clients are pending
    try std.testing.expectEqual(@as(usize, 0), try server.pollOnce(&arena, &fm, &tree));
}

test "IpcServer handles split slowloris framing, rejects EOF without newline, and evicts idle clients without blocking" {
    const linux = std.os.linux;
    var path_buf: [96]u8 = undefined;
    const pid = linux.getpid();
    const path = try std.fmt.bufPrintZ(&path_buf, "/tmp/ziggui_ipc_slowloris_{d}.sock", .{pid});

    var server = try ipc.IpcServer.bind(std.testing.allocator, path);
    defer server.deinit();

    var arena = core.LayoutArena.init(std.testing.allocator);
    defer arena.deinit();
    const root = try arena.addNode(.{ .kind = .vstack, .role = .container, .test_id = "root" });
    const t1 = try arena.addChild(root, .{ .kind = .toggle, .role = .switch_control, .test_id = "ipc.btn", .height = 48.0, .checked = false });
    arena.layout(300.0, 200.0);

    var fm = focus.FocusManager.init();
    var tree = a11y.A11yTree.init(std.testing.allocator);
    defer tree.deinit();

    // Helper: raw non-blocking AF_UNIX client connect
    const connectRaw = struct {
        fn call(sock_path: [*:0]const u8) !i32 {
            const pslice = std.mem.span(sock_path);
            const rc = linux.socket(linux.AF.UNIX, linux.SOCK.STREAM | linux.SOCK.NONBLOCK | linux.SOCK.CLOEXEC, 0);
            try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(rc));
            const fd: i32 = @intCast(rc);
            var addr: linux.sockaddr.un = .{ .family = linux.AF.UNIX, .path = [_]u8{0} ** 108 };
            @memcpy(addr.path[0..pslice.len], pslice);
            const alen: linux.socklen_t = @intCast(@offsetOf(linux.sockaddr.un, "path") + pslice.len + 1);
            try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(linux.connect(fd, @ptrCast(&addr), alen)));
            return fd;
        }
    }.call;

    // 1. Slowloris split write: send partial line without '\n', pollOnce must NOT block or execute
    const c1 = try connectRaw(path);
    defer _ = linux.close(c1);
    const part1 = "{\"cmd\":\"toggle\"";
    try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(linux.sendto(c1, part1.ptr, part1.len, linux.MSG.NOSIGNAL, null, 0)));
    try std.testing.expectEqual(@as(usize, 0), try server.pollOnce(&arena, &fm, &tree));
    try std.testing.expect(!arena.isChecked(t1).?);

    // Finish line with '\n' -> next pollOnce executes cleanly
    const part2 = ",\"id\":\"ipc.btn\"}\n";
    try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(linux.sendto(c1, part2.ptr, part2.len, linux.MSG.NOSIGNAL, null, 0)));
    try std.testing.expectEqual(@as(usize, 1), try server.pollOnce(&arena, &fm, &tree));
    try std.testing.expect(arena.isChecked(t1).?);

    var rbuf: [128]u8 = undefined;
    const rrc = linux.read(c1, &rbuf, rbuf.len);
    try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(rrc));
    try std.testing.expect(std.mem.indexOf(u8, rbuf[0..@intCast(rrc)], "\"ok\":true") != null);

    // 2. Truncated EOF without '\n' must NOT execute
    const c2 = try connectRaw(path);
    const trunc = "{\"cmd\":\"toggle\",\"id\":\"ipc.btn\"}";
    try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(linux.sendto(c2, trunc.ptr, trunc.len, linux.MSG.NOSIGNAL, null, 0)));
    _ = linux.close(c2);
    try std.testing.expectEqual(@as(usize, 0), try server.pollOnce(&arena, &fm, &tree));
    try std.testing.expect(arena.isChecked(t1).?); // still true, not toggled back!

    // 3. Stalled client eviction after bounded idle_polls
    var stalled_fds: [8]i32 = undefined;
    for (&stalled_fds) |*sfd| {
        sfd.* = try connectRaw(path);
    }
    defer for (stalled_fds) |sfd| {
        _ = linux.close(sfd);
    };
    var p: usize = 0;
    while (p < 70) : (p += 1) {
        _ = try server.pollOnce(&arena, &fm, &tree);
    }
    // Slots were freed by eviction, so a fresh client succeeds
    const resp = try ipc.sendClientCommand(std.testing.allocator, path, "{\"cmd\":\"toggle\",\"id\":\"ipc.btn\"}\n", &server, &arena, &fm, &tree);
    defer std.testing.allocator.free(resp);
    try std.testing.expect(std.mem.indexOf(u8, resp, "\"ok\":true") != null);
    try std.testing.expect(!arena.isChecked(t1).?);
}

test "IpcServer.bind refuses to unlink regular files and enforces CRLF / MAX_REQ_BYTES boundary framing" {
    const linux = std.os.linux;
    var reg_path_buf: [96]u8 = undefined;
    const pid = linux.getpid();
    const reg_path = try std.fmt.bufPrintZ(&reg_path_buf, "/tmp/ziggui_not_a_sock_{d}", .{pid});

    // Create a regular file at reg_path
    const fd_rc = linux.openat(linux.AT.FDCWD, reg_path, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, 0o644);
    try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(fd_rc));
    const reg_fd: i32 = @intCast(fd_rc);
    const sentinel = "keep-me";
    _ = linux.write(reg_fd, sentinel.ptr, sentinel.len);
    _ = linux.close(reg_fd);
    defer _ = linux.unlink(reg_path);

    // bind MUST fail with AddressInUse and leave regular file untouched
    try std.testing.expectError(error.AddressInUse, ipc.IpcServer.bind(std.testing.allocator, reg_path));
    const check_rc = linux.openat(linux.AT.FDCWD, reg_path, .{ .ACCMODE = .RDONLY }, 0);
    try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(check_rc));
    const check_fd: i32 = @intCast(check_rc);
    var check_buf: [16]u8 = undefined;
    const n_read: usize = @intCast(linux.read(check_fd, &check_buf, check_buf.len));
    _ = linux.close(check_fd);
    try std.testing.expectEqualStrings(sentinel, check_buf[0..n_read]);

    // Boundary framing tests: CRLF at 4096 bytes, empty "\n", and > MAX_REQ_BYTES without '\n'
    var sock_path_buf: [96]u8 = undefined;
    const sock_path = try std.fmt.bufPrintZ(&sock_path_buf, "/tmp/ziggui_ipc_crlf_{d}.sock", .{pid});
    var server = try ipc.IpcServer.bind(std.testing.allocator, sock_path);
    defer server.deinit();

    var arena = core.LayoutArena.init(std.testing.allocator);
    defer arena.deinit();
    const root = try arena.addNode(.{ .kind = .vstack, .role = .container, .test_id = "root" });
    _ = try arena.addChild(root, .{ .kind = .toggle, .role = .switch_control, .test_id = "ipc.btn", .height = 48.0, .checked = false });
    arena.layout(300.0, 200.0);

    var fm = focus.FocusManager.init();
    var tree = a11y.A11yTree.init(std.testing.allocator);
    defer tree.deinit();

    // Empty "\n" -> invalid_json
    const empty_resp = try ipc.sendClientCommand(std.testing.allocator, sock_path, "\n", &server, &arena, &fm, &tree);
    defer std.testing.allocator.free(empty_resp);
    try std.testing.expect(std.mem.indexOf(u8, empty_resp, "invalid_json") != null);

    // Exactly 4096-byte JSON + "\r\n" -> succeeds!
    var max_crlf: [ipc.MAX_REQ_BYTES + 2]u8 = undefined;
    const prefix = "{\"cmd\":\"toggle\",\"id\":\"ipc.btn\"";
    @memcpy(max_crlf[0..prefix.len], prefix);
    @memset(max_crlf[prefix.len .. ipc.MAX_REQ_BYTES - 1], ' ');
    max_crlf[ipc.MAX_REQ_BYTES - 1] = '}';
    max_crlf[ipc.MAX_REQ_BYTES] = '\r';
    max_crlf[ipc.MAX_REQ_BYTES + 1] = '\n';
    const max_resp = try ipc.sendClientCommand(std.testing.allocator, sock_path, &max_crlf, &server, &arena, &fm, &tree);
    defer std.testing.allocator.free(max_resp);
    try std.testing.expect(std.mem.indexOf(u8, max_resp, "\"ok\":true") != null);

    // 4096-byte JSON + "\r" in first packet, "\n" in second packet -> succeeds!
    const c_split_rc = linux.socket(linux.AF.UNIX, linux.SOCK.STREAM | linux.SOCK.NONBLOCK | linux.SOCK.CLOEXEC, 0);
    try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(c_split_rc));
    const c_split: i32 = @intCast(c_split_rc);
    defer _ = linux.close(c_split);
    var saddr: linux.sockaddr.un = .{ .family = linux.AF.UNIX, .path = [_]u8{0} ** 108 };
    @memcpy(saddr.path[0..sock_path.len], sock_path);
    const sal_len: linux.socklen_t = @intCast(@offsetOf(linux.sockaddr.un, "path") + sock_path.len + 1);
    try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(linux.connect(c_split, @ptrCast(&saddr), sal_len)));
    _ = linux.sendto(c_split, max_crlf[0 .. ipc.MAX_REQ_BYTES + 1].ptr, ipc.MAX_REQ_BYTES + 1, linux.MSG.NOSIGNAL, null, 0);
    try std.testing.expectEqual(@as(usize, 0), try server.pollOnce(&arena, &fm, &tree));
    _ = linux.sendto(c_split, max_crlf[ipc.MAX_REQ_BYTES + 1 ..].ptr, 1, linux.MSG.NOSIGNAL, null, 0);
    try std.testing.expectEqual(@as(usize, 1), try server.pollOnce(&arena, &fm, &tree));
    var split_rbuf: [128]u8 = undefined;
    const split_rrc = linux.read(c_split, &split_rbuf, split_rbuf.len);
    try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(split_rrc));
    try std.testing.expect(std.mem.indexOf(u8, split_rbuf[0..@intCast(split_rrc)], "\"ok\":true") != null);

    // > MAX_REQ_BYTES without '\n' -> request_too_large
    var no_nl_over: [ipc.MAX_REQ_BYTES + 8]u8 = undefined;
    @memset(&no_nl_over, 'z');
    const over_resp = try ipc.sendClientCommand(std.testing.allocator, sock_path, &no_nl_over, &server, &arena, &fm, &tree);
    defer std.testing.allocator.free(over_resp);
    try std.testing.expect(std.mem.indexOf(u8, over_resp, "request_too_large") != null);
}
