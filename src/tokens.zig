const std = @import("std");
const builtin = @import("builtin");
const linux = std.os.linux;
const core = @import("core.zig");

pub const MAGIC: u32 = 0x5A47544B; // "ZGTK"
pub const FORMAT_VERSION: u32 = 1;

pub const OklabColor = extern struct {
    l: f32,
    a: f32,
    b: f32,
    alpha: f32 = 1.0,

    pub fn toSrgb(self: OklabColor) core.Color {
        return core.oklabToSrgb(self.l, self.a, self.b, self.alpha);
    }

    /// Converts an sRGB `[4]f32` color (with `[0, 1]` channels) to perceptual Oklab.
    pub fn fromSrgb(color: core.Color) OklabColor {
        const safe = core.sanitizeColor(color);
        const r = srgbToLinear(safe[0]);
        const g = srgbToLinear(safe[1]);
        const b = srgbToLinear(safe[2]);

        const l = 0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b;
        const m = 0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b;
        const s = 0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b;

        const l_ = std.math.cbrt(@max(0.0, l));
        const m_ = std.math.cbrt(@max(0.0, m));
        const s_ = std.math.cbrt(@max(0.0, s));

        return .{
            .l = 0.2104542553 * l_ + 0.7936177850 * m_ - 0.0040720468 * s_,
            .a = 1.9779984951 * l_ - 2.4285922050 * m_ + 0.4505937099 * s_,
            .b = 0.0259040371 * l_ + 0.7827717662 * m_ - 0.8086757660 * s_,
            .alpha = safe[3],
        };
    }

    pub fn fromSrgbHex(comptime rgb: u24) OklabColor {
        @setEvalBranchQuota(5000);
        const r_srgb: f32 = @as(f32, @floatFromInt((rgb >> 16) & 0xFF)) / 255.0;
        const g_srgb: f32 = @as(f32, @floatFromInt((rgb >> 8) & 0xFF)) / 255.0;
        const b_srgb: f32 = @as(f32, @floatFromInt(rgb & 0xFF)) / 255.0;
        return fromSrgb(.{ r_srgb, g_srgb, b_srgb, 1.0 });
    }

    fn srgbToLinear(c: f32) f32 {
        const x = std.math.clamp(c, 0.0, 1.0);
        if (x <= 0.04045) return x / 12.92;
        return std.math.pow(f32, (x + 0.055) / 1.055, 2.4);
    }

    fn isValid(self: OklabColor) bool {
        return std.math.isFinite(self.l) and self.l >= 0.0 and self.l <= 1.0 and
            std.math.isFinite(self.a) and @abs(self.a) <= 1.0 and
            std.math.isFinite(self.b) and @abs(self.b) <= 1.0 and
            std.math.isFinite(self.alpha) and self.alpha >= 0.0 and self.alpha <= 1.0;
    }
};

pub const PseudoState = packed struct(u8) {
    hover: bool = false,
    active: bool = false,
    focus_visible: bool = false,
    disabled: bool = false,
    checked: bool = false,
    _pad: u3 = 0,
};

pub const ComponentKind = enum(u8) {
    surface,
    card,
    toggle,
    slider,
    bar,
    button,
    input,
};

pub const ResolvedStyle = struct {
    fill: core.Color,
    border: core.Color,
    text: core.Color,
    accent: core.Color,
    corner_radius: f32,
    border_width: f32,
    shadow_blur: f32,
};

