const std = @import("std");
const builtin = @import("builtin");
const linux = std.os.linux;
const core = @import("core.zig");
const focus = @import("focus.zig");
const a11y = @import("a11y.zig");

pub const MAX_REQ_BYTES: usize = 4096;
pub const MAX_CLIENTS: usize = 8;
const MAX_IDLE_POLLS: u32 = 64;
const MAX_CLIENT_PUMPS: usize = 128;

// Kernel `struct stat` matching Linux ABI for `fstatat64` (Linux 3.10+ / Android API 24+).
const KernelStat = switch (builtin.target.cpu.arch) {
    .x86_64 => extern struct {
        dev: u64,
        ino: u64,
        nlink: u64,
        mode: u32,
        uid: u32,
        gid: u32,
        __pad0: u32,
        rdev: u64,
        size: i64,
        blksize: i64,
        blocks: i64,
        atime_sec: i64,
        atime_nsec: i64,
        mtime_sec: i64,
        mtime_nsec: i64,
        ctime_sec: i64,
        ctime_nsec: i64,
        __unused: [3]i64,
    },
    .aarch64, .riscv64, .loongarch64 => extern struct {
        dev: u64,
        ino: u64,
        mode: u32,
        nlink: u32,
        uid: u32,
        gid: u32,
        rdev: u64,
        __pad1: u64,
        size: i64,
        blksize: i32,
        __pad2: i32,
        blocks: i64,
        atime_sec: i64,
        atime_nsec: i64,
        mtime_sec: i64,
        mtime_nsec: i64,
        ctime_sec: i64,
        ctime_nsec: i64,
        __unused4: u32,
        __unused5: u32,
    },
    else => @compileError("Unsupported architecture for KernelStat"),
};

const Ucred = extern struct {
    pid: i32,
    uid: u32,
    gid: u32,
};

fn linuxFstatat(dirfd: i32, path: [*:0]const u8, st: *KernelStat, flags: u32) linux.E {
    const sys: linux.SYS = if (@hasField(linux.SYS, "fstatat64")) .fstatat64 else .newfstatat;
    while (true) {
        const rc = linux.syscall4(
            sys,
            @as(usize, @bitCast(@as(isize, dirfd))),
            @intFromPtr(path),
            @intFromPtr(st),
            flags,
        );
        const err = linux.errno(rc);
        if (err == .INTR) continue;
        return err;
    }
}

fn parseJsonFiniteF32(val: std.json.Value) ?f32 {
    return switch (val) {
        .float => |v| blk: {
            if (!std.math.isFinite(v)) break :blk null;
            const cast: f32 = @floatCast(v);
            if (!std.math.isFinite(cast)) break :blk null;
            break :blk cast;
        },
        .integer => |v| blk: {
            const cast: f32 = @floatFromInt(v);
            if (!std.math.isFinite(cast)) break :blk null;
            break :blk cast;
        },
        .number_string => |s| blk: {
            const parsed = std.fmt.parseFloat(f32, s) catch break :blk null;
            if (!std.math.isFinite(parsed)) break :blk null;
            break :blk parsed;
        },
        else => null,
    };
}

fn getRequiredString(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const val = obj.get(key) orelse return null;
    return switch (val) {
        .string => |s| s,
        else => null,
    };
}

fn writeActionResult(writer: anytype, ok: bool) !void {
    if (ok) {
        try writer.writeAll("{\"ok\":true}\n");
    } else {
        try writer.writeAll("{\"ok\":false,\"error\":\"action_rejected\"}\n");
    }
}

