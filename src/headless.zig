const std = @import("std");
const core = @import("core.zig");
const events = @import("events.zig");

pub const DiagnosticCode = enum {
    overflow,
    zero_size,
    occluded_target,
    small_touch_target,
    low_contrast,
};

pub const Diagnostic = struct {
    code: DiagnosticCode,
    id: core.NodeId,
    test_id: []const u8,
    value: f32 = 0.0,
};

pub const Action = union(enum) {
    click_id: []const u8,
    set_slider_id: struct { id: []const u8, value: f32 },
    key: struct { key: events.Key, mods: events.Modifiers = .{}, codepoint: u21 = 0 },
    raw: events.InputEvent,
};

pub const StepResult = struct {
    quad_count: usize,
    events: []const events.UiEvent,
    frame: u64,
    virtual_time_ms: f64,
};

pub const DiffStats = struct {
    mismatched_pixels: usize,
    max_diff: u8,
};

pub const HeadlessSession = struct {
    allocator: std.mem.Allocator,
    arena: core.LayoutArena,
    router: events.EventRouter,
    viewport_w: f32,
    viewport_h: f32,
    scale_factor: f32,
    virtual_time_ms: f64 = 0.0,
    frame_count: u64 = 0,
    touch_profile: bool = false,
    quad_buf: [2048]core.QuadInstance = undefined,
    last_quad_count: usize = 0,
    step_events: [128]events.UiEvent = undefined,
    step_events_len: usize = 0,

    pub fn init(
        allocator: std.mem.Allocator,
        viewport_w: f32,
        viewport_h: f32,
        scale_factor: f32,
    ) error{InvalidViewport}!HeadlessSession {
        if (!isPositiveFinite(viewport_w) or !isPositiveFinite(viewport_h) or !isPositiveFinite(scale_factor)) {
            return error.InvalidViewport;
        }
        return .{
            .allocator = allocator,
            .arena = core.LayoutArena.init(allocator),
            .router = events.EventRouter.init(),
            .viewport_w = viewport_w,
            .viewport_h = viewport_h,
            .scale_factor = scale_factor,
        };
    }

    pub fn deinit(self: *HeadlessSession) void {
        self.arena.deinit();
    }

    pub fn setViewport(self: *HeadlessSession, w: f32, h: f32, scale: f32) void {
        if (!isPositiveFinite(w) or !isPositiveFinite(h) or !isPositiveFinite(scale)) return;
        self.viewport_w = w;
        self.viewport_h = h;
        self.scale_factor = scale;
        self.arena.layout(self.viewport_w, self.viewport_h);
        self.arena.requestRedraw();
    }

    pub fn act(
        self: *HeadlessSession,
        action: Action,
    ) error{ NodeNotFound, ZeroSizeNode, NodeNotSlider }!void {
        switch (action) {
            .click_id => |id_str| {
                const id = self.arena.findByTestId(id_str) orelse return error.NodeNotFound;
                const rect = self.arena.getRect(id) orelse return error.NodeNotFound;
                if (rect.w <= 0.0 or rect.h <= 0.0) return error.ZeroSizeNode;
                const cx = rect.x + rect.w * 0.5;
                const cy = rect.y + rect.h * 0.5;
                self.router.dispatch(&self.arena, .{ .pointer_down = .{
                    .pointer_id = 0,
                    .x = cx,
                    .y = cy,
                    .button = .primary,
                    .is_touch = self.touch_profile,
                } });
                self.router.dispatch(&self.arena, .{ .pointer_up = .{
                    .pointer_id = 0,
                    .x = cx,
                    .y = cy,
                    .button = .primary,
                    .is_touch = self.touch_profile,
                } });
            },
            .set_slider_id => |s| {
                const id = self.arena.findByTestId(s.id) orelse return error.NodeNotFound;
                if (self.arena.getKind(id) != .slider) return error.NodeNotSlider;
                const rect = self.arena.getRect(id) orelse return error.NodeNotFound;
                if (rect.w <= 0.0 or rect.h <= 0.0) return error.ZeroSizeNode;
                const tb = core.sliderTrackBounds(rect);
                const val = if (std.math.isFinite(s.value)) std.math.clamp(s.value, 0.0, 1.0) else 0.0;
                const x = tb.x + tb.w * val;
                const cy = rect.y + rect.h * 0.5;
                self.router.dispatch(&self.arena, .{ .pointer_down = .{
                    .pointer_id = 0,
                    .x = x,
                    .y = cy,
                    .button = .primary,
                    .is_touch = self.touch_profile,
                } });
                self.router.dispatch(&self.arena, .{ .pointer_move = .{
                    .pointer_id = 0,
                    .x = x,
                    .y = cy,
                    .is_touch = self.touch_profile,
                } });
                self.router.dispatch(&self.arena, .{ .pointer_up = .{
                    .pointer_id = 0,
                    .x = x,
                    .y = cy,
                    .button = .primary,
                    .is_touch = self.touch_profile,
                } });
            },
            .key => |k| {
                self.router.dispatch(&self.arena, .{ .key_down = .{
                    .key = k.key,
                    .mods = k.mods,
                    .repeat = false,
                    .codepoint = k.codepoint,
                } });
                self.router.dispatch(&self.arena, .{ .key_up = .{
                    .key = k.key,
                    .mods = k.mods,
                } });
            },
            .raw => |ev| {
                self.router.dispatch(&self.arena, ev);
            },
        }
    }

    pub fn step(self: *HeadlessSession, dt_ms: f64) StepResult {
        if (std.math.isFinite(dt_ms) and dt_ms > 0.0) {
            self.virtual_time_ms += dt_ms;
        }
        self.arena.layout(self.viewport_w, self.viewport_h);
        self.last_quad_count = self.arena.emitQuads(&self.quad_buf, self.scale_factor);

        const polled = self.router.pollEvents();
        const copy_len = @min(polled.len, self.step_events.len);
        if (copy_len > 0) {
            @memcpy(self.step_events[0..copy_len], polled[0..copy_len]);
        }
        self.step_events_len = copy_len;
        self.router.clearEvents();

        self.arena.consumeRedraw();
        self.frame_count += 1;

        return .{
            .quad_count = self.last_quad_count,
            .events = self.step_events[0..self.step_events_len],
            .frame = self.frame_count,
            .virtual_time_ms = self.virtual_time_ms,
        };
    }

    pub fn runDiagnostics(self: *const HeadlessSession, out_buf: []Diagnostic) usize {
        var count: usize = 0;
        const slice = self.arena.nodes.slice();
        const n = self.arena.nodes.len;
        const gens = slice.items(.gen);
        const kinds = slice.items(.kind);
        const test_ids = slice.items(.test_id);
        const labels = slice.items(.label);
        const text_colors = slice.items(.text_color);
        const fills = slice.items(.fill);
        const parents = slice.items(.parent);
        const rects = slice.items(.rect);
        const scroll_props = slice.items(.scroll_props);

        for (0..n) |i| {
            const idx: u16 = @intCast(i);
            const id = core.NodeId{ .index = idx, .gen = gens[i] };
            const tid = test_ids[i];
            const r = rects[i];
            const kind = kinds[i];

            if (parents[i]) |p_idx| {
                if (!scroll_props[p_idx].clip_children) {
                    const pr = rects[p_idx];
                    const ov_left = pr.x - r.x;
                    const ov_top = pr.y - r.y;
                    const ov_right = (r.x + r.w) - (pr.x + pr.w);
                    const ov_bottom = (r.y + r.h) - (pr.y + pr.h);
                    const max_ov = @max(@max(ov_left, ov_top), @max(ov_right, ov_bottom));
                    if (max_ov > 0.5) {
                        pushDiagnostic(out_buf, &count, .{
                            .code = .overflow,
                            .id = id,
                            .test_id = tid,
                            .value = max_ov,
                        });
                    }
                }
            }

            if (r.w <= 0.0 or r.h <= 0.0) {
                pushDiagnostic(out_buf, &count, .{
                    .code = .zero_size,
                    .id = id,
                    .test_id = tid,
                    .value = @min(r.w, r.h),
                });
            }

            const is_interactive = (kind == .toggle or kind == .slider);

            if (is_interactive and r.w > 0.0 and r.h > 0.0) {
                const cx = r.x + r.w * 0.5;
                const cy = r.y + r.h * 0.5;
                if (inAncestorClips(idx, cx, cy, parents, rects, scroll_props, n)) {
                    const in_viewport = cx >= 0.0 and cy >= 0.0 and cx <= self.viewport_w and cy <= self.viewport_h;
                    const hit_ok = if (in_viewport) blk: {
                        const hit = self.arena.hitTest(cx, cy) orelse break :blk false;
                        break :blk hitResolvesToTarget(&self.arena, hit, id);
                    } else false;
                    if (!hit_ok) {
                        pushDiagnostic(out_buf, &count, .{
                            .code = .occluded_target,
                            .id = id,
                            .test_id = tid,
                            .value = 0.0,
                        });
                    }
                }
            }

            if (self.touch_profile and is_interactive) {
                if (r.w < 44.0 or r.h < 44.0) {
                    pushDiagnostic(out_buf, &count, .{
                        .code = .small_touch_target,
                        .id = id,
                        .test_id = tid,
                        .value = @min(r.w, r.h),
                    });
                }
            }

            if (labels[i].len > 0) {
                const tc = text_colors[i];
                if (!std.math.isFinite(tc[3]) or tc[3] < 0.5) {
                    pushDiagnostic(out_buf, &count, .{
                        .code = .low_contrast,
                        .id = id,
                        .test_id = tid,
                        .value = 0.0,
                    });
                } else {
                    const eff_bg = resolveEffectiveBg(idx, parents, fills);
                    const eff_text = compositeOver(clampColor(tc), eff_bg);
                    const l_text = core.srgbToOklabL(eff_text);
                    const l_bg = core.srgbToOklabL(eff_bg);
                    const diff_l = @abs(l_text - l_bg);
                    if (diff_l < 0.25) {
                        pushDiagnostic(out_buf, &count, .{
                            .code = .low_contrast,
                            .id = id,
                            .test_id = tid,
                            .value = diff_l,
                        });
                    }
                }
            }
        }

        return count;
    }

    pub fn dumpJson(self: *const HeadlessSession, writer: anytype) !void {
        try writer.writeAll("{");
        try writer.print(
            "\"viewport\":{{\"w\":{d:.2},\"h\":{d:.2}}},\"scale\":{d:.3},\"frame\":{d},\"virtual_time_ms\":{d:.3},",
            .{
                finiteOrZero32(self.viewport_w),
                finiteOrZero32(self.viewport_h),
                finiteOrZero32(self.scale_factor),
                self.frame_count,
                if (std.math.isFinite(self.virtual_time_ms)) self.virtual_time_ms else 0.0,
            },
        );

        try writer.writeAll("\"nodes\":[");
        const slice = self.arena.nodes.slice();
        const n = self.arena.nodes.len;
        const gens = slice.items(.gen);
        const kinds = slice.items(.kind);
        const roles = slice.items(.role);
        const test_ids = slice.items(.test_id);
        const labels = slice.items(.label);
        const rects = slice.items(.rect);
        const checkeds = slice.items(.checked);
        const slider_vals = slice.items(.slider_val);

        for (0..n) |i| {
            if (i > 0) try writer.writeAll(",");
            const r = rects[i];
            try writer.print(
                "{{\"id\":{{\"index\":{d},\"gen\":{d}}},\"kind\":",
                .{ i, gens[i] },
            );
            try writeJsonString(writer, @tagName(kinds[i]));
            try writer.writeAll(",\"role\":");
            try writeJsonString(writer, @tagName(roles[i]));
            try writer.writeAll(",\"test_id\":");
            try writeJsonString(writer, test_ids[i]);
            try writer.writeAll(",\"label\":");
            try writeJsonString(writer, labels[i]);
            try writer.print(
                ",\"rect\":{{\"x\":{d:.2},\"y\":{d:.2},\"w\":{d:.2},\"h\":{d:.2}}},\"checked\":{},\"slider_val\":{d:.4}}}",
                .{
                    finiteOrZero32(r.x),
                    finiteOrZero32(r.y),
                    finiteOrZero32(r.w),
                    finiteOrZero32(r.h),
                    checkeds[i],
                    finiteOrZero32(slider_vals[i]),
                },
            );
        }
        try writer.writeAll("],");

        try writer.writeAll("\"diagnostics\":[");
        var diags: [256]Diagnostic = undefined;
        const n_diag = self.runDiagnostics(&diags);
        for (diags[0..n_diag], 0..) |d, i| {
            if (i > 0) try writer.writeAll(",");
            try writer.writeAll("{\"code\":");
            try writeJsonString(writer, @tagName(d.code));
            try writer.print(",\"id\":{{\"index\":{d},\"gen\":{d}}},\"test_id\":", .{ d.id.index, d.id.gen });
            try writeJsonString(writer, d.test_id);
            try writer.print(",\"value\":{d:.4}}}", .{finiteOrZero32(d.value)});
        }
        try writer.writeAll("]}");
    }

    pub fn renderSnapshotRgba(
        self: *const HeadlessSession,
        allocator: std.mem.Allocator,
        annotate_bounds: bool,
    ) ![]u8 {
        if (!isPositiveFinite(self.viewport_w) or !isPositiveFinite(self.viewport_h) or !isPositiveFinite(self.scale_factor)) {
            return error.InvalidViewport;
        }
        const phys_w_f = @max(1.0, @round(self.viewport_w * self.scale_factor));
        const phys_h_f = @max(1.0, @round(self.viewport_h * self.scale_factor));
        if (!std.math.isFinite(phys_w_f) or !std.math.isFinite(phys_h_f) or
            phys_w_f > 16384.0 or phys_h_f > 16384.0)
        {
            return error.InvalidViewport;
        }
        const phys_w: usize = @intFromFloat(phys_w_f);
        const phys_h: usize = @intFromFloat(phys_h_f);
        const px_count = try std.math.mul(usize, phys_w, phys_h);
        const byte_len = try std.math.mul(usize, px_count, 4);

        const buf = try allocator.alloc(u8, byte_len);
        errdefer allocator.free(buf);

        const bg_r = floatToU8(core.Nord.polar_night_0[0]);
        const bg_g = floatToU8(core.Nord.polar_night_0[1]);
        const bg_b = floatToU8(core.Nord.polar_night_0[2]);
        const bg_a = floatToU8(core.Nord.polar_night_0[3]);
        var p: usize = 0;
        while (p < byte_len) : (p += 4) {
            buf[p + 0] = bg_r;
            buf[p + 1] = bg_g;
            buf[p + 2] = bg_b;
            buf[p + 3] = bg_a;
        }

        const quads = self.quad_buf[0..@min(self.last_quad_count, self.quad_buf.len)];
        for (quads) |q| {
            rasterizeQuad(buf, phys_w, phys_h, q);
        }

        if (annotate_bounds) {
            const slice = self.arena.nodes.slice();
            const rects = slice.items(.rect);
            const kinds = slice.items(.kind);
            for (0..self.arena.nodes.len) |i| {
                const pr = core.snapRectToPhysical(rects[i], self.scale_factor);
                const col: core.Color = switch (kinds[i]) {
                    .toggle => core.Nord.aurora_green,
                    .slider => core.Nord.aurora_yellow,
                    .bar => core.Nord.aurora_orange,
                    .card => core.Nord.aurora_purple,
                    .vstack, .hstack, .zstack, .grid => core.Nord.aurora_red,
                };
                drawOutlineRect(buf, phys_w, phys_h, pr, col);
            }
        }

        return buf;
    }
};