pub const TokenTable = extern struct {
    magic: u32 = MAGIC,
    format_version: u32 = FORMAT_VERSION,
    version: u32 = 1,
    checksum: u32 = 0,

    // Oklab color palette
    bg_base: OklabColor,
    bg_surface: OklabColor,
    bg_elevated: OklabColor,
    border_default: OklabColor,
    border_focus: OklabColor,
    text_primary: OklabColor,
    text_muted: OklabColor,
    accent_primary: OklabColor,
    accent_success: OklabColor,
    accent_warn: OklabColor,
    accent_danger: OklabColor,

    // Logical spacing & geometry tokens
    space_xs: f32 = 4.0,
    space_sm: f32 = 8.0,
    space_md: f32 = 16.0,
    space_lg: f32 = 24.0,
    corner_radius_sm: f32 = 4.0,
    corner_radius_md: f32 = 8.0,
    corner_radius_lg: f32 = 16.0,
    border_width_default: f32 = 1.0,
    border_width_focus: f32 = 2.0,
    shadow_sm: f32 = 4.0,
    shadow_md: f32 = 12.0,

    const HEADER_SIZE: usize = 16;
    const MAX_GEOM_DP: f32 = 4096.0;

    comptime {
        std.debug.assert(@offsetOf(TokenTable, "version") == 8);
        std.debug.assert(@offsetOf(TokenTable, "checksum") == 12);
        std.debug.assert(@offsetOf(TokenTable, "bg_base") == HEADER_SIZE);
        std.debug.assert(@sizeOf(TokenTable) == HEADER_SIZE + 11 * @sizeOf(OklabColor) + 11 * @sizeOf(f32));
    }

    /// Returns the default perceptually uniform Oklab Nord token table with valid checksum.
    pub fn nordDefault() TokenTable {
        var t = TokenTable{
            .bg_base = OklabColor.fromSrgbHex(0x2E3440), // polar_night_0
            .bg_surface = OklabColor.fromSrgbHex(0x3B4252), // polar_night_1
            .bg_elevated = OklabColor.fromSrgbHex(0x434C5E), // polar_night_2
            .border_default = OklabColor.fromSrgbHex(0x4C566A), // polar_night_3
            .border_focus = OklabColor.fromSrgbHex(0x88C0D0), // frost_1
            .text_primary = OklabColor.fromSrgbHex(0xECEFF4), // snow_storm_2
            .text_muted = OklabColor.fromSrgbHex(0x9099AB), // muted slate
            .accent_primary = OklabColor.fromSrgbHex(0x5E81AC), // frost_3
            .accent_success = OklabColor.fromSrgbHex(0xA3BE8C), // aurora_green
            .accent_warn = OklabColor.fromSrgbHex(0xEBCB8B), // aurora_yellow
            .accent_danger = OklabColor.fromSrgbHex(0xBF616A), // aurora_red
        };
        t.checksum = t.computeChecksum();
        return t;
    }

    /// Computes IEEE CRC32 over header fields preceding `checksum` (`0..12`) and payload (`16..`).
    pub fn computeChecksum(self: *const TokenTable) u32 {
        const bytes = std.mem.asBytes(self);
        var hasher = std.hash.Crc32.init();
        hasher.update(bytes[0..12]);
        hasher.update(bytes[HEADER_SIZE..]);
        return hasher.final();
    }

    fn isValidGeom(v: f32) bool {
        return std.math.isFinite(v) and v >= 0.0 and v <= MAX_GEOM_DP;
    }

    /// Validates magic, format_version, CRC32 checksum, bounded Oklab colors, and finite geometry tokens.
    pub fn isValid(self: *const TokenTable) bool {
        if (self.magic != MAGIC) return false;
        if (self.format_version != FORMAT_VERSION) return false;
        if (self.checksum != self.computeChecksum()) return false;

        const colors = [_]OklabColor{
            self.bg_base,
            self.bg_surface,
            self.bg_elevated,
            self.border_default,
            self.border_focus,
            self.text_primary,
            self.text_muted,
            self.accent_primary,
            self.accent_success,
            self.accent_warn,
            self.accent_danger,
        };
        for (colors) |c| {
            if (!c.isValid()) return false;
        }

        const scalars = [_]f32{
            self.space_xs,
            self.space_sm,
            self.space_md,
            self.space_lg,
            self.corner_radius_sm,
            self.corner_radius_md,
            self.corner_radius_lg,
            self.border_width_default,
            self.border_width_focus,
            self.shadow_sm,
            self.shadow_md,
        };
        for (scalars) |v| {
            if (!isValidGeom(v)) return false;
        }

        return true;
    }

    /// Resolves a component's base style and applies scoped pseudostates deterministically in Oklab space.
    pub fn resolve(self: *const TokenTable, kind: ComponentKind, state: PseudoState) ResolvedStyle {
        var fill_ok: OklabColor = switch (kind) {
            .surface => self.bg_base,
            .card => self.bg_surface,
            .toggle => self.bg_elevated,
            .slider => self.bg_elevated,
            .bar => self.bg_surface,
            .button => self.bg_elevated,
            .input => self.bg_base,
        };
        var border_ok: OklabColor = self.border_default;
        var text_ok: OklabColor = self.text_primary;
        var accent_ok: OklabColor = self.accent_primary;

        const corner_radius: f32 = switch (kind) {
            .surface => 0.0,
            .card, .button => self.corner_radius_md,
            .toggle => self.corner_radius_lg,
            .slider, .bar, .input => self.corner_radius_sm,
        };
        var border_width: f32 = switch (kind) {
            .surface => 0.0,
            .card, .toggle, .slider, .bar, .button, .input => self.border_width_default,
        };
        const shadow_blur: f32 = switch (kind) {
            .card, .bar, .button => self.shadow_sm,
            .surface, .toggle, .slider, .input => 0.0,
        };

        if (state.checked) {
            fill_ok = self.accent_primary;
            border_ok = self.accent_primary;
        }

        if (!state.disabled) {
            if (state.active) {
                fill_ok.l = std.math.clamp(fill_ok.l - 0.03, 0.0, 1.0);
            } else if (state.hover) {
                fill_ok.l = std.math.clamp(fill_ok.l + 0.04, 0.0, 1.0);
            }
            if (state.focus_visible) {
                border_ok = self.border_focus;
                border_width = self.border_width_focus;
            }
        }

        if ((kind == .button or kind == .toggle) and state.checked) {
            text_ok = if (fill_ok.l >= 0.58)
                OklabColor{ .l = 0.14, .a = 0.0, .b = 0.0, .alpha = 1.0 }
            else
                OklabColor{ .l = 0.98, .a = 0.0, .b = 0.0, .alpha = 1.0 };
        }

        if (state.disabled) {
            fill_ok.alpha = std.math.clamp(fill_ok.alpha * 0.55, 0.0, 1.0);
            border_ok.alpha = std.math.clamp(border_ok.alpha * 0.55, 0.0, 1.0);
            accent_ok.alpha = std.math.clamp(accent_ok.alpha * 0.55, 0.0, 1.0);
            text_ok.l = std.math.clamp(text_ok.l + (self.text_muted.l - text_ok.l) * 0.65, 0.0, 1.0);
            text_ok.a = std.math.clamp(text_ok.a + (self.text_muted.a - text_ok.a) * 0.65, -1.0, 1.0);
            text_ok.b = std.math.clamp(text_ok.b + (self.text_muted.b - text_ok.b) * 0.65, -1.0, 1.0);
            text_ok.alpha = std.math.clamp(text_ok.alpha + (self.text_muted.alpha - text_ok.alpha) * 0.65, 0.0, 1.0);
        }

        return .{
            .fill = fill_ok.toSrgb(),
            .border = border_ok.toSrgb(),
            .text = text_ok.toSrgb(),
            .accent = accent_ok.toSrgb(),
            .corner_radius = corner_radius,
            .border_width = border_width,
            .shadow_blur = shadow_blur,
        };
    }
};