/// Parses a single NDJSON IPC request line, enforces `MAX_REQ_BYTES`, and
/// dispatches semantic inspection or action execution through `A11yTree`.
pub fn handleRequestJson(
    allocator: std.mem.Allocator,
    arena: *core.LayoutArena,
    fm: ?*focus.FocusManager,
    tree: *a11y.A11yTree,
    req_line: []const u8,
    writer: anytype,
) !void {
    if (req_line.len > MAX_REQ_BYTES) {
        try writer.writeAll("{\"ok\":false,\"error\":\"request_too_large\"}\n");
        return;
    }

    var parsed = std.json.parseFromSlice(
        std.json.Value,
        allocator,
        req_line,
        .{},
    ) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            try writer.writeAll("{\"ok\":false,\"error\":\"invalid_json\"}\n");
            return;
        },
    };
    defer parsed.deinit();

    const obj = switch (parsed.value) {
        .object => |o| o,
        else => {
            try writer.writeAll("{\"ok\":false,\"error\":\"invalid_json\"}\n");
            return;
        },
    };

    const cmd = getRequiredString(obj, "cmd") orelse {
        try writer.writeAll("{\"ok\":false,\"error\":\"invalid_cmd\"}\n");
        return;
    };

    if (std.mem.eql(u8, cmd, "inspect")) {
        try tree.syncFromArena(arena, fm);
        try writer.writeAll("{\"ok\":true,\"tree\":");
        try tree.writeAtSpiJson(writer);
        try writer.writeAll("}\n");
        return;
    }

    if (std.mem.eql(u8, cmd, "toggle") or
        std.mem.eql(u8, cmd, "click") or
        std.mem.eql(u8, cmd, "focus"))
    {
        const id_str = getRequiredString(obj, "id") orelse {
            try writer.writeAll("{\"ok\":false,\"error\":\"missing_id\"}\n");
            return;
        };
        const node_id = arena.findByTestId(id_str) orelse {
            try writer.writeAll("{\"ok\":false,\"error\":\"not_found\"}\n");
            return;
        };
        const req: a11y.A11yActionRequest = if (std.mem.eql(u8, cmd, "toggle"))
            .{ .toggle = node_id }
        else if (std.mem.eql(u8, cmd, "click"))
            .{ .click = node_id }
        else
            .{ .focus = node_id };

        try writeActionResult(writer, tree.invokeAction(arena, fm, req));
        return;
    }

    if (std.mem.eql(u8, cmd, "set_value")) {
        const id_str = getRequiredString(obj, "id") orelse {
            try writer.writeAll("{\"ok\":false,\"error\":\"missing_id\"}\n");
            return;
        };
        const node_id = arena.findByTestId(id_str) orelse {
            try writer.writeAll("{\"ok\":false,\"error\":\"not_found\"}\n");
            return;
        };
        const val_json = obj.get("value") orelse {
            try writer.writeAll("{\"ok\":false,\"error\":\"invalid_value\"}\n");
            return;
        };
        const val = parseJsonFiniteF32(val_json) orelse {
            try writer.writeAll("{\"ok\":false,\"error\":\"invalid_value\"}\n");
            return;
        };
        const ok = tree.invokeAction(arena, fm, .{
            .set_value = .{ .id = node_id, .value = val },
        });
        try writeActionResult(writer, ok);
        return;
    }

    if (std.mem.eql(u8, cmd, "scroll")) {
        const id_str = getRequiredString(obj, "id") orelse {
            try writer.writeAll("{\"ok\":false,\"error\":\"missing_id\"}\n");
            return;
        };
        const node_id = arena.findByTestId(id_str) orelse {
            try writer.writeAll("{\"ok\":false,\"error\":\"not_found\"}\n");
            return;
        };
        const x_json = obj.get("x");
        const y_json = obj.get("y");
        if (x_json == null and y_json == null) {
            try writer.writeAll("{\"ok\":false,\"error\":\"invalid_scroll\"}\n");
            return;
        }
        const cur_scroll = arena.getScroll(node_id) orelse [2]f32{ 0.0, 0.0 };
        const sx: f32 = if (x_json) |xv| (parseJsonFiniteF32(xv) orelse {
            try writer.writeAll("{\"ok\":false,\"error\":\"invalid_scroll\"}\n");
            return;
        }) else cur_scroll[0];
        const sy: f32 = if (y_json) |yv| (parseJsonFiniteF32(yv) orelse {
            try writer.writeAll("{\"ok\":false,\"error\":\"invalid_scroll\"}\n");
            return;
        }) else cur_scroll[1];

        const ok = tree.invokeAction(arena, fm, .{
            .scroll = .{ .id = node_id, .x = sx, .y = sy },
        });
        try writeActionResult(writer, ok);
        return;
    }

    try writer.writeAll("{\"ok\":false,\"error\":\"unknown_cmd\"}\n");
}

fn validateUnixPath(path: [*:0]const u8) ![]const u8 {
    const slice = std.mem.span(path);
    if (slice.len == 0) return error.InvalidPath;
    if (slice.len >= 108) return error.PathTooLong;
    return slice;
}

