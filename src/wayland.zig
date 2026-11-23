const std = @import("std");
const builtin = @import("builtin");
const linux = std.os.linux;
const events = @import("events.zig");

const native_endian = builtin.target.cpu.arch.endian();

pub const MAX_WIRE_MSG_SIZE: usize = 65532;
pub const RECV_BUF_SIZE: usize = 65536;
pub const SEND_BUF_SIZE: usize = 65536;
pub const INPUT_QUEUE_CAPACITY: usize = 128;
pub const MAX_OUTPUTS: usize = 64;
pub const MAX_SURFACES: usize = 128;
pub const MAX_DISPATCH_PER_CALL: usize = 256;
pub const CLIENT_OBJECT_ID_LIMIT: u32 = 0xFF00_0000;

// Linux input event button codes (<linux/input-event-codes.h>)
pub const BTN_LEFT: u32 = 0x110;
pub const BTN_RIGHT: u32 = 0x111;
pub const BTN_MIDDLE: u32 = 0x112;

// Linux evdev keycodes (<linux/input-event-codes.h>)
pub const KEY_ESC: u32 = 1;
pub const KEY_BACKSPACE: u32 = 14;
pub const KEY_TAB: u32 = 15;
pub const KEY_ENTER: u32 = 28;
pub const KEY_SPACE: u32 = 57;
pub const KEY_KPENTER: u32 = 96;
pub const KEY_HOME: u32 = 102;
pub const KEY_UP: u32 = 103;
pub const KEY_LEFT: u32 = 105;
pub const KEY_RIGHT: u32 = 106;
pub const KEY_END: u32 = 107;
pub const KEY_DOWN: u32 = 108;

pub const Layer = enum(u32) {
    background = 0,
    bottom = 1,
    top = 2,
    overlay = 3,
};

pub const Anchor = packed struct(u32) {
    top: bool = false,
    bottom: bool = false,
    left: bool = false,
    right: bool = false,
    _pad: u28 = 0,
};

pub const LayerSurfaceDesc = struct {
    layer: Layer = .top,
    anchor: Anchor = .{},
    width: u32 = 0,
    height: u32 = 0,
    exclusive_zone: i32 = 0,
    keyboard_interactivity: u32 = 0,
    namespace: []const u8 = "huey",
};

pub const LayerSurfaceHandle = struct {
    surface_id: u32,
    layer_surface_id: u32,
    fractional_scale_id: u32,
};

pub const XdgSurfaceDesc = struct {
    title: []const u8 = "huey",
    app_id: []const u8 = "dev.huey.app",
};

pub const XdgSurfaceHandle = struct {
    surface_id: u32,
    xdg_surface_id: u32,
    xdg_toplevel_id: u32,
    fractional_scale_id: u32,
};

pub const OutputInfo = struct {
    global_name: u32,
    object_id: u32,
    width_px: i32 = 0,
    height_px: i32 = 0,
    refresh_mhz: i32 = 60000,
    scale_int: i32 = 1,
};

pub const SurfaceState = struct {
    surface_id: u32,
    layer_surface_id: u32 = 0,
    xdg_surface_id: u32 = 0,
    xdg_toplevel_id: u32 = 0,
    fractional_scale_id: u32 = 0,
    width: u32 = 0,
    height: u32 = 0,
    scale_factor: f32 = 1.0,
    configured: bool = false,
    closed: bool = false,
};

// Wayland protocol opcodes
pub const WL_DISPLAY_ID: u32 = 1;

const WL_DISPLAY_SYNC: u16 = 0;
const WL_DISPLAY_GET_REGISTRY: u16 = 1;
const WL_DISPLAY_EVT_ERROR: u16 = 0;
const WL_DISPLAY_EVT_DELETE_ID: u16 = 1;

const WL_REGISTRY_BIND: u16 = 0;
const WL_REGISTRY_EVT_GLOBAL: u16 = 0;
const WL_REGISTRY_EVT_GLOBAL_REMOVE: u16 = 1;

const WL_COMPOSITOR_CREATE_SURFACE: u16 = 0;

const WL_SURFACE_DESTROY: u16 = 0;
const WL_SURFACE_ATTACH: u16 = 1;
const WL_SURFACE_FRAME: u16 = 3;
const WL_SURFACE_COMMIT: u16 = 6;
const WL_SURFACE_DAMAGE_BUFFER: u16 = 9;

const XDG_WM_BASE_DESTROY: u16 = 0;
const XDG_WM_BASE_GET_XDG_SURFACE: u16 = 2;
const XDG_WM_BASE_PONG: u16 = 3;
const XDG_WM_BASE_EVT_PING: u16 = 0;

const XDG_SURFACE_DESTROY: u16 = 0;
const XDG_SURFACE_GET_TOPLEVEL: u16 = 1;
const XDG_SURFACE_ACK_CONFIGURE: u16 = 4;
const XDG_SURFACE_EVT_CONFIGURE: u16 = 0;

const XDG_TOPLEVEL_DESTROY: u16 = 0;
const XDG_TOPLEVEL_SET_TITLE: u16 = 2;
const XDG_TOPLEVEL_SET_APP_ID: u16 = 3;
const XDG_TOPLEVEL_EVT_CONFIGURE: u16 = 0;
const XDG_TOPLEVEL_EVT_CLOSE: u16 = 1;

const ZWLR_LAYER_SHELL_GET_LAYER_SURFACE: u16 = 0;

const ZWLR_LAYER_SURFACE_SET_SIZE: u16 = 0;
const ZWLR_LAYER_SURFACE_SET_ANCHOR: u16 = 1;
const ZWLR_LAYER_SURFACE_SET_EXCLUSIVE_ZONE: u16 = 2;
const ZWLR_LAYER_SURFACE_SET_KEYBOARD_INTERACTIVITY: u16 = 4;
const ZWLR_LAYER_SURFACE_ACK_CONFIGURE: u16 = 6;
const ZWLR_LAYER_SURFACE_DESTROY: u16 = 7;
const ZWLR_LAYER_SURFACE_EVT_CONFIGURE: u16 = 0;
const ZWLR_LAYER_SURFACE_EVT_CLOSED: u16 = 1;

const WP_FRACTIONAL_SCALE_MGR_GET_FRACTIONAL_SCALE: u16 = 1;
const WP_FRACTIONAL_SCALE_DESTROY: u16 = 0;
const WP_FRACTIONAL_SCALE_EVT_PREFERRED_SCALE: u16 = 0;

const WL_SEAT_GET_POINTER: u16 = 0;
const WL_SEAT_GET_KEYBOARD: u16 = 1;
const WL_SEAT_EVT_CAPABILITIES: u16 = 0;

const WL_POINTER_EVT_ENTER: u16 = 0;
const WL_POINTER_EVT_LEAVE: u16 = 1;
const WL_POINTER_EVT_MOTION: u16 = 2;
const WL_POINTER_EVT_BUTTON: u16 = 3;
const WL_POINTER_EVT_AXIS: u16 = 4;

const WL_KEYBOARD_EVT_LEAVE: u16 = 2;
const WL_KEYBOARD_EVT_KEY: u16 = 3;
const WL_KEYBOARD_EVT_MODIFIERS: u16 = 4;

const WL_OUTPUT_EVT_MODE: u16 = 1;
const WL_OUTPUT_EVT_SCALE: u16 = 3;