// Kernel `struct stat` matching Linux ABI for `fstat`/`fstatat64` (works on Linux 3.10+ / Android API 24+).
const KernelStat = switch (builtin.cpu.arch) {
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

fn linuxFstat(fd: i32, st: *KernelStat) linux.E {
    while (true) {
        const rc = linux.syscall2(.fstat, @as(usize, @bitCast(@as(isize, fd))), @intFromPtr(st));
        const err = linux.errno(rc);
        if (err == .INTR) continue;
        return err;
    }
}

fn linuxFstatat(dirfd: i32, path: [*:0]const u8, st: *KernelStat, flags: u32) linux.E {
    while (true) {
        const rc = linux.syscall4(.fstatat64, @as(usize, @bitCast(@as(isize, dirfd))), @intFromPtr(path), @intFromPtr(st), flags);
        const err = linux.errno(rc);
        if (err == .INTR) continue;
        return err;
    }
}

var tmp_seq: std.atomic.Value(u32) = std.atomic.Value(u32).init(0);

/// Computes checksum on a copy, validates it, and atomically writes to `path` via exclusive temp file + renameat.
pub fn writeTokenFile(path: [*:0]const u8, table: *const TokenTable) !void {
    const path_slice = std.mem.span(path);
    if (path_slice.len == 0 or path_slice[path_slice.len - 1] == '/') {
        return error.InvalidPath;
    }

    var copy = table.*;
    copy.checksum = copy.computeChecksum();
    if (!copy.isValid()) {
        return error.InvalidTokenTable;
    }
    const bytes = std.mem.asBytes(&copy);

    const pid = linux.getpid();
    var tmp_buf: [4096]u8 = undefined;
    var tmp_path: [*:0]const u8 = undefined;
    var fd: i32 = -1;
    var attempts: usize = 0;

    while (true) : (attempts += 1) {
        if (attempts >= 128) return error.OpenFailed;
        const seq = tmp_seq.fetchAdd(1, .monotonic);
        const tmp_slice = if (std.mem.lastIndexOfScalar(u8, path_slice, '/')) |idx| blk: {
            const prefix = if (idx == 0) "" else path_slice[0..idx];
            break :blk std.fmt.bufPrint(&tmp_buf, "{s}/.zgt.{d}.{d}\x00", .{ prefix, pid, seq }) catch return error.NameTooLong;
        } else std.fmt.bufPrint(&tmp_buf, ".zgt.{d}.{d}\x00", .{ pid, seq }) catch return error.NameTooLong;
        tmp_path = @ptrCast(tmp_slice.ptr);

        const rc = linux.openat(linux.AT.FDCWD, tmp_path, .{
            .ACCMODE = .WRONLY,
            .CREAT = true,
            .EXCL = true,
            .CLOEXEC = true,
        }, 0o644);
        const err = linux.errno(rc);
        switch (err) {
            .SUCCESS => {
                fd = @intCast(rc);
                break;
            },
            .INTR, .EXIST => continue,
            else => return error.OpenFailed,
        }
    }

    var fd_open = true;
    errdefer {
        if (fd_open) _ = linux.close(fd);
        _ = linux.unlinkat(linux.AT.FDCWD, tmp_path, 0);
    }

    var written: usize = 0;
    while (written < bytes.len) {
        const rc = linux.write(fd, bytes[written..].ptr, bytes.len - written);
        const err = linux.errno(rc);
        switch (err) {
            .SUCCESS => {
                if (rc == 0) return error.WriteFailed;
                written += rc;
            },
            .INTR => continue,
            else => return error.WriteFailed,
        }
    }

    const close_rc = linux.close(fd);
    fd_open = false;
    if (linux.errno(close_rc) != .SUCCESS) {
        return error.CloseFailed;
    }

    while (true) {
        const rc = linux.renameat(linux.AT.FDCWD, tmp_path, linux.AT.FDCWD, path);
        const err = linux.errno(rc);
        switch (err) {
            .SUCCESS => break,
            .INTR => continue,
            else => return error.RenameFailed,
        }
    }
}

pub const MmapTokenBuffer = struct {
    fd: i32 = -1,
    mapped: ?[*]const u8 = null,
    dev: u64 = 0,
    ino: u64 = 0,
    path_buf: [4096]u8 = undefined,
    path_len: usize = 0,
    active: TokenTable,

    fn pathPtr(self: *const MmapTokenBuffer) [*:0]const u8 {
        return @ptrCast(&self.path_buf);
    }

    fn preadTokenTable(fd: i32) !TokenTable {
        var candidate: TokenTable = undefined;
        const dst = std.mem.asBytes(&candidate);
        var total: usize = 0;
        while (total < dst.len) {
            const rc = linux.pread(fd, dst[total..].ptr, dst.len - total, @intCast(total));
            const err = linux.errno(rc);
            switch (err) {
                .SUCCESS => {
                    if (rc == 0) return error.UnexpectedEof;
                    total += rc;
                },
                .INTR => continue,
                else => return error.ReadFailed,
            }
        }
        if (!candidate.isValid()) {
            return error.InvalidTokenTable;
        }
        return candidate;
    }

    fn openAndMap(path: [*:0]const u8) !struct {
        fd: i32,
        mapped: [*]const u8,
        dev: u64,
        ino: u64,
        table: TokenTable,
    } {
        const fd: i32 = blk: {
            while (true) {
                const rc = linux.openat(
                    linux.AT.FDCWD,
                    path,
                    .{ .ACCMODE = .RDONLY, .NONBLOCK = true, .CLOEXEC = true },
                    0,
                );
                const err = linux.errno(rc);
                switch (err) {
                    .SUCCESS => break :blk @intCast(rc),
                    .INTR => continue,
                    else => return error.OpenFailed,
                }
            }
        };
        errdefer _ = linux.close(fd);

        var st: KernelStat = undefined;
        if (linuxFstat(fd, &st) != .SUCCESS) {
            return error.StatFailed;
        }
        if ((st.mode & linux.S.IFMT) != linux.S.IFREG) {
            return error.NotRegularFile;
        }
        if (st.size != @sizeOf(TokenTable)) {
            return error.InvalidTokenFileSize;
        }

        const candidate = try preadTokenTable(fd);

        const map_rc = linux.mmap(
            null,
            @sizeOf(TokenTable),
            .{ .READ = true },
            .{ .TYPE = .SHARED },
            fd,
            0,
        );
        if (linux.errno(map_rc) != .SUCCESS) {
            return error.MmapFailed;
        }
        const mapped: [*]const u8 = @ptrFromInt(map_rc);

        return .{
            .fd = fd,
            .mapped = mapped,
            .dev = st.dev,
            .ino = st.ino,
            .table = candidate,
        };
    }

    /// Opens `path`, verifies regular file & size == `@sizeOf(TokenTable)`, snapshots via `pread`, and maps `MAP.SHARED`.
    pub fn open(path: [*:0]const u8) !MmapTokenBuffer {
        const path_slice = std.mem.span(path);
        if (path_slice.len == 0 or path_slice.len >= 4096 or path_slice[path_slice.len - 1] == '/') {
            return error.InvalidPath;
        }

        const res = try openAndMap(path);
        var buf = MmapTokenBuffer{
            .fd = res.fd,
            .mapped = res.mapped,
            .dev = res.dev,
            .ino = res.ino,
            .path_len = path_slice.len,
            .active = res.table,
        };
        @memcpy(buf.path_buf[0..path_slice.len], path_slice);
        buf.path_buf[path_slice.len] = 0;
        return buf;
    }

    /// Unmaps the token buffer and closes its fd cleanly. Safe on double-close.
    pub fn close(self: *MmapTokenBuffer) void {
        if (self.mapped) |ptr| {
            _ = linux.munmap(ptr, @sizeOf(TokenTable));
            self.mapped = null;
        }
        if (self.fd >= 0) {
            _ = linux.close(self.fd);
            self.fd = -1;
        }
    }

    /// Returns the currently active validated token table snapshot.
    pub fn current(self: *const MmapTokenBuffer) *const TokenTable {
        return &self.active;
    }

    /// Polls disk for updates via `fstatat`/`fstat` + `pread`; swaps into `active` only when valid and version/checksum changed.
    pub fn pollReload(self: *MmapTokenBuffer) bool {
        if (self.fd < 0 or self.mapped == null) return false;

        var path_st: KernelStat = undefined;
        if (linuxFstatat(linux.AT.FDCWD, self.pathPtr(), &path_st, 0) != .SUCCESS) {
            return false;
        }
        if ((path_st.mode & linux.S.IFMT) != linux.S.IFREG or path_st.size != @sizeOf(TokenTable)) {
            return false;
        }

        if (path_st.dev != self.dev or path_st.ino != self.ino) {
            const next = openAndMap(self.pathPtr()) catch return false;
            if (self.mapped) |old_ptr| {
                _ = linux.munmap(old_ptr, @sizeOf(TokenTable));
            }
            if (self.fd >= 0) {
                _ = linux.close(self.fd);
            }
            self.fd = next.fd;
            self.mapped = next.mapped;
            self.dev = next.dev;
            self.ino = next.ino;

            if (next.table.version != self.active.version or next.table.checksum != self.active.checksum) {
                self.active = next.table;
                return true;
            }
            return false;
        }

        var fd_st: KernelStat = undefined;
        if (linuxFstat(self.fd, &fd_st) != .SUCCESS) {
            return false;
        }
        if ((fd_st.mode & linux.S.IFMT) != linux.S.IFREG or fd_st.size != @sizeOf(TokenTable)) {
            return false;
        }

        const candidate = preadTokenTable(self.fd) catch return false;
        if (candidate.version != self.active.version or candidate.checksum != self.active.checksum) {
            self.active = candidate;
            return true;
        }
        return false;
    }
};