fn initUnixAddr(path_slice: []const u8) struct { addr: linux.sockaddr.un, len: linux.socklen_t } {
    var addr: linux.sockaddr.un = .{
        .family = linux.AF.UNIX,
        .path = @splat(0),
    };
    @memcpy(addr.path[0..path_slice.len], path_slice);
    const len: linux.socklen_t = @intCast(@offsetOf(linux.sockaddr.un, "path") + path_slice.len + 1);
    return .{ .addr = addr, .len = len };
}

const ClientPhase = enum {
    reading,
    writing,
};

const ClientSlot = struct {
    fd: i32 = -1,
    req_buf: [MAX_REQ_BYTES + 2]u8 = undefined,
    req_len: usize = 0,
    resp_buf: std.ArrayList(u8) = .empty,
    resp_sent: usize = 0,
    phase: ClientPhase = .reading,
    idle_polls: u32 = 0,

    fn isActive(self: *const ClientSlot) bool {
        return self.fd >= 0;
    }

    fn close(self: *ClientSlot, allocator: std.mem.Allocator) void {
        if (self.fd >= 0) {
            _ = linux.close(self.fd);
            self.fd = -1;
        }
        self.req_len = 0;
        self.resp_sent = 0;
        self.phase = .reading;
        self.idle_polls = 0;
        self.resp_buf.deinit(allocator);
        self.resp_buf = .empty;
    }
};

fn findFreeSlot(clients: *[MAX_CLIENTS]ClientSlot) ?*ClientSlot {
    for (clients) |*slot| {
        if (!slot.isActive()) return slot;
    }
    return null;
}

fn beginStaticResponse(allocator: std.mem.Allocator, slot: *ClientSlot, msg: []const u8) !void {
    slot.resp_buf.clearRetainingCapacity();
    try slot.resp_buf.appendSlice(allocator, msg);
    slot.resp_sent = 0;
    slot.phase = .writing;
    slot.idle_polls = 0;
}

fn beginJsonResponse(
    allocator: std.mem.Allocator,
    slot: *ClientSlot,
    arena: *core.LayoutArena,
    fm: ?*focus.FocusManager,
    tree: *a11y.A11yTree,
    req_line: []const u8,
) !void {
    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    try handleRequestJson(allocator, arena, fm, tree, req_line, &aw.writer);
    slot.resp_buf.clearRetainingCapacity();
    try slot.resp_buf.appendSlice(allocator, aw.written());
    slot.resp_sent = 0;
    slot.phase = .writing;
    slot.idle_polls = 0;
}