/// Encodes one or more Wayland wire protocol messages into a caller-supplied buffer.
pub const WireEncoder = struct {
    buf: []u8,
    pos: usize = 8,
    msg_start: usize = 0,
    msg_open: bool = true,

    pub fn init(buf: []u8) WireEncoder {
        return .{ .buf = buf, .pos = 8, .msg_start = 0, .msg_open = true };
    }

    pub fn beginMessage(self: *WireEncoder) !void {
        if (self.msg_open) return;
        if (self.pos > self.buf.len or self.buf.len - self.pos < 8) {
            return error.BufferTooSmall;
        }
        self.msg_start = self.pos;
        self.pos += 8;
        self.msg_open = true;
    }

    fn ensureSpace(self: *WireEncoder, bytes: usize) !void {
        try self.beginMessage();
        if (self.pos > self.buf.len or self.buf.len - self.pos < bytes) {
            return error.BufferTooSmall;
        }
        const msg_len = self.pos - self.msg_start;
        if (msg_len + bytes > MAX_WIRE_MSG_SIZE) {
            return error.MessageTooLarge;
        }
    }

    pub fn writeU32(self: *WireEncoder, val: u32) !void {
        try self.ensureSpace(4);
        std.mem.writeInt(u32, self.buf[self.pos..][0..4], val, native_endian);
        self.pos += 4;
    }

    pub fn writeI32(self: *WireEncoder, val: i32) !void {
        try self.writeU32(@bitCast(val));
    }

    pub fn writeFixed(self: *WireEncoder, val: f32) !void {
        if (!std.math.isFinite(val)) return error.InvalidFixedPoint;
        const scaled = @round(@as(f64, val) * 256.0);
        if (scaled < -2147483648.0 or scaled > 2147483647.0) {
            return error.InvalidFixedPoint;
        }
        try self.writeI32(@intFromFloat(scaled));
    }

    pub fn writeString(self: *WireEncoder, s: []const u8) !void {
        if (std.mem.indexOfScalar(u8, s, 0) != null) {
            return error.InvalidString;
        }
        if (s.len > MAX_WIRE_MSG_SIZE - 12) {
            return error.MessageTooLarge;
        }
        const len_with_nul: u32 = @intCast(s.len + 1);
        const padded_len: usize = std.mem.alignForward(usize, len_with_nul, 4);
        try self.ensureSpace(4 + padded_len);

        std.mem.writeInt(u32, self.buf[self.pos..][0..4], len_with_nul, native_endian);
        self.pos += 4;
        if (s.len > 0) {
            @memcpy(self.buf[self.pos .. self.pos + s.len], s);
        }
        @memset(self.buf[self.pos + s.len .. self.pos + padded_len], 0);
        self.pos += padded_len;
    }

    pub fn writeArray(self: *WireEncoder, data: []const u8) !void {
        if (data.len > MAX_WIRE_MSG_SIZE - 12) {
            return error.MessageTooLarge;
        }
        const padded_len: usize = std.mem.alignForward(usize, data.len, 4);
        try self.ensureSpace(4 + padded_len);

        std.mem.writeInt(u32, self.buf[self.pos..][0..4], @intCast(data.len), native_endian);
        self.pos += 4;
        if (data.len > 0) {
            @memcpy(self.buf[self.pos .. self.pos + data.len], data);
        }
        if (padded_len > data.len) {
            @memset(self.buf[self.pos + data.len .. self.pos + padded_len], 0);
        }
        self.pos += padded_len;
    }

    pub fn finish(self: *WireEncoder, object_id: u32, opcode: u16) ![]const u8 {
        try self.beginMessage();
        if (self.pos < self.msg_start + 8 or self.pos > self.buf.len) {
            return error.BufferTooSmall;
        }
        const msg_len = self.pos - self.msg_start;
        if (msg_len > MAX_WIRE_MSG_SIZE or msg_len % 4 != 0) {
            return error.InvalidMessageSize;
        }
        const size_u16: u16 = @intCast(msg_len);
        const size_and_opcode: u32 = (@as(u32, size_u16) << 16) | @as(u32, opcode);
        std.mem.writeInt(u32, self.buf[self.msg_start..][0..4], object_id, native_endian);
        std.mem.writeInt(u32, self.buf[self.msg_start + 4 ..][0..4], size_and_opcode, native_endian);
        const start = self.msg_start;
        self.msg_start = self.pos;
        self.msg_open = false;
        return self.buf[start..self.pos];
    }

    pub fn written(self: *const WireEncoder) []const u8 {
        if (self.msg_open) {
            return self.buf[0..self.msg_start];
        }
        return self.buf[0..self.pos];
    }
};

/// Decodes and validates a single Wayland wire protocol message.
pub const WireDecoder = struct {
    object_id: u32,
    opcode: u16,
    size: u16,
    payload: []const u8,
    offset: usize = 0,

    pub fn init(msg: []const u8) !WireDecoder {
        if (msg.len < 8) return error.TruncatedHeader;
        const object_id = std.mem.readInt(u32, msg[0..4], native_endian);
        const size_and_opcode = std.mem.readInt(u32, msg[4..8], native_endian);
        const size: u16 = @intCast(size_and_opcode >> 16);
        const opcode: u16 = @intCast(size_and_opcode & 0xFFFF);

        if (size < 8) return error.InvalidMessageSize;
        if (size > msg.len) return error.TruncatedMessage;
        if (size % 4 != 0) return error.UnalignedMessageSize;

        return .{
            .object_id = object_id,
            .opcode = opcode,
            .size = size,
            .payload = msg[8..size],
            .offset = 0,
        };
    }

    pub fn remaining(self: *const WireDecoder) usize {
        return self.payload.len - self.offset;
    }

    pub fn readU32(self: *WireDecoder) !u32 {
        if (self.remaining() < 4) return error.UnexpectedEndOfMessage;
        const val = std.mem.readInt(u32, self.payload[self.offset..][0..4], native_endian);
        self.offset += 4;
        return val;
    }

    pub fn readI32(self: *WireDecoder) !i32 {
        return @bitCast(try self.readU32());
    }

    pub fn readFixed(self: *WireDecoder) !f32 {
        const raw = try self.readI32();
        return @as(f32, @floatFromInt(raw)) / 256.0;
    }

    pub fn readString(self: *WireDecoder) ![]const u8 {
        const len_u32 = try self.readU32();
        if (len_u32 == 0) return error.InvalidStringLength;
        const len: usize = @intCast(len_u32);
        const padded_u64 = std.mem.alignForward(u64, len_u32, 4);
        if (padded_u64 > self.remaining()) return error.TruncatedString;

        const raw = self.payload[self.offset .. self.offset + len];
        if (raw[len - 1] != 0) return error.MissingNulTerminator;
        if (std.mem.indexOfScalar(u8, raw[0 .. len - 1], 0) != null) {
            return error.InvalidString;
        }
        self.offset += @intCast(padded_u64);
        return raw[0 .. len - 1];
    }

    pub fn readArray(self: *WireDecoder) ![]const u8 {
        const len_u32 = try self.readU32();
        const len: usize = @intCast(len_u32);
        const padded_u64 = std.mem.alignForward(u64, len_u32, 4);
        if (padded_u64 > self.remaining()) return error.TruncatedArray;

        const data = self.payload[self.offset .. self.offset + len];
        self.offset += @intCast(padded_u64);
        return data;
    }
};