pub fn diffRgba(a: []const u8, b: []const u8, max_channel_delta: u8) DiffStats {
    const a_full = a.len / 4;
    const b_full = b.len / 4;
    const min_full = @min(a_full, b_full);

    var mismatched: usize = 0;
    var max_diff: u8 = 0;

    for (0..min_full) |i| {
        const off = i * 4;
        var px_max: u8 = 0;
        for (0..4) |c| {
            const va = a[off + c];
            const vb = b[off + c];
            const d: u8 = if (va > vb) va - vb else vb - va;
            if (d > px_max) px_max = d;
        }
        if (px_max > max_diff) max_diff = px_max;
        if (px_max > max_channel_delta) mismatched += 1;
    }

    if (a.len != b.len) {
        max_diff = 255;
        const total_a_slots = (a.len + 3) / 4;
        const total_b_slots = (b.len + 3) / 4;
        const max_slots = @max(total_a_slots, total_b_slots);
        mismatched += max_slots - min_full;
    } else if (a.len % 4 != 0) {
        const rem_start = min_full * 4;
        var rem_max: u8 = 0;
        for (rem_start..a.len) |idx| {
            const va = a[idx];
            const vb = b[idx];
            const d: u8 = if (va > vb) va - vb else vb - va;
            if (d > rem_max) rem_max = d;
        }
        if (rem_max > max_diff) max_diff = rem_max;
        if (rem_max > max_channel_delta) mismatched += 1;
    }

    return .{
        .mismatched_pixels = mismatched,
        .max_diff = max_diff,
    };
}