/// Non-blocking `AF_UNIX` `SOCK_STREAM` server for local NDJSON inspection and control.
pub const IpcServer = struct {
    fd: i32 = -1,
    path_buf: [108]u8 = @splat(0),
    path_len: usize = 0,
    allocator: std.mem.Allocator,
    clients: [MAX_CLIENTS]ClientSlot = @splat(.{}),

    pub fn bind(allocator: std.mem.Allocator, path: [*:0]const u8) !IpcServer {
        const path_slice = try validateUnixPath(path);

        var st: KernelStat = undefined;
        const st_err = linuxFstatat(linux.AT.FDCWD, path, &st, linux.AT.SYMLINK_NOFOLLOW);
        switch (st_err) {
            .SUCCESS => {
                if (!linux.S.ISSOCK(st.mode) or st.uid != linux.geteuid()) {
                    return error.AddressInUse;
                }
                _ = linux.unlink(path);
            },
            .NOENT => {},
            .ACCES, .PERM => return error.AccessDenied,
            .NOTDIR => return error.NotDir,
            .NAMETOOLONG => return error.PathTooLong,
            else => {},
        }

        const sock_rc = linux.socket(
            linux.AF.UNIX,
            linux.SOCK.STREAM | linux.SOCK.NONBLOCK | linux.SOCK.CLOEXEC,
            0,
        );
        const sock_err = linux.errno(sock_rc);
        if (sock_err != .SUCCESS) {
            return switch (sock_err) {
                .MFILE => error.ProcessFdQuotaExceeded,
                .NFILE => error.SystemFdQuotaExceeded,
                .NOMEM => error.SystemResources,
                .ACCES, .PERM => error.AccessDenied,
                else => error.SocketFailed,
            };
        }
        const fd: i32 = @intCast(sock_rc);
        errdefer _ = linux.close(fd);

        _ = linux.fchmod(fd, 0o600);

        const uaddr = initUnixAddr(path_slice);
        const bind_rc = linux.bind(fd, @ptrCast(&uaddr.addr), uaddr.len);
        const bind_err = linux.errno(bind_rc);
        if (bind_err != .SUCCESS) {
            return switch (bind_err) {
                .ACCES, .PERM => error.AccessDenied,
                .ADDRINUSE => error.AddressInUse,
                .NOENT => error.FileNotFound,
                .NOTDIR => error.NotDir,
                .NAMETOOLONG => error.PathTooLong,
                else => error.BindFailed,
            };
        }
        errdefer _ = linux.unlink(path);

        const listen_rc = linux.listen(fd, MAX_CLIENTS);
        if (linux.errno(listen_rc) != .SUCCESS) {
            return error.ListenFailed;
        }

        var srv = IpcServer{
            .fd = fd,
            .path_buf = @splat(0),
            .path_len = path_slice.len,
            .allocator = allocator,
        };
        @memcpy(srv.path_buf[0..path_slice.len], path_slice);
        return srv;
    }

    pub fn deinit(self: *IpcServer) void {
        for (&self.clients) |*slot| {
            slot.close(self.allocator);
        }
        if (self.fd >= 0) {
            _ = linux.close(self.fd);
            self.fd = -1;
        }
        if (self.path_len > 0 and self.path_len < self.path_buf.len) {
            self.path_buf[self.path_len] = 0;
            _ = linux.unlink(@ptrCast(&self.path_buf));
            self.path_len = 0;
        }
    }

    pub fn listenFd(self: *const IpcServer) i32 {
        return self.fd;
    }

    /// Zero-blocking single-step pump: accepts new peer-credential-verified clients
    /// into free slots, performs one non-blocking `read` per `.reading` slot
    /// (requiring strict `\n` framing before dispatch), and one non-blocking
    /// `sendto(..., MSG.NOSIGNAL)` per `.writing` slot.
    pub fn pollOnce(
        self: *IpcServer,
        arena: *core.LayoutArena,
        fm: ?*focus.FocusManager,
        tree: *a11y.A11yTree,
    ) !usize {
        if (self.fd < 0) return 0;

        // (a) Non-blocking accept4 into free client slots
        while (findFreeSlot(&self.clients)) |slot| {
            const acc_rc = linux.accept4(
                self.fd,
                null,
                null,
                linux.SOCK.NONBLOCK | linux.SOCK.CLOEXEC,
            );
            const acc_err = linux.errno(acc_rc);
            switch (acc_err) {
                .SUCCESS => {},
                .INTR, .CONNABORTED => continue,
                .AGAIN, .MFILE, .NFILE, .NOBUFS, .NOMEM, .PERM, .PROTO => break,
                else => break,
            }

            const client_fd: i32 = @intCast(acc_rc);
            var cred: Ucred = undefined;
            var cred_len: linux.socklen_t = @sizeOf(Ucred);
            const cred_rc = linux.getsockopt(
                client_fd,
                linux.SOL.SOCKET,
                linux.SO.PEERCRED,
                @ptrCast(&cred),
                &cred_len,
            );
            if (linux.errno(cred_rc) != .SUCCESS or
                cred_len < @sizeOf(Ucred) or
                cred.uid != linux.geteuid())
            {
                _ = linux.close(client_fd);
                continue;
            }

            slot.fd = client_fd;
            slot.req_len = 0;
            slot.resp_sent = 0;
            slot.phase = .reading;
            slot.idle_polls = 0;
            slot.resp_buf.clearRetainingCapacity();
        }

        var handled: usize = 0;

        // (b) & (c) Advance active client slots without blocking
        for (&self.clients) |*slot| {
            if (!slot.isActive()) continue;

            if (slot.phase == .reading) {
                const cap_left = slot.req_buf.len - slot.req_len;
                if (cap_left == 0) {
                    try beginStaticResponse(self.allocator, slot, "{\"ok\":false,\"error\":\"request_too_large\"}\n");
                    handled += 1;
                } else {
                    const r_rc = linux.read(slot.fd, slot.req_buf[slot.req_len..].ptr, cap_left);
                    const r_err = linux.errno(r_rc);
                    switch (r_err) {
                        .SUCCESS => {
                            const n: usize = @intCast(r_rc);
                            if (n == 0) {
                                // EOF without '\n': reject truncated command cleanly.
                                slot.close(self.allocator);
                                continue;
                            }
                            const prev_len = slot.req_len;
                            slot.req_len += n;
                            slot.idle_polls = 0;

                            if (std.mem.indexOfScalar(u8, slot.req_buf[prev_len..slot.req_len], '\n')) |rel_nl| {
                                const nl_pos = prev_len + rel_nl;
                                var line_end = nl_pos;
                                if (line_end > 0 and slot.req_buf[line_end - 1] == '\r') {
                                    line_end -= 1;
                                }
                                if (line_end > MAX_REQ_BYTES) {
                                    try beginStaticResponse(self.allocator, slot, "{\"ok\":false,\"error\":\"request_too_large\"}\n");
                                } else {
                                    try beginJsonResponse(self.allocator, slot, arena, fm, tree, slot.req_buf[0..line_end]);
                                }
                                handled += 1;
                            } else if (slot.req_len > MAX_REQ_BYTES + 1 or
                                (slot.req_len == MAX_REQ_BYTES + 1 and slot.req_buf[MAX_REQ_BYTES] != '\r'))
                            {
                                try beginStaticResponse(self.allocator, slot, "{\"ok\":false,\"error\":\"request_too_large\"}\n");
                                handled += 1;
                            }
                        },
                        .AGAIN, .INTR => {
                            slot.idle_polls +|= 1;
                            if (slot.idle_polls >= MAX_IDLE_POLLS) {
                                slot.close(self.allocator);
                                continue;
                            }
                        },
                        else => {
                            slot.close(self.allocator);
                            continue;
                        },
                    }
                }
            }

            if (slot.phase == .writing) {
                const remaining = slot.resp_buf.items[slot.resp_sent..];
                if (remaining.len == 0) {
                    slot.close(self.allocator);
                    continue;
                }
                const w_rc = linux.sendto(
                    slot.fd,
                    remaining.ptr,
                    remaining.len,
                    linux.MSG.NOSIGNAL,
                    null,
                    0,
                );
                const w_err = linux.errno(w_rc);
                switch (w_err) {
                    .SUCCESS => {
                        const n: usize = @intCast(w_rc);
                        if (n == 0) {
                            slot.close(self.allocator);
                            continue;
                        }
                        slot.resp_sent += n;
                        slot.idle_polls = 0;
                        if (slot.resp_sent >= slot.resp_buf.items.len) {
                            slot.close(self.allocator);
                        }
                    },
                    .AGAIN, .INTR => {
                        slot.idle_polls +|= 1;
                        if (slot.idle_polls >= MAX_IDLE_POLLS) {
                            slot.close(self.allocator);
                        }
                    },
                    else => {
                        slot.close(self.allocator);
                    },
                }
            }
        }

        return handled;
    }
};