/// Zero-tick Linux `epoll` wakeup loop wrapper.
pub const EpollLoop = struct {
    pub const MAX_EVENTS: usize = 64;

    epoll_fd: i32 = -1,
    events_buf: [MAX_EVENTS]linux.epoll_event = undefined,
    tags_buf: [MAX_EVENTS]u64 = undefined,

    pub fn init() !EpollLoop {
        const rc = linux.epoll_create1(linux.EPOLL.CLOEXEC);
        const err = linux.errno(rc);
        if (err != .SUCCESS) {
            return switch (err) {
                .MFILE => error.ProcessFdQuotaExceeded,
                .NFILE => error.SystemFdQuotaExceeded,
                .NOMEM => error.SystemResources,
                else => error.EpollCreateFailed,
            };
        }
        return .{ .epoll_fd = @intCast(rc) };
    }

    pub fn deinit(self: *EpollLoop) void {
        if (self.epoll_fd >= 0) {
            _ = linux.close(self.epoll_fd);
            self.epoll_fd = -1;
        }
    }

    pub fn addFd(self: *EpollLoop, target_fd: i32, tag: u64) !void {
        if (self.epoll_fd < 0 or target_fd < 0) return error.InvalidFd;
        var ev = linux.epoll_event{
            .events = linux.EPOLL.IN,
            .data = .{ .u64 = tag },
        };
        const rc = linux.epoll_ctl(self.epoll_fd, linux.EPOLL.CTL_ADD, target_fd, &ev);
        const err = linux.errno(rc);
        if (err != .SUCCESS) {
            return switch (err) {
                .EXIST => error.AlreadyRegistered,
                .NOMEM => error.SystemResources,
                .NOSPC => error.SystemLimitsReached,
                .BADF => error.InvalidFd,
                .PERM => error.NotPollable,
                else => error.EpollCtlFailed,
            };
        }
    }

    pub fn removeFd(self: *EpollLoop, target_fd: i32) void {
        if (self.epoll_fd < 0 or target_fd < 0) return;
        _ = linux.epoll_ctl(self.epoll_fd, linux.EPOLL.CTL_DEL, target_fd, null);
    }

    /// Blocks up to `timeout_ms` (`-1` for zero-CPU infinite sleep, `0` for non-blocking poll)
    /// and returns the slice of woken tags.
    pub fn wait(self: *EpollLoop, timeout_ms: i32) ![]const u64 {
        if (self.epoll_fd < 0) return error.InvalidFd;
        if (timeout_ms < -1) return error.InvalidArgument;
        while (true) {
            const rc = linux.epoll_wait(
                self.epoll_fd,
                &self.events_buf,
                self.events_buf.len,
                timeout_ms,
            );
            const err = linux.errno(rc);
            switch (err) {
                .SUCCESS => {
                    const count: usize = @min(rc, self.tags_buf.len);
                    for (0..count) |i| {
                        self.tags_buf[i] = self.events_buf[i].data.u64;
                    }
                    return self.tags_buf[0..count];
                },
                .INTR => continue,
                .BADF => return error.InvalidFd,
                .INVAL => return error.InvalidArgument,
                else => return error.EpollWaitFailed,
            }
        }
    }
};

fn initUnixAddr(path_slice: []const u8) struct { addr: linux.sockaddr.un, len: linux.socklen_t } {
    var addr: linux.sockaddr.un = .{
        .family = linux.AF.UNIX,
        .path = @splat(0),
    };
    @memcpy(addr.path[0..path_slice.len], path_slice);
    const len: linux.socklen_t = @intCast(@offsetOf(linux.sockaddr.un, "path") + path_slice.len + 1);
    return .{ .addr = addr, .len = len };
}

/// Builds `$XDG_RUNTIME_DIR/$WAYLAND_DISPLAY` into `out_buf` as a NUL-terminated path.
/// If `wayland_display` starts with `'/'`, it is treated as an absolute socket path directly.
pub fn resolveSocketPath(
    xdg_runtime_dir: []const u8,
    wayland_display: []const u8,
    out_buf: []u8,
) ![*:0]const u8 {
    if (std.mem.indexOfScalar(u8, xdg_runtime_dir, 0) != null or
        std.mem.indexOfScalar(u8, wayland_display, 0) != null)
    {
        return error.InvalidPath;
    }
    if (wayland_display.len == 0) {
        return error.InvalidSocketPath;
    }

    if (wayland_display[0] == '/') {
        if (wayland_display.len >= 108 or wayland_display.len + 1 > out_buf.len) {
            return error.PathTooLong;
        }
        @memcpy(out_buf[0..wayland_display.len], wayland_display);
        out_buf[wayland_display.len] = 0;
        return @ptrCast(out_buf[0..wayland_display.len :0]);
    }

    if (xdg_runtime_dir.len == 0) {
        return error.InvalidSocketPath;
    }
    if (xdg_runtime_dir.len >= 108 or wayland_display.len >= 108) {
        return error.PathTooLong;
    }
    const need_slash = xdg_runtime_dir[xdg_runtime_dir.len - 1] != '/';
    const total = xdg_runtime_dir.len + (if (need_slash) @as(usize, 1) else 0) + wayland_display.len;
    if (total == 0 or total >= 108 or total + 1 > out_buf.len) {
        return error.PathTooLong;
    }
    var pos: usize = 0;
    @memcpy(out_buf[pos .. pos + xdg_runtime_dir.len], xdg_runtime_dir);
    pos += xdg_runtime_dir.len;
    if (need_slash) {
        out_buf[pos] = '/';
        pos += 1;
    }
    @memcpy(out_buf[pos .. pos + wayland_display.len], wayland_display);
    pos += wayland_display.len;
    out_buf[pos] = 0;
    return @ptrCast(out_buf[0..pos :0]);
}