pub fn encodePng(writer: anytype, width: u32, height: u32, rgba: []const u8) !void {
    if (width == 0 or height == 0) return error.InvalidDimensions;
    const row_bytes_u64: u64 = @as(u64, width) * 4;
    const expected_rgba_u64 = std.math.mul(u64, row_bytes_u64, @as(u64, height)) catch return error.ImageTooLarge;
    if (expected_rgba_u64 > std.math.maxInt(usize)) return error.ImageTooLarge;
    const expected_rgba: usize = @intCast(expected_rgba_u64);
    if (rgba.len != expected_rgba) return error.InvalidBufferSize;

    const raw_row_len_u64: u64 = 1 + row_bytes_u64;
    const total_raw_len_u64 = std.math.mul(u64, raw_row_len_u64, @as(u64, height)) catch return error.ImageTooLarge;
    if (total_raw_len_u64 > std.math.maxInt(u32)) return error.ImageTooLarge;

    const num_blocks = try std.math.divCeil(u64, total_raw_len_u64, 65535);
    const idat_len_u64 = 2 + num_blocks * 5 + total_raw_len_u64 + 4;
    if (idat_len_u64 > std.math.maxInt(u32)) return error.ImageTooLarge;

    const png_sig = [_]u8{ 0x89, 'P', 'N', 'G', 0x0D, 0x0A, 0x1A, 0x0A };
    try writer.writeAll(&png_sig);

    // IHDR
    var ihdr: [13]u8 = undefined;
    std.mem.writeInt(u32, ihdr[0..4], width, .big);
    std.mem.writeInt(u32, ihdr[4..8], height, .big);
    ihdr[8] = 8; // bit depth
    ihdr[9] = 6; // RGBA
    ihdr[10] = 0; // compression
    ihdr[11] = 0; // filter
    ihdr[12] = 0; // interlace
    try writePngChunk(writer, "IHDR", &ihdr);

    // IDAT (zlib stored deflate blocks, streamed in O(1) memory)
    const idat_len: u32 = @intCast(idat_len_u64);
    var len_be: [4]u8 = undefined;
    std.mem.writeInt(u32, &len_be, idat_len, .big);
    try writer.writeAll(&len_be);

    var crc = std.hash.Crc32.init();
    const idat_tag = "IDAT";
    try writer.writeAll(idat_tag);
    crc.update(idat_tag);

    const zlib_hdr = [_]u8{ 0x78, 0x01 };
    try writer.writeAll(&zlib_hdr);
    crc.update(&zlib_hdr);

    var adler_s1: u32 = 1;
    var adler_s2: u32 = 0;

    const row_bytes: usize = @intCast(row_bytes_u64);
    const raw_row_len: usize = @intCast(raw_row_len_u64);
    var cur_row: usize = 0;
    var cur_col: usize = 0; // 0 = filter byte, 1..row_bytes+1 = pixel bytes
    var remaining: usize = @intCast(total_raw_len_u64);

    while (remaining > 0) {
        const block_len_usize = @min(remaining, 65535);
        const block_len: u16 = @intCast(block_len_usize);
        const is_last = (remaining == block_len_usize);
        const nlen: u16 = ~block_len;
        const b_hdr = [_]u8{
            if (is_last) 0x01 else 0x00,
            @truncate(block_len),
            @truncate(block_len >> 8),
            @truncate(nlen),
            @truncate(nlen >> 8),
        };
        try writer.writeAll(&b_hdr);
        crc.update(&b_hdr);

        var block_rem: usize = block_len_usize;
        while (block_rem > 0) {
            if (cur_col == 0) {
                const zero = [_]u8{0x00};
                try writer.writeAll(&zero);
                crc.update(&zero);
                adlerUpdate(&adler_s1, &adler_s2, &zero);
                cur_col = 1;
                block_rem -= 1;
            } else {
                const row_off = cur_col - 1;
                const row_rem = row_bytes - row_off;
                const take = @min(block_rem, row_rem);
                const src_start = cur_row * row_bytes + row_off;
                const chunk = rgba[src_start .. src_start + take];
                try writer.writeAll(chunk);
                crc.update(chunk);
                adlerUpdate(&adler_s1, &adler_s2, chunk);
                cur_col += take;
                block_rem -= take;
                if (cur_col == raw_row_len) {
                    cur_col = 0;
                    cur_row += 1;
                }
            }
        }
        remaining -= block_len_usize;
    }

    const adler32: u32 = (adler_s2 << 16) | adler_s1;
    var adler_be: [4]u8 = undefined;
    std.mem.writeInt(u32, &adler_be, adler32, .big);
    try writer.writeAll(&adler_be);
    crc.update(&adler_be);

    var crc_be: [4]u8 = undefined;
    std.mem.writeInt(u32, &crc_be, crc.final(), .big);
    try writer.writeAll(&crc_be);

    // IEND
    try writePngChunk(writer, "IEND", &.{});
}