/// Connects an `AF_UNIX` client to `path`, sends `cmd_line`, optionally pumps
/// `server_opt` for single-threaded tests, and returns the owned response slice.
pub fn sendClientCommand(
    allocator: std.mem.Allocator,
    path: [*:0]const u8,
    cmd_line: []const u8,
    server_opt: ?*IpcServer,
    arena_opt: ?*core.LayoutArena,
    fm_opt: ?*focus.FocusManager,
    tree_opt: ?*a11y.A11yTree,
) ![]u8 {
    const path_slice = try validateUnixPath(path);

    const sock_rc = linux.socket(
        linux.AF.UNIX,
        linux.SOCK.STREAM | linux.SOCK.NONBLOCK | linux.SOCK.CLOEXEC,
        0,
    );
    if (linux.errno(sock_rc) != .SUCCESS) return error.SocketFailed;
    const client_fd: i32 = @intCast(sock_rc);
    defer _ = linux.close(client_fd);

    const uaddr = initUnixAddr(path_slice);
    var conn_pumps: usize = 0;
    while (true) {
        const conn_rc = linux.connect(client_fd, @ptrCast(&uaddr.addr), uaddr.len);
        const conn_err = linux.errno(conn_rc);
        switch (conn_err) {
            .SUCCESS, .ISCONN => break,
            .INTR => continue,
            .AGAIN => {
                if (conn_pumps >= MAX_CLIENT_PUMPS) return error.Timeout;
                conn_pumps += 1;
                if (server_opt) |srv| {
                    if (arena_opt != null and tree_opt != null) {
                        _ = try srv.pollOnce(arena_opt.?, fm_opt, tree_opt.?);
                        continue;
                    }
                }
                var pfd = [_]linux.pollfd{.{
                    .fd = client_fd,
                    .events = linux.POLL.OUT,
                    .revents = 0,
                }};
                _ = linux.poll(&pfd, 1, 10);
            },
            .INPROGRESS => {
                if (conn_pumps >= MAX_CLIENT_PUMPS) return error.Timeout;
                conn_pumps += 1;
                if (server_opt) |srv| {
                    if (arena_opt != null and tree_opt != null) {
                        _ = try srv.pollOnce(arena_opt.?, fm_opt, tree_opt.?);
                    }
                }
                var pfd = [_]linux.pollfd{.{
                    .fd = client_fd,
                    .events = linux.POLL.OUT,
                    .revents = 0,
                }};
                _ = linux.poll(&pfd, 1, 10);
                var so_err: i32 = 0;
                var so_len: linux.socklen_t = @sizeOf(i32);
                const opt_rc = linux.getsockopt(
                    client_fd,
                    linux.SOL.SOCKET,
                    linux.SO.ERROR,
                    @ptrCast(&so_err),
                    &so_len,
                );
                if (linux.errno(opt_rc) != .SUCCESS or so_err != 0) {
                    return error.ConnectFailed;
                }
                break;
            },
            else => return error.ConnectFailed,
        }
    }

    var sent: usize = 0;
    var write_broken = false;
    var write_pumps: usize = 0;
    while (sent < cmd_line.len) {
        const w_rc = linux.sendto(
            client_fd,
            cmd_line[sent..].ptr,
            cmd_line.len - sent,
            linux.MSG.NOSIGNAL,
            null,
            0,
        );
        const w_err = linux.errno(w_rc);
        switch (w_err) {
            .SUCCESS => {
                const n: usize = @intCast(w_rc);
                if (n == 0) break;
                sent += n;
            },
            .INTR => continue,
            .AGAIN => {
                if (write_pumps >= MAX_CLIENT_PUMPS) return error.Timeout;
                write_pumps += 1;
                if (server_opt) |srv| {
                    if (arena_opt != null and tree_opt != null) {
                        _ = try srv.pollOnce(arena_opt.?, fm_opt, tree_opt.?);
                        continue;
                    }
                }
                var pfd = [_]linux.pollfd{.{
                    .fd = client_fd,
                    .events = linux.POLL.OUT,
                    .revents = 0,
                }};
                _ = linux.poll(&pfd, 1, 10);
            },
            .PIPE, .CONNRESET => {
                write_broken = true;
                break;
            },
            else => return error.WriteFailed,
        }
    }

    if (server_opt) |srv| {
        if (arena_opt != null and tree_opt != null) {
            _ = try srv.pollOnce(arena_opt.?, fm_opt, tree_opt.?);
        }
    }

    var resp: std.ArrayList(u8) = .empty;
    errdefer resp.deinit(allocator);

    var tmp: [1024]u8 = undefined;
    var read_pumps: usize = 0;
    while (true) {
        const r_rc = linux.read(client_fd, &tmp, tmp.len);
        const r_err = linux.errno(r_rc);
        switch (r_err) {
            .SUCCESS => {
                const n: usize = @intCast(r_rc);
                if (n == 0) break;
                try resp.appendSlice(allocator, tmp[0..n]);
                if (std.mem.indexOfScalar(u8, tmp[0..n], '\n') != null) break;
            },
            .INTR => continue,
            .AGAIN => {
                if (read_pumps >= MAX_CLIENT_PUMPS) return error.Timeout;
                read_pumps += 1;
                if (server_opt) |srv| {
                    if (arena_opt != null and tree_opt != null) {
                        _ = try srv.pollOnce(arena_opt.?, fm_opt, tree_opt.?);
                        continue;
                    }
                }
                var pfd = [_]linux.pollfd{.{
                    .fd = client_fd,
                    .events = linux.POLL.IN,
                    .revents = 0,
                }};
                _ = linux.poll(&pfd, 1, 10);
            },
            .CONNRESET => break,
            else => return error.ReadFailed,
        }
    }

    if (write_broken and resp.items.len == 0) return error.WriteFailed;
    return resp.toOwnedSlice(allocator);
}