/// Pure-Zig Wayland wire client supporting `wl_surface`, `xdg_shell`,
/// `zwlr_layer_shell_v1`, `wp_fractional_scale_v1`, `wl_seat`, and `wl_output`.
pub const WaylandClient = struct {
    allocator: std.mem.Allocator,
    sock_fd: i32 = -1,
    peer_fd: i32 = -1,
    next_id: u32 = 3,
    registry_id: u32 = 2,

    compositor_id: u32 = 0,
    xdg_wm_base_id: u32 = 0,
    layer_shell_id: u32 = 0,
    fractional_scale_mgr_id: u32 = 0,
    seat_id: u32 = 0,
    pointer_id: u32 = 0,
    keyboard_id: u32 = 0,

    outputs: std.ArrayList(OutputInfo) = .empty,
    surfaces: std.ArrayList(SurfaceState) = .empty,

    input_queue: [INPUT_QUEUE_CAPACITY]events.InputEvent = undefined,
    drain_buf: [INPUT_QUEUE_CAPACITY]events.InputEvent = undefined,
    input_len: usize = 0,
    dropped_input_events: usize = 0,

    pointer_x: f32 = 0.0,
    pointer_y: f32 = 0.0,
    active_mods: events.Modifiers = .{},

    recv_buf: []u8 = &.{},
    recv_len: usize = 0,
    send_buf: []u8 = &.{},
    send_len: usize = 0,
    disconnected: bool = false,
    peer_eof: bool = false,

    pub fn connect(allocator: std.mem.Allocator, socket_path: [*:0]const u8) !WaylandClient {
        const path_slice = std.mem.span(socket_path);
        if (path_slice.len == 0) return error.InvalidSocketPath;
        if (path_slice.len >= 108) return error.PathTooLong;

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
        var sock_fd: i32 = @intCast(sock_rc);
        errdefer if (sock_fd >= 0) {
            _ = linux.close(sock_fd);
        };

        const uaddr = initUnixAddr(path_slice);
        var retries: usize = 0;
        while (true) {
            const conn_rc = linux.connect(sock_fd, @ptrCast(&uaddr.addr), uaddr.len);
            const conn_err = linux.errno(conn_rc);
            switch (conn_err) {
                .SUCCESS, .ISCONN => break,
                .INTR => continue,
                .INPROGRESS, .ALREADY => {
                    var poll_retries: usize = 0;
                    while (true) {
                        if (poll_retries >= 64) return error.ConnectTimeout;
                        poll_retries += 1;
                        var pfd = [_]linux.pollfd{.{
                            .fd = sock_fd,
                            .events = linux.POLL.OUT,
                            .revents = 0,
                        }};
                        const poll_rc = linux.poll(&pfd, 1, 10);
                        const poll_err = linux.errno(poll_rc);
                        if (poll_err == .INTR) continue;
                        if (poll_err != .SUCCESS) return error.ConnectFailed;
                        if (poll_rc == 0) continue;
                        var so_err: i32 = 0;
                        var so_len: linux.socklen_t = @sizeOf(i32);
                        const opt_rc = linux.getsockopt(
                            sock_fd,
                            linux.SOL.SOCKET,
                            linux.SO.ERROR,
                            @ptrCast(&so_err),
                            &so_len,
                        );
                        if (linux.errno(opt_rc) != .SUCCESS or so_err != 0) {
                            return error.ConnectFailed;
                        }
                        break;
                    }
                    break;
                },
                .AGAIN => {
                    if (retries >= 64) return error.ConnectTimeout;
                    retries += 1;
                    var dummy: [1]linux.pollfd = undefined;
                    _ = linux.poll(&dummy, 0, 5);
                    continue;
                },
                .NOENT => return error.FileNotFound,
                .CONNREFUSED => return error.ConnectionRefused,
                .ACCES, .PERM => return error.AccessDenied,
                else => return error.ConnectFailed,
            }
        }

        var recv_buf: []u8 = try allocator.alloc(u8, RECV_BUF_SIZE);
        errdefer if (recv_buf.len > 0) allocator.free(recv_buf);
        var send_buf: []u8 = try allocator.alloc(u8, SEND_BUF_SIZE);
        errdefer if (send_buf.len > 0) allocator.free(send_buf);

        var client = WaylandClient{
            .allocator = allocator,
            .sock_fd = sock_fd,
            .recv_buf = recv_buf,
            .send_buf = send_buf,
        };
        sock_fd = -1;
        recv_buf = &.{};
        send_buf = &.{};
        errdefer client.deinit();
        try client.sendGetRegistry();
        return client;
    }

    /// Creates a connected kernel `AF_UNIX` socketpair so unit tests encode and
    /// flush real Wayland wire protocol frames without an external compositor.
    pub fn initLoopback(allocator: std.mem.Allocator) !WaylandClient {
        var fds: [2]i32 = .{ -1, -1 };
        const rc = linux.socketpair(
            linux.AF.UNIX,
            linux.SOCK.STREAM | linux.SOCK.NONBLOCK | linux.SOCK.CLOEXEC,
            0,
            &fds,
        );
        const err = linux.errno(rc);
        if (err != .SUCCESS) {
            return switch (err) {
                .MFILE => error.ProcessFdQuotaExceeded,
                .NFILE => error.SystemFdQuotaExceeded,
                .NOMEM => error.SystemResources,
                else => error.SocketPairFailed,
            };
        }
        errdefer {
            if (fds[0] >= 0) _ = linux.close(fds[0]);
            if (fds[1] >= 0) _ = linux.close(fds[1]);
        }

        var recv_buf: []u8 = try allocator.alloc(u8, RECV_BUF_SIZE);
        errdefer if (recv_buf.len > 0) allocator.free(recv_buf);
        var send_buf: []u8 = try allocator.alloc(u8, SEND_BUF_SIZE);
        errdefer if (send_buf.len > 0) allocator.free(send_buf);

        var client = WaylandClient{
            .allocator = allocator,
            .sock_fd = fds[0],
            .peer_fd = fds[1],
            .recv_buf = recv_buf,
            .send_buf = send_buf,
        };
        fds[0] = -1;
        fds[1] = -1;
        recv_buf = &.{};
        send_buf = &.{};
        errdefer client.deinit();
        try client.sendGetRegistry();
        return client;
    }

    pub fn deinit(self: *WaylandClient) void {
        if (self.sock_fd >= 0) {
            _ = linux.close(self.sock_fd);
            self.sock_fd = -1;
        }
        if (self.peer_fd >= 0) {
            _ = linux.close(self.peer_fd);
            self.peer_fd = -1;
        }
        if (self.recv_buf.len > 0) {
            self.allocator.free(self.recv_buf);
            self.recv_buf = &.{};
        }
        self.recv_len = 0;
        if (self.send_buf.len > 0) {
            self.allocator.free(self.send_buf);
            self.send_buf = &.{};
        }
        self.send_len = 0;
        self.outputs.deinit(self.allocator);
        self.outputs = .empty;
        self.surfaces.deinit(self.allocator);
        self.surfaces = .empty;
        self.disconnected = true;
    }

    pub fn fd(self: *const WaylandClient) i32 {
        return self.sock_fd;
    }

    pub fn peerFd(self: *const WaylandClient) i32 {
        return self.peer_fd;
    }

    pub fn hasLayerShell(self: *const WaylandClient) bool {
        return self.layer_shell_id != 0;
    }

    pub fn hasFractionalScale(self: *const WaylandClient) bool {
        return self.fractional_scale_mgr_id != 0;
    }

    pub fn hasXdgShell(self: *const WaylandClient) bool {
        return self.xdg_wm_base_id != 0;
    }

    pub fn hasPendingSend(self: *const WaylandClient) bool {
        return self.send_len > 0;
    }

    fn allocId(self: *WaylandClient) !u32 {
        if (self.next_id >= CLIENT_OBJECT_ID_LIMIT) {
            return error.ObjectIdExhausted;
        }
        const id = self.next_id;
        self.next_id += 1;
        return id;
    }

    fn checkIdBudget(self: *const WaylandClient, count: u32) !void {
        if (self.next_id >= CLIENT_OBJECT_ID_LIMIT or CLIENT_OBJECT_ID_LIMIT - self.next_id < count) {
            return error.ObjectIdExhausted;
        }
    }

    fn validateWireString(s: []const u8, max_padded_bytes: usize) !void {
        if (std.mem.indexOfScalar(u8, s, 0) != null) return error.InvalidString;
        if (s.len > MAX_WIRE_MSG_SIZE - 12) return error.MessageTooLarge;
        if (std.mem.alignForward(usize, s.len + 1, 4) > max_padded_bytes) return error.MessageTooLarge;
    }

    /// Flushes any buffered outbound wire bytes without corrupting message framing.
    pub fn flushSend(self: *WaylandClient) !void {
        if (self.sock_fd < 0) return error.NotConnected;
        var sent: usize = 0;
        defer if (sent > 0) {
            const rem = self.send_len - sent;
            if (rem > 0) {
                std.mem.copyForwards(u8, self.send_buf[0..rem], self.send_buf[sent..self.send_len]);
            }
            self.send_len = rem;
        };

        while (sent < self.send_len) {
            const rc = linux.sendto(
                self.sock_fd,
                self.send_buf[sent..].ptr,
                self.send_len - sent,
                linux.MSG.NOSIGNAL,
                null,
                0,
            );
            const err = linux.errno(rc);
            switch (err) {
                .SUCCESS => {
                    if (rc == 0) return error.BrokenPipe;
                    sent += rc;
                },
                .INTR => continue,
                .AGAIN => return error.WouldBlock,
                .PIPE, .CONNRESET => return error.BrokenPipe,
                else => return error.SendFailed,
            }
        }
    }

    fn sendWireMsg(self: *WaylandClient, msg: []const u8) !void {
        if (self.sock_fd < 0 or self.send_buf.len == 0) return error.NotConnected;
        if (msg.len > self.send_buf.len) return error.MessageTooLarge;

        if (self.send_len > 0) {
            self.flushSend() catch |err| switch (err) {
                error.WouldBlock => {
                    if (self.send_len + msg.len > self.send_buf.len) {
                        return error.WouldBlock;
                    }
                    @memcpy(self.send_buf[self.send_len .. self.send_len + msg.len], msg);
                    self.send_len += msg.len;
                    return;
                },
                else => return err,
            };
        }

        var sent: usize = 0;
        while (sent < msg.len) {
            const rc = linux.sendto(
                self.sock_fd,
                msg.ptr + sent,
                msg.len - sent,
                linux.MSG.NOSIGNAL,
                null,
                0,
            );
            const err = linux.errno(rc);
            switch (err) {
                .SUCCESS => {
                    if (rc == 0) return error.BrokenPipe;
                    sent += rc;
                },
                .INTR => continue,
                .AGAIN => {
                    const tail = msg[sent..];
                    @memcpy(self.send_buf[0..tail.len], tail);
                    self.send_len = tail.len;
                    return;
                },
                .PIPE, .CONNRESET => return error.BrokenPipe,
                else => return error.SendFailed,
            }
        }
    }

    fn sendGetRegistry(self: *WaylandClient) !void {
        var buf: [32]u8 = undefined;
        var enc = WireEncoder.init(&buf);
        try enc.writeU32(self.registry_id);
        const msg = try enc.finish(WL_DISPLAY_ID, WL_DISPLAY_GET_REGISTRY);
        try self.sendWireMsg(msg);
    }

    fn sendRegistryBind(
        self: *WaylandClient,
        name: u32,
        interface: []const u8,
        version: u32,
        new_id: u32,
    ) !void {
        var buf: [256]u8 = undefined;
        var enc = WireEncoder.init(&buf);
        try enc.writeU32(name);
        try enc.writeString(interface);
        try enc.writeU32(version);
        try enc.writeU32(new_id);
        const msg = try enc.finish(self.registry_id, WL_REGISTRY_BIND);
        try self.sendWireMsg(msg);
    }

    pub fn simulateRegistryGlobal(
        self: *WaylandClient,
        name: u32,
        interface: []const u8,
        version: u32,
    ) !void {
        if (version == 0) return;

        if (std.mem.eql(u8, interface, "wl_compositor")) {
            if (self.compositor_id != 0) return;
            try self.checkIdBudget(1);
            const id = try self.allocId();
            try self.sendRegistryBind(name, interface, @min(version, 5), id);
            self.compositor_id = id;
        } else if (std.mem.eql(u8, interface, "xdg_wm_base")) {
            if (self.xdg_wm_base_id != 0) return;
            try self.checkIdBudget(1);
            const id = try self.allocId();
            try self.sendRegistryBind(name, interface, @min(version, 3), id);
            self.xdg_wm_base_id = id;
        } else if (std.mem.eql(u8, interface, "zwlr_layer_shell_v1")) {
            if (self.layer_shell_id != 0) return;
            try self.checkIdBudget(1);
            const id = try self.allocId();
            try self.sendRegistryBind(name, interface, @min(version, 4), id);
            self.layer_shell_id = id;
        } else if (std.mem.eql(u8, interface, "wp_fractional_scale_manager_v1")) {
            if (self.fractional_scale_mgr_id != 0) return;
            try self.checkIdBudget(1);
            const id = try self.allocId();
            try self.sendRegistryBind(name, interface, @min(version, 1), id);
            self.fractional_scale_mgr_id = id;
        } else if (std.mem.eql(u8, interface, "wl_seat")) {
            if (self.seat_id != 0) return;
            try self.checkIdBudget(1);
            const id = try self.allocId();
            try self.sendRegistryBind(name, interface, @min(version, 7), id);
            self.seat_id = id;
        } else if (std.mem.eql(u8, interface, "wl_output")) {
            for (self.outputs.items) |out| {
                if (out.global_name == name) return;
            }
            if (self.outputs.items.len >= MAX_OUTPUTS) return;
            try self.checkIdBudget(1);
            try self.outputs.ensureUnusedCapacity(self.allocator, 1);
            const id = try self.allocId();
            try self.sendRegistryBind(name, interface, @min(version, 4), id);
            self.outputs.appendAssumeCapacity(.{
                .global_name = name,
                .object_id = id,
            });
        }
    }

    pub fn createLayerSurface(self: *WaylandClient, desc: LayerSurfaceDesc) !LayerSurfaceHandle {
        if (self.sock_fd < 0) return error.NotConnected;
        if (self.compositor_id == 0) return error.MissingCompositor;
        if (self.layer_shell_id == 0) return error.MissingLayerShell;
        if (self.surfaces.items.len >= MAX_SURFACES) return error.TooManySurfaces;
        try validateWireString(desc.namespace, 512 - 28);
        const needed_ids: u32 = if (self.fractional_scale_mgr_id != 0) 3 else 2;
        try self.checkIdBudget(needed_ids);
        try self.surfaces.ensureUnusedCapacity(self.allocator, 1);

        const surface_id = try self.allocId();
        {
            var buf: [32]u8 = undefined;
            var enc = WireEncoder.init(&buf);
            try enc.writeU32(surface_id);
            try self.sendWireMsg(try enc.finish(self.compositor_id, WL_COMPOSITOR_CREATE_SURFACE));
        }

        var fractional_scale_id: u32 = 0;
        if (self.fractional_scale_mgr_id != 0) {
            fractional_scale_id = try self.allocId();
            var buf: [32]u8 = undefined;
            var enc = WireEncoder.init(&buf);
            try enc.writeU32(fractional_scale_id);
            try enc.writeU32(surface_id);
            try self.sendWireMsg(try enc.finish(
                self.fractional_scale_mgr_id,
                WP_FRACTIONAL_SCALE_MGR_GET_FRACTIONAL_SCALE,
            ));
        }

        const layer_surface_id = try self.allocId();
        {
            var buf: [512]u8 = undefined;
            var enc = WireEncoder.init(&buf);
            try enc.writeU32(layer_surface_id);
            try enc.writeU32(surface_id);
            try enc.writeU32(0); // output = NULL (compositor picks active output)
            try enc.writeU32(@backingInt(desc.layer));
            try enc.writeString(desc.namespace);
            try self.sendWireMsg(try enc.finish(
                self.layer_shell_id,
                ZWLR_LAYER_SHELL_GET_LAYER_SURFACE,
            ));
        }

        {
            var buf: [32]u8 = undefined;
            var enc = WireEncoder.init(&buf);
            try enc.writeU32(desc.width);
            try enc.writeU32(desc.height);
            try self.sendWireMsg(try enc.finish(layer_surface_id, ZWLR_LAYER_SURFACE_SET_SIZE));
        }

        {
            var buf: [32]u8 = undefined;
            var enc = WireEncoder.init(&buf);
            try enc.writeU32(@bitCast(desc.anchor));
            try self.sendWireMsg(try enc.finish(layer_surface_id, ZWLR_LAYER_SURFACE_SET_ANCHOR));
        }

        {
            var buf: [32]u8 = undefined;
            var enc = WireEncoder.init(&buf);
            try enc.writeI32(desc.exclusive_zone);
            try self.sendWireMsg(try enc.finish(
                layer_surface_id,
                ZWLR_LAYER_SURFACE_SET_EXCLUSIVE_ZONE,
            ));
        }

        {
            var buf: [32]u8 = undefined;
            var enc = WireEncoder.init(&buf);
            try enc.writeU32(desc.keyboard_interactivity);
            try self.sendWireMsg(try enc.finish(
                layer_surface_id,
                ZWLR_LAYER_SURFACE_SET_KEYBOARD_INTERACTIVITY,
            ));
        }

        {
            var buf: [16]u8 = undefined;
            var enc = WireEncoder.init(&buf);
            try self.sendWireMsg(try enc.finish(surface_id, WL_SURFACE_COMMIT));
        }

        self.surfaces.appendAssumeCapacity(.{
            .surface_id = surface_id,
            .layer_surface_id = layer_surface_id,
            .fractional_scale_id = fractional_scale_id,
            .width = desc.width,
            .height = desc.height,
        });

        return .{
            .surface_id = surface_id,
            .layer_surface_id = layer_surface_id,
            .fractional_scale_id = fractional_scale_id,
        };
    }

    pub fn createXdgSurface(self: *WaylandClient, desc: XdgSurfaceDesc) !XdgSurfaceHandle {
        if (self.sock_fd < 0) return error.NotConnected;
        if (self.compositor_id == 0) return error.MissingCompositor;
        if (self.xdg_wm_base_id == 0) return error.MissingXdgShell;
        if (self.surfaces.items.len >= MAX_SURFACES) return error.TooManySurfaces;
        try validateWireString(desc.title, 512 - 12);
        try validateWireString(desc.app_id, 512 - 12);
        const needed_ids: u32 = if (self.fractional_scale_mgr_id != 0) 4 else 3;
        try self.checkIdBudget(needed_ids);
        try self.surfaces.ensureUnusedCapacity(self.allocator, 1);

        const surface_id = try self.allocId();
        {
            var buf: [32]u8 = undefined;
            var enc = WireEncoder.init(&buf);
            try enc.writeU32(surface_id);
            try self.sendWireMsg(try enc.finish(self.compositor_id, WL_COMPOSITOR_CREATE_SURFACE));
        }

        var fractional_scale_id: u32 = 0;
        if (self.fractional_scale_mgr_id != 0) {
            fractional_scale_id = try self.allocId();
            var buf: [32]u8 = undefined;
            var enc = WireEncoder.init(&buf);
            try enc.writeU32(fractional_scale_id);
            try enc.writeU32(surface_id);
            try self.sendWireMsg(try enc.finish(
                self.fractional_scale_mgr_id,
                WP_FRACTIONAL_SCALE_MGR_GET_FRACTIONAL_SCALE,
            ));
        }

        const xdg_surface_id = try self.allocId();
        {
            var buf: [32]u8 = undefined;
            var enc = WireEncoder.init(&buf);
            try enc.writeU32(xdg_surface_id);
            try enc.writeU32(surface_id);
            try self.sendWireMsg(try enc.finish(self.xdg_wm_base_id, XDG_WM_BASE_GET_XDG_SURFACE));
        }

        const xdg_toplevel_id = try self.allocId();
        {
            var buf: [32]u8 = undefined;
            var enc = WireEncoder.init(&buf);
            try enc.writeU32(xdg_toplevel_id);
            try self.sendWireMsg(try enc.finish(xdg_surface_id, XDG_SURFACE_GET_TOPLEVEL));
        }

        {
            var buf: [512]u8 = undefined;
            var enc = WireEncoder.init(&buf);
            try enc.writeString(desc.title);
            try self.sendWireMsg(try enc.finish(xdg_toplevel_id, XDG_TOPLEVEL_SET_TITLE));
        }

        {
            var buf: [512]u8 = undefined;
            var enc = WireEncoder.init(&buf);
            try enc.writeString(desc.app_id);
            try self.sendWireMsg(try enc.finish(xdg_toplevel_id, XDG_TOPLEVEL_SET_APP_ID));
        }

        {
            var buf: [16]u8 = undefined;
            var enc = WireEncoder.init(&buf);
            try self.sendWireMsg(try enc.finish(surface_id, WL_SURFACE_COMMIT));
        }

        self.surfaces.appendAssumeCapacity(.{
            .surface_id = surface_id,
            .xdg_surface_id = xdg_surface_id,
            .xdg_toplevel_id = xdg_toplevel_id,
            .fractional_scale_id = fractional_scale_id,
        });

        return .{
            .surface_id = surface_id,
            .xdg_surface_id = xdg_surface_id,
            .xdg_toplevel_id = xdg_toplevel_id,
            .fractional_scale_id = fractional_scale_id,
        };
    }

    pub fn destroySurface(self: *WaylandClient, surface_id: u32) bool {
        if (surface_id == 0) return false;
        for (self.surfaces.items, 0..) |s, i| {
            if (s.surface_id == surface_id) {
                _ = self.surfaces.swapRemove(i);
                return true;
            }
        }
        return false;
    }

    fn findSurfaceById(self: *WaylandClient, surface_id: u32) ?*SurfaceState {
        if (surface_id == 0) return null;
        for (self.surfaces.items) |*s| {
            if (s.surface_id == surface_id) return s;
        }
        return null;
    }

    fn findSurfaceByLayerId(self: *WaylandClient, layer_surface_id: u32) ?*SurfaceState {
        if (layer_surface_id == 0) return null;
        for (self.surfaces.items) |*s| {
            if (s.layer_surface_id == layer_surface_id) return s;
        }
        return null;
    }

    fn findSurfaceByXdgId(self: *WaylandClient, xdg_surface_id: u32) ?*SurfaceState {
        if (xdg_surface_id == 0) return null;
        for (self.surfaces.items) |*s| {
            if (s.xdg_surface_id == xdg_surface_id) return s;
        }
        return null;
    }

    pub fn handleFractionalScale(self: *WaylandClient, surface_id: u32, scale_120: u32) void {
        if (scale_120 < 60 or scale_120 > 1200) return;
        const s = self.findSurfaceById(surface_id) orelse return;
        s.scale_factor = @as(f32, @floatFromInt(scale_120)) / 120.0;
    }

    pub fn handleLayerConfigure(
        self: *WaylandClient,
        layer_surface_id: u32,
        serial: u32,
        width: u32,
        height: u32,
    ) !void {
        const s = self.findSurfaceByLayerId(layer_surface_id) orelse return error.UnknownSurface;
        if (width > 0) s.width = width;
        if (height > 0) s.height = height;
        s.configured = true;

        var buf: [32]u8 = undefined;
        var enc = WireEncoder.init(&buf);
        try enc.writeU32(serial);
        try self.sendWireMsg(try enc.finish(layer_surface_id, ZWLR_LAYER_SURFACE_ACK_CONFIGURE));
    }

    pub fn handleXdgConfigure(self: *WaylandClient, xdg_surface_id: u32, serial: u32) !void {
        const s = self.findSurfaceByXdgId(xdg_surface_id) orelse return error.UnknownSurface;
        s.configured = true;

        var buf: [32]u8 = undefined;
        var enc = WireEncoder.init(&buf);
        try enc.writeU32(serial);
        try self.sendWireMsg(try enc.finish(xdg_surface_id, XDG_SURFACE_ACK_CONFIGURE));
    }

    pub fn getSurfaceScale(self: *const WaylandClient, surface_id: u32) ?f32 {
        if (surface_id == 0) return null;
        for (self.surfaces.items) |s| {
            if (s.surface_id == surface_id) return s.scale_factor;
        }
        return null;
    }

    pub fn getSurfaceSize(self: *const WaylandClient, surface_id: u32) ?[2]u32 {
        if (surface_id == 0) return null;
        for (self.surfaces.items) |s| {
            if (s.surface_id == surface_id) return .{ s.width, s.height };
        }
        return null;
    }

    fn pushInputEvent(self: *WaylandClient, ev: events.InputEvent) void {
        if (ev == .pointer_move and self.input_len > 0 and self.input_queue[self.input_len - 1] == .pointer_move) {
            if (self.input_queue[self.input_len - 1].pointer_move.pointer_id == ev.pointer_move.pointer_id and
                self.input_queue[self.input_len - 1].pointer_move.is_touch == ev.pointer_move.is_touch)
            {
                self.input_queue[self.input_len - 1] = ev;
                return;
            }
        }
        if (self.input_len < self.input_queue.len) {
            self.input_queue[self.input_len] = ev;
            self.input_len += 1;
            return;
        }
        if (ev != .pointer_move) {
            var i: usize = self.input_len;
            while (i > 0) {
                i -= 1;
                if (self.input_queue[i] == .pointer_move) {
                    if (i + 1 < self.input_len) {
                        std.mem.copyForwards(
                            events.InputEvent,
                            self.input_queue[i .. self.input_len - 1],
                            self.input_queue[i + 1 .. self.input_len],
                        );
                    }
                    self.input_queue[self.input_len - 1] = ev;
                    self.dropped_input_events +|= 1;
                    return;
                }
            }
        }
        self.dropped_input_events +|= 1;
    }

    pub fn handlePointerMotion(self: *WaylandClient, x: f32, y: f32) void {
        if (!std.math.isFinite(x) or !std.math.isFinite(y)) return;
        self.pointer_x = x;
        self.pointer_y = y;
        self.pushInputEvent(.{ .pointer_move = .{
            .pointer_id = 0,
            .x = x,
            .y = y,
            .is_touch = false,
        } });
    }

    pub fn handlePointerButton(self: *WaylandClient, btn: u32, pressed: bool) void {
        const button: events.PointerButton = switch (btn) {
            BTN_LEFT => .primary,
            BTN_RIGHT => .secondary,
            BTN_MIDDLE => .middle,
            else => return,
        };
        if (pressed) {
            self.pushInputEvent(.{ .pointer_down = .{
                .pointer_id = 0,
                .x = self.pointer_x,
                .y = self.pointer_y,
                .button = button,
                .is_touch = false,
            } });
        } else {
            self.pushInputEvent(.{ .pointer_up = .{
                .pointer_id = 0,
                .x = self.pointer_x,
                .y = self.pointer_y,
                .button = button,
                .is_touch = false,
            } });
        }
    }

    pub fn handlePointerAxis(self: *WaylandClient, dx: f32, dy: f32) void {
        if (!std.math.isFinite(dx) or !std.math.isFinite(dy)) return;
        self.pushInputEvent(.{ .wheel = .{
            .x = self.pointer_x,
            .y = self.pointer_y,
            .dx = dx,
            .dy = dy,
        } });
    }

    pub fn mapEvdevKey(evdev_keycode: u32) events.Key {
        return switch (evdev_keycode) {
            KEY_ESC => .escape,
            KEY_ENTER, KEY_KPENTER => .enter,
            KEY_TAB => .tab,
            KEY_SPACE => .space,
            KEY_BACKSPACE => .backspace,
            KEY_UP => .up,
            KEY_DOWN => .down,
            KEY_LEFT => .left,
            KEY_RIGHT => .right,
            KEY_HOME => .home,
            KEY_END => .end,
            else => .char,
        };
    }

    pub fn handleKey(
        self: *WaylandClient,
        evdev_keycode: u32,
        pressed: bool,
        mods: events.Modifiers,
    ) void {
        const key = mapEvdevKey(evdev_keycode);
        if (pressed) {
            self.pushInputEvent(.{ .key_down = .{
                .key = key,
                .mods = mods,
                .repeat = false,
                .codepoint = 0,
            } });
        } else {
            self.pushInputEvent(.{ .key_up = .{
                .key = key,
                .mods = mods,
            } });
        }
    }

    pub fn drainInputEvents(self: *WaylandClient) []const events.InputEvent {
        const n = self.input_len;
        if (n == 0) return &.{};
        @memcpy(self.drain_buf[0..n], self.input_queue[0..n]);
        self.input_len = 0;
        return self.drain_buf[0..n];
    }

    fn compactRecvBuf(self: *WaylandClient, consumed: usize) void {
        if (consumed == 0) return;
        const rem = self.recv_len - consumed;
        if (rem > 0) {
            std.mem.copyForwards(u8, self.recv_buf[0..rem], self.recv_buf[consumed..self.recv_len]);
        }
        self.recv_len = rem;
    }

    /// Reads pending wire messages from `sock_fd` and dispatches protocol events.
    pub fn readAndDispatch(self: *WaylandClient) !usize {
        if (self.sock_fd < 0 or self.recv_buf.len == 0) return error.NotConnected;
        if (self.disconnected) return error.ConnectionClosed;
        var dispatched: usize = 0;

        while (dispatched < MAX_DISPATCH_PER_CALL) {
            var hit_again = false;
            if (!self.peer_eof) {
                while (self.recv_len < self.recv_buf.len) {
                    const rc = linux.recvfrom(
                        self.sock_fd,
                        self.recv_buf[self.recv_len..].ptr,
                        self.recv_buf.len - self.recv_len,
                        0,
                        null,
                        null,
                    );
                    const err = linux.errno(rc);
                    switch (err) {
                        .SUCCESS => {
                            if (rc == 0) {
                                self.peer_eof = true;
                                break;
                            }
                            self.recv_len += rc;
                        },
                        .AGAIN => {
                            hit_again = true;
                            break;
                        },
                        .INTR => continue,
                        else => return error.RecvFailed,
                    }
                }
            }

            var consumed: usize = 0;
            defer self.compactRecvBuf(consumed);

            while (dispatched < MAX_DISPATCH_PER_CALL and self.recv_len - consumed >= 8) {
                const slice = self.recv_buf[consumed..self.recv_len];
                const size_and_opcode = std.mem.readInt(u32, slice[4..8], native_endian);
                const msg_size: usize = @intCast(size_and_opcode >> 16);
                if (msg_size < 8 or msg_size % 4 != 0) {
                    return error.InvalidMessageSize;
                }
                if (msg_size > self.recv_buf.len) {
                    return error.MessageTooLarge;
                }
                if (msg_size > slice.len) break;

                var dec = try WireDecoder.init(slice[0..msg_size]);
                try self.dispatchWireEvent(&dec);
                consumed += msg_size;
                dispatched += 1;
            }

            const made_progress = consumed > 0;
            self.compactRecvBuf(consumed);
            consumed = 0;

            if (dispatched >= MAX_DISPATCH_PER_CALL) break;

            if (self.peer_eof) {
                self.disconnected = true;
                if (self.recv_len > 0) return error.TruncatedMessage;
                if (dispatched == 0) return error.ConnectionClosed;
                break;
            }

            if (hit_again) break;

            if (!made_progress and self.recv_len == self.recv_buf.len) {
                return error.MessageTooLarge;
            }
        }

        return dispatched;
    }

    pub fn dispatchWireEvent(self: *WaylandClient, dec: *WireDecoder) !void {
        if (dec.object_id == self.registry_id) {
            switch (dec.opcode) {
                WL_REGISTRY_EVT_GLOBAL => {
                    const name = try dec.readU32();
                    const iface = try dec.readString();
                    const version = try dec.readU32();
                    try self.simulateRegistryGlobal(name, iface, version);
                },
                WL_REGISTRY_EVT_GLOBAL_REMOVE => {
                    const name = try dec.readU32();
                    var i: usize = 0;
                    while (i < self.outputs.items.len) {
                        if (self.outputs.items[i].global_name == name) {
                            _ = self.outputs.swapRemove(i);
                        } else {
                            i += 1;
                        }
                    }
                },
                else => {},
            }
            return;
        }

        if (self.xdg_wm_base_id != 0 and dec.object_id == self.xdg_wm_base_id) {
            if (dec.opcode == XDG_WM_BASE_EVT_PING) {
                const serial = try dec.readU32();
                var buf: [32]u8 = undefined;
                var enc = WireEncoder.init(&buf);
                try enc.writeU32(serial);
                try self.sendWireMsg(try enc.finish(self.xdg_wm_base_id, XDG_WM_BASE_PONG));
            }
            return;
        }

        if (self.seat_id != 0 and dec.object_id == self.seat_id) {
            if (dec.opcode == WL_SEAT_EVT_CAPABILITIES) {
                const caps = try dec.readU32();
                if ((caps & 1) != 0 and self.pointer_id == 0) {
                    const pid = try self.allocId();
                    var buf: [32]u8 = undefined;
                    var enc = WireEncoder.init(&buf);
                    try enc.writeU32(pid);
                    try self.sendWireMsg(try enc.finish(self.seat_id, WL_SEAT_GET_POINTER));
                    self.pointer_id = pid;
                }
                if ((caps & 2) != 0 and self.keyboard_id == 0) {
                    const kid = try self.allocId();
                    var buf: [32]u8 = undefined;
                    var enc = WireEncoder.init(&buf);
                    try enc.writeU32(kid);
                    try self.sendWireMsg(try enc.finish(self.seat_id, WL_SEAT_GET_KEYBOARD));
                    self.keyboard_id = kid;
                }
            }
            return;
        }

        if (self.pointer_id != 0 and dec.object_id == self.pointer_id) {
            switch (dec.opcode) {
                WL_POINTER_EVT_ENTER => {
                    _ = try dec.readU32(); // serial
                    _ = try dec.readU32(); // surface
                    const x = try dec.readFixed();
                    const y = try dec.readFixed();
                    self.handlePointerMotion(x, y);
                },
                WL_POINTER_EVT_LEAVE => {},
                WL_POINTER_EVT_MOTION => {
                    _ = try dec.readU32(); // time
                    const x = try dec.readFixed();
                    const y = try dec.readFixed();
                    self.handlePointerMotion(x, y);
                },
                WL_POINTER_EVT_BUTTON => {
                    _ = try dec.readU32(); // serial
                    _ = try dec.readU32(); // time
                    const button = try dec.readU32();
                    const state = try dec.readU32();
                    self.handlePointerButton(button, state != 0);
                },
                WL_POINTER_EVT_AXIS => {
                    _ = try dec.readU32(); // time
                    const axis = try dec.readU32();
                    const value = try dec.readFixed();
                    if (axis == 0) {
                        self.handlePointerAxis(0.0, value);
                    } else if (axis == 1) {
                        self.handlePointerAxis(value, 0.0);
                    }
                },
                else => {},
            }
            return;
        }

        if (self.keyboard_id != 0 and dec.object_id == self.keyboard_id) {
            switch (dec.opcode) {
                WL_KEYBOARD_EVT_LEAVE => {
                    self.active_mods = .{};
                    self.pushInputEvent(.focus_lost);
                },
                WL_KEYBOARD_EVT_KEY => {
                    _ = try dec.readU32(); // serial
                    _ = try dec.readU32(); // time
                    const keycode = try dec.readU32();
                    const state = try dec.readU32();
                    self.handleKey(keycode, state != 0, self.active_mods);
                },
                WL_KEYBOARD_EVT_MODIFIERS => {
                    _ = try dec.readU32(); // serial
                    const mods_depressed = try dec.readU32();
                    self.active_mods = .{
                        .shift = (mods_depressed & 1) != 0,
                        .ctrl = (mods_depressed & 4) != 0,
                        .alt = (mods_depressed & 8) != 0,
                        .super = (mods_depressed & 64) != 0,
                    };
                },
                else => {},
            }
            return;
        }

        for (self.outputs.items) |*out| {
            if (out.object_id == dec.object_id) {
                switch (dec.opcode) {
                    WL_OUTPUT_EVT_MODE => {
                        const flags = try dec.readU32();
                        const w = try dec.readI32();
                        const h = try dec.readI32();
                        const refresh = try dec.readI32();
                        if (w > 0 and h > 0 and ((flags & 1) != 0 or out.width_px == 0)) {
                            out.width_px = w;
                            out.height_px = h;
                            if (refresh > 0) {
                                out.refresh_mhz = refresh;
                            }
                        }
                    },
                    WL_OUTPUT_EVT_SCALE => {
                        const scale = try dec.readI32();
                        if (scale >= 1) {
                            out.scale_int = scale;
                        }
                    },
                    else => {},
                }
                return;
            }
        }

        for (self.surfaces.items) |*s| {
            if (s.layer_surface_id != 0 and dec.object_id == s.layer_surface_id) {
                switch (dec.opcode) {
                    ZWLR_LAYER_SURFACE_EVT_CONFIGURE => {
                        const serial = try dec.readU32();
                        const w = try dec.readU32();
                        const h = try dec.readU32();
                        try self.handleLayerConfigure(s.layer_surface_id, serial, w, h);
                    },
                    ZWLR_LAYER_SURFACE_EVT_CLOSED => {
                        s.closed = true;
                    },
                    else => {},
                }
                return;
            }
            if (s.xdg_surface_id != 0 and dec.object_id == s.xdg_surface_id) {
                if (dec.opcode == XDG_SURFACE_EVT_CONFIGURE) {
                    const serial = try dec.readU32();
                    try self.handleXdgConfigure(s.xdg_surface_id, serial);
                }
                return;
            }
            if (s.xdg_toplevel_id != 0 and dec.object_id == s.xdg_toplevel_id) {
                switch (dec.opcode) {
                    XDG_TOPLEVEL_EVT_CONFIGURE => {
                        const w = try dec.readI32();
                        const h = try dec.readI32();
                        if (w > 0) s.width = @intCast(w);
                        if (h > 0) s.height = @intCast(h);
                    },
                    XDG_TOPLEVEL_EVT_CLOSE => {
                        s.closed = true;
                    },
                    else => {},
                }
                return;
            }
            if (s.fractional_scale_id != 0 and dec.object_id == s.fractional_scale_id) {
                if (dec.opcode == WP_FRACTIONAL_SCALE_EVT_PREFERRED_SCALE) {
                    const scale_120 = try dec.readU32();
                    self.handleFractionalScale(s.surface_id, scale_120);
                }
                return;
            }
        }

        if (dec.object_id == WL_DISPLAY_ID) {
            if (dec.opcode == WL_DISPLAY_EVT_ERROR) {
                return error.WaylandProtocolError;
            }
            _ = WL_DISPLAY_EVT_DELETE_ID;
            _ = WL_DISPLAY_SYNC;
            _ = WL_SURFACE_DESTROY;
            _ = WL_SURFACE_ATTACH;
            _ = WL_SURFACE_FRAME;
            _ = WL_SURFACE_DAMAGE_BUFFER;
            _ = XDG_WM_BASE_DESTROY;
            _ = XDG_SURFACE_DESTROY;
            _ = XDG_TOPLEVEL_DESTROY;
            _ = ZWLR_LAYER_SURFACE_DESTROY;
            _ = WP_FRACTIONAL_SCALE_DESTROY;
        }
    }
};