fn adlerUpdate(s1: *u32, s2: *u32, data: []const u8) void {
    const mod: u32 = 65521;
    var i: usize = 0;
    while (i < data.len) {
        const end = @min(data.len, i + 5552);
        var a = s1.*;
        var b = s2.*;
        for (data[i..end]) |byte| {
            a += byte;
            b += a;
        }
        s1.* = a % mod;
        s2.* = b % mod;
        i = end;
    }
}

fn writePngChunk(writer: anytype, chunk_type: *const [4]u8, data: []const u8) !void {
    var len_be: [4]u8 = undefined;
    std.mem.writeInt(u32, &len_be, @intCast(data.len), .big);
    try writer.writeAll(&len_be);
    try writer.writeAll(chunk_type);
    if (data.len > 0) {
        try writer.writeAll(data);
    }
    var crc = std.hash.Crc32.init();
    crc.update(chunk_type);
    if (data.len > 0) {
        crc.update(data);
    }
    var crc_be: [4]u8 = undefined;
    std.mem.writeInt(u32, &crc_be, crc.final(), .big);
    try writer.writeAll(&crc_be);
}

fn isPositiveFinite(v: f32) bool {
    return std.math.isFinite(v) and v > 0.0;
}

fn finiteOrZero32(v: f32) f32 {
    return if (std.math.isFinite(v)) v else 0.0;
}

fn allFinite4(v: [4]f32) bool {
    return std.math.isFinite(v[0]) and std.math.isFinite(v[1]) and
        std.math.isFinite(v[2]) and std.math.isFinite(v[3]);
}

fn clampColor(c: core.Color) core.Color {
    return .{
        if (std.math.isFinite(c[0])) std.math.clamp(c[0], 0.0, 1.0) else 0.0,
        if (std.math.isFinite(c[1])) std.math.clamp(c[1], 0.0, 1.0) else 0.0,
        if (std.math.isFinite(c[2])) std.math.clamp(c[2], 0.0, 1.0) else 0.0,
        if (std.math.isFinite(c[3])) std.math.clamp(c[3], 0.0, 1.0) else 0.0,
    };
}

fn compositeOver(fg: core.Color, bg: core.Color) core.Color {
    return core.blendOverLinear(fg, bg);
}

fn resolveEffectiveBg(node_idx: u16, parents: []const ?u16, fills: []const core.Color) core.Color {
    var chain: [64]u16 = undefined;
    var chain_len: usize = 0;
    var base_bg = core.Nord.polar_night_0;

    var cur_opt: ?u16 = node_idx;
    while (cur_opt) |cur| {
        const c = clampColor(fills[cur]);
        if (c[3] >= 0.999) {
            base_bg = c;
            break;
        }
        if (chain_len < chain.len) {
            chain[chain_len] = cur;
            chain_len += 1;
        } else {
            break;
        }
        cur_opt = parents[cur];
    }

    var j = chain_len;
    while (j > 0) {
        j -= 1;
        base_bg = compositeOver(clampColor(fills[chain[j]]), base_bg);
    }
    return base_bg;
}

fn inAncestorClips(
    idx: u16,
    cx: f32,
    cy: f32,
    parents: []const ?u16,
    rects: []const core.Rect,
    scroll_props: []const core.ScrollProps,
    max_nodes: usize,
) bool {
    var anc_opt = parents[idx];
    var steps: usize = 0;
    while (anc_opt) |anc_idx| : (steps += 1) {
        if (steps >= max_nodes) break;
        if (scroll_props[anc_idx].clip_children) {
            const ar = rects[anc_idx];
            if (!(ar.w > 0.0 and ar.h > 0.0 and
                cx >= ar.x and cx <= ar.x + ar.w and
                cy >= ar.y and cy <= ar.y + ar.h))
            {
                return false;
            }
        }
        anc_opt = parents[anc_idx];
    }
    return true;
}

fn hitResolvesToTarget(arena: *const core.LayoutArena, hit_id: core.NodeId, target_id: core.NodeId) bool {
    var cur_opt: ?core.NodeId = hit_id;
    while (cur_opt) |cur| {
        if (cur.index == target_id.index and cur.gen == target_id.gen) return true;
        const kind = arena.getKind(cur) orelse return false;
        switch (kind) {
            .bar, .vstack, .hstack, .zstack, .grid => cur_opt = arena.getParent(cur),
            .slider, .toggle, .card => return false,
        }
    }
    return false;
}

fn pushDiagnostic(out_buf: []Diagnostic, count: *usize, diag: Diagnostic) void {
    if (count.* < out_buf.len) {
        out_buf[count.*] = diag;
        count.* += 1;
    }
}

fn writeJsonString(writer: anytype, s: []const u8) !void {
    try writer.writeByte('"');
    for (s) |c| {
        switch (c) {
            '"' => try writer.writeAll("\\\""),
            '\\' => try writer.writeAll("\\\\"),
            '\n' => try writer.writeAll("\\n"),
            '\r' => try writer.writeAll("\\r"),
            '\t' => try writer.writeAll("\\t"),
            0x08 => try writer.writeAll("\\b"),
            0x0c => try writer.writeAll("\\f"),
            else => {
                if (c < 0x20) {
                    try writer.print("\\u{x:0>4}", .{c});
                } else {
                    try writer.writeByte(c);
                }
            },
        }
    }
    try writer.writeByte('"');
}

fn floatToU8(v: f32) u8 {
    if (!std.math.isFinite(v)) return 0;
    const clamped = std.math.clamp(v, 0.0, 1.0);
    return @intFromFloat(@round(clamped * 255.0));
}

fn setPixelRgba(buf: []u8, phys_w: usize, px: usize, py: usize, r: u8, g: u8, b: u8, a: u8) void {
    const off = (py * phys_w + px) * 4;
    buf[off + 0] = r;
    buf[off + 1] = g;
    buf[off + 2] = b;
    buf[off + 3] = a;
}

fn smoothstep(edge0: f32, edge1: f32, x: f32) f32 {
    if (edge1 <= edge0) return if (x >= edge1) 1.0 else 0.0;
    const t = std.math.clamp((x - edge0) / (edge1 - edge0), 0.0, 1.0);
    return t * t * (3.0 - 2.0 * t);
}

fn sdRoundedBox(px: f32, py: f32, bx: f32, by: f32, r: f32) f32 {
    const qx = @abs(px) - bx + r;
    const qy = @abs(py) - by + r;
    const ox = @max(qx, 0.0);
    const oy = @max(qy, 0.0);
    return @min(@max(qx, qy), 0.0) + @sqrt(ox * ox + oy * oy) - r;
}

fn mix4(a: [4]f32, b: [4]f32, t: f32) [4]f32 {
    return .{
        a[0] + (b[0] - a[0]) * t,
        a[1] + (b[1] - a[1]) * t,
        a[2] + (b[2] - a[2]) * t,
        a[3] + (b[3] - a[3]) * t,
    };
}

pub fn rasterizeQuad(buf: []u8, phys_w: usize, phys_h: usize, q: core.QuadInstance) void {
    if (!allFinite4(q.pos_size) or !allFinite4(q.params) or
        !allFinite4(q.color) or !allFinite4(q.border_color) or
        !allFinite4(q.clip_rect))
    {
        return;
    }
    // Skip glyph quads when no atlas is bound in headless rasterizer.
    if (q.params[3] > 0.5) return;
    if (q.pos_size[2] <= 0.0 or q.pos_size[3] <= 0.0) return;
    if (q.clip_rect[2] <= q.clip_rect[0] or q.clip_rect[3] <= q.clip_rect[1]) return;

    const col = clampColor(q.color);
    const bcol = clampColor(q.border_color);

    const half_w = @max(q.pos_size[2], 0.0) * 0.5;
    const half_h = @max(q.pos_size[3], 0.0) * 0.5;
    const cx = q.pos_size[0] + half_w;
    const cy = q.pos_size[1] + half_h;

    const blur = @max(q.params[2], 0.0);
    const pad = blur * 1.5 + 2.0;
    const radius = @min(@max(q.params[0], 0.0), @min(half_w, half_h));
    const bw = @max(q.params[1], 0.0);

    const min_x_f = @max(@floor(cx - half_w - pad), @floor(q.clip_rect[0]));
    const min_y_f = @max(@floor(cy - half_h - pad), @floor(q.clip_rect[1]));
    const max_x_f = @min(@ceil(cx + half_w + pad), @ceil(q.clip_rect[2]));
    const max_y_f = @min(@ceil(cy + half_h + pad), @ceil(q.clip_rect[3]));
    if (!std.math.isFinite(min_x_f) or !std.math.isFinite(min_y_f) or
        !std.math.isFinite(max_x_f) or !std.math.isFinite(max_y_f))
    {
        return;
    }

    const max_w_f: f32 = @floatFromInt(phys_w);
    const max_h_f: f32 = @floatFromInt(phys_h);
    if (max_x_f <= 0.0 or max_y_f <= 0.0 or min_x_f >= max_w_f or min_y_f >= max_h_f) return;

    const x0: usize = @intFromFloat(std.math.clamp(min_x_f, 0.0, max_w_f));
    const y0: usize = @intFromFloat(std.math.clamp(min_y_f, 0.0, max_h_f));
    const x1: usize = @intFromFloat(std.math.clamp(max_x_f, 0.0, max_w_f));
    const y1: usize = @intFromFloat(std.math.clamp(max_y_f, 0.0, max_h_f));
    if (x1 <= x0 or y1 <= y0) return;

    const col_lin = core.srgbToLinearColor(col);
    const bcol_lin = core.srgbToLinearColor(bcol);
    const fill_pm = [4]f32{
        col_lin[0] * col_lin[3],
        col_lin[1] * col_lin[3],
        col_lin[2] * col_lin[3],
        col_lin[3],
    };
    const border_pm = [4]f32{
        bcol_lin[0] * bcol_lin[3],
        bcol_lin[1] * bcol_lin[3],
        bcol_lin[2] * bcol_lin[3],
        bcol_lin[3],
    };
    const shadow_lin = core.srgbToLinearColor(.{ 0.03, 0.04, 0.06, 1.0 });

    for (y0..y1) |py| {
        const py_center = @as(f32, @floatFromInt(py)) + 0.5;
        if (py_center < q.clip_rect[1] or py_center > q.clip_rect[3]) continue;
        const local_y = py_center - cy;
        for (x0..x1) |px| {
            const px_center = @as(f32, @floatFromInt(px)) + 0.5;
            if (px_center < q.clip_rect[0] or px_center > q.clip_rect[2]) continue;
            const local_x = px_center - cx;

            const d = sdRoundedBox(local_x, local_y, half_w, half_h, radius);
            const body_cov = 1.0 - smoothstep(-0.5, 0.5, d);

            var body_pm = fill_pm;
            if (bw > 0.05) {
                const border_t = smoothstep(-bw - 0.5, -bw + 0.5, d);
                body_pm = mix4(fill_pm, border_pm, border_t);
            }
            const fg_pm = [4]f32{
                body_pm[0] * body_cov,
                body_pm[1] * body_cov,
                body_pm[2] * body_cov,
                body_pm[3] * body_cov,
            };

            var shadow_alpha: f32 = 0.0;
            if (blur > 0.5) {
                const d_shadow = sdRoundedBox(local_x, local_y - blur * 0.25, half_w, half_h, radius);
                shadow_alpha = (1.0 - smoothstep(-blur * 0.35, blur * 1.15, d_shadow)) * 0.32;
            }
            const shadow_pm = [4]f32{
                shadow_lin[0] * shadow_alpha,
                shadow_lin[1] * shadow_alpha,
                shadow_lin[2] * shadow_alpha,
                shadow_alpha,
            };

            const inv_fg = 1.0 - fg_pm[3];
            const out_pm = [4]f32{
                fg_pm[0] + shadow_pm[0] * inv_fg,
                fg_pm[1] + shadow_pm[1] * inv_fg,
                fg_pm[2] + shadow_pm[2] * inv_fg,
                fg_pm[3] + shadow_pm[3] * inv_fg,
            };

            const out_a = out_pm[3];
            if (out_a < 1e-4) continue;

            const out_srgb = core.linearToSrgbColor(.{
                out_pm[0] / out_a,
                out_pm[1] / out_a,
                out_pm[2] / out_a,
                out_a,
            });

            const off = (py * phys_w + px) * 4;
            const dst_srgb = core.Color{
                @as(f32, @floatFromInt(buf[off + 0])) / 255.0,
                @as(f32, @floatFromInt(buf[off + 1])) / 255.0,
                @as(f32, @floatFromInt(buf[off + 2])) / 255.0,
                @as(f32, @floatFromInt(buf[off + 3])) / 255.0,
            };
            const blended = core.blendOverLinear(out_srgb, dst_srgb);

            buf[off + 0] = floatToU8(blended[0]);
            buf[off + 1] = floatToU8(blended[1]);
            buf[off + 2] = floatToU8(blended[2]);
            buf[off + 3] = floatToU8(blended[3]);
        }
    }
}

fn drawOutlineRect(buf: []u8, phys_w: usize, phys_h: usize, pr: core.Rect, color: core.Color) void {
    if (!std.math.isFinite(pr.x) or !std.math.isFinite(pr.y) or
        !std.math.isFinite(pr.w) or !std.math.isFinite(pr.h))
    {
        return;
    }
    if (pr.w <= 0.0 or pr.h <= 0.0 or phys_w == 0 or phys_h == 0) return;

    const max_x_f: f32 = @floatFromInt(phys_w - 1);
    const max_y_f: f32 = @floatFromInt(phys_h - 1);

    const x0_f = @floor(pr.x);
    const y0_f = @floor(pr.y);
    const x1_f = @floor(pr.x + pr.w - 1.0);
    const y1_f = @floor(pr.y + pr.h - 1.0);

    if (!std.math.isFinite(x0_f) or !std.math.isFinite(y0_f) or
        !std.math.isFinite(x1_f) or !std.math.isFinite(y1_f))
    {
        return;
    }
    if (x1_f < x0_f or y1_f < y0_f) return;
    if (x1_f < 0.0 or y1_f < 0.0 or x0_f > max_x_f or y0_f > max_y_f) return;

    const cx0: usize = @intFromFloat(std.math.clamp(x0_f, 0.0, max_x_f));
    const cx1: usize = @intFromFloat(std.math.clamp(x1_f, 0.0, max_x_f));
    const cy0: usize = @intFromFloat(std.math.clamp(y0_f, 0.0, max_y_f));
    const cy1: usize = @intFromFloat(std.math.clamp(y1_f, 0.0, max_y_f));

    const r = floatToU8(color[0]);
    const g = floatToU8(color[1]);
    const b = floatToU8(color[2]);
    const a: u8 = 255;

    if (y0_f >= 0.0 and y0_f <= max_y_f) {
        for (cx0..cx1 + 1) |px| {
            setPixelRgba(buf, phys_w, px, cy0, r, g, b, a);
        }
    }
    if (y1_f >= 0.0 and y1_f <= max_y_f and cy1 != cy0) {
        for (cx0..cx1 + 1) |px| {
            setPixelRgba(buf, phys_w, px, cy1, r, g, b, a);
        }
    }
    if (x0_f >= 0.0 and x0_f <= max_x_f) {
        for (cy0..cy1 + 1) |py| {
            setPixelRgba(buf, phys_w, cx0, py, r, g, b, a);
        }
    }
    if (x1_f >= 0.0 and x1_f <= max_x_f and cx1 != cx0) {
        for (cy0..cy1 + 1) |py| {
            setPixelRgba(buf, phys_w, cx1, py, r, g, b, a);
        }
    }
}
