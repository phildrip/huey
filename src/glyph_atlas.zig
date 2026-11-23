const std = @import("std");
const core = @import("core.zig");

const StbttFontInfo = extern struct {
    storage: [512]u8 align(16) = undefined,
};

extern "c" fn huey_stbtt_get_font_offset_for_index(data: [*]const u8, index: c_int) c_int;
extern "c" fn huey_stbtt_init_font(info_buf: *StbttFontInfo, data: [*]const u8, offset: c_int) c_int;
extern "c" fn huey_stbtt_get_font_vmetrics(info_buf: *const StbttFontInfo, ascent: *c_int, descent: *c_int, line_gap: *c_int) void;
extern "c" fn huey_stbtt_scale_for_pixel_height(info_buf: *const StbttFontInfo, pixels: f32) f32;
extern "c" fn huey_stbtt_get_codepoint_hmetrics(info_buf: *const StbttFontInfo, codepoint: c_int, advance_width: *c_int, left_side_bearing: *c_int) void;
extern "c" fn huey_stbtt_get_codepoint_bitmap_box(info_buf: *const StbttFontInfo, codepoint: c_int, scale_x: f32, scale_y: f32, ix0: *c_int, iy0: *c_int, ix1: *c_int, iy1: *c_int) void;
extern "c" fn huey_stbtt_make_codepoint_bitmap(info_buf: *const StbttFontInfo, output: [*]u8, out_w: c_int, out_h: c_int, out_stride: c_int, scale_x: f32, scale_y: f32, codepoint: c_int) void;
extern "c" fn huey_stbtt_get_codepoint_kern_advance(info_buf: *const StbttFontInfo, ch1: c_int, ch2: c_int) c_int;

pub const GlyphKey = struct {
    codepoint: u21,
    size_px_q4: u16,
};

pub const GlyphMetrics = struct {
    w: f32,
    h: f32,
    x_off: f32,
    y_off: f32,
    advance: f32,
    u0: f32,
    v0: f32,
    u1: f32,
    v1: f32,
};

pub const TextMetrics = struct {
    width: f32,
    height: f32,
    ascent: f32,
    descent: f32,
};

const GlyphEntry = struct {
    metrics: GlyphMetrics,
    last_used_frame: u64,
};

const Shelf = struct {
    y: u32,
    height: u32,
    cursor_x: u32,
};

const EvictCandidate = struct {
    key: GlyphKey,
    last_used_frame: u64,
};

fn readU16BE(bytes: []const u8, off: usize) u16 {
    return std.mem.readInt(u16, bytes[off..][0..2], .big);
}

fn readU32BE(bytes: []const u8, off: usize) u32 {
    return std.mem.readInt(u32, bytes[off..][0..4], .big);
}

fn validateSfntHeader(bytes: []const u8, sfnt_off: usize) !void {
    if (sfnt_off > bytes.len or bytes.len - sfnt_off < 12) return error.InvalidFont;
    const tag = readU32BE(bytes, sfnt_off);
    const valid_tag = (tag == 0x00010000) or
        (tag == 0x4F54544F) or // "OTTO"
        (tag == 0x74727565) or // "true"
        (tag == 0x74797031); // "typ1"
    if (!valid_tag) return error.InvalidFont;

    const num_tables: usize = readU16BE(bytes, sfnt_off + 4);
    if (num_tables == 0) return error.InvalidFont;
    const dir_bytes = std.math.mul(usize, num_tables, 16) catch return error.InvalidFont;
    if (bytes.len - sfnt_off - 12 < dir_bytes) return error.InvalidFont;

    var i: usize = 0;
    while (i < num_tables) : (i += 1) {
        const rec = sfnt_off + 12 + i * 16;
        const t_off: usize = readU32BE(bytes, rec + 8);
        const t_len: usize = readU32BE(bytes, rec + 12);
        if (t_off > bytes.len or t_len > bytes.len - t_off) {
            return error.InvalidFont;
        }
    }
}

fn validateTtfBytes(bytes: []const u8) !void {
    if (bytes.len < 12) return error.InvalidFont;
    const tag = readU32BE(bytes, 0);
    if (tag == 0x74746366) { // "ttcf"
        if (bytes.len < 16) return error.InvalidFont;
        const num_fonts: usize = readU32BE(bytes, 8);
        if (num_fonts == 0) return error.InvalidFont;
        const table_bytes = std.math.mul(usize, num_fonts, 4) catch return error.InvalidFont;
        if (bytes.len - 12 < table_bytes) return error.InvalidFont;
        const first_off: usize = readU32BE(bytes, 12);
        try validateSfntHeader(bytes, first_off);
    } else {
        try validateSfntHeader(bytes, 0);
    }
}

fn nextUtf8Codepoint(bytes: []const u8, index: *usize) u21 {
    if (index.* >= bytes.len) return 0xFFFD;
    const b0 = bytes[index.*];
    const seq_len = std.unicode.utf8ByteSequenceLength(b0) catch {
        index.* += 1;
        return 0xFFFD;
    };
    if (index.* + seq_len > bytes.len) {
        index.* += 1;
        return 0xFFFD;
    }
    const cp = std.unicode.utf8Decode(bytes[index.* .. index.* + seq_len]) catch {
        index.* += 1;
        return 0xFFFD;
    };
    index.* += seq_len;
    return cp;
}

fn quantizeSizePx(font_size_logical: f32, scale: f32) struct { q4: u16, px: f32 } {
    const safe_font = if (std.math.isFinite(font_size_logical) and font_size_logical > 0.0) font_size_logical else 16.0;
    const safe_scale = if (std.math.isFinite(scale) and scale > 0.0) scale else 1.0;
    const raw_px = std.math.clamp(safe_font * safe_scale, 1.0, 256.0);
    const q4_f = std.math.clamp(@round(raw_px * 16.0), 16.0, 65535.0);
    const q4: u16 = @intFromFloat(q4_f);
    return .{
        .q4 = q4,
        .px = @as(f32, @floatFromInt(q4)) / 16.0,
    };
}

pub const GlyphAtlas = struct {
    allocator: std.mem.Allocator,
    font_bytes: []u8,
    font: StbttFontInfo,
    width: u32,
    height: u32,
    pixels: []u8,
    entries: std.AutoHashMap(GlyphKey, GlyphEntry),
    shelves: std.ArrayListUnmanaged(Shelf) = .empty,
    next_shelf_y: u32 = 1,
    scale_factor: f32 = 0.0,
    dirty: bool = false,
    eviction_count: usize = 0,
    repack_epoch: u64 = 0,

    pub fn init(allocator: std.mem.Allocator, font_bytes: []const u8, width: u32, height: u32) !GlyphAtlas {
        const max_c_int: usize = @intCast(std.math.maxInt(c_int));
        if (width == 0 or height == 0 or width > max_c_int or height > max_c_int) {
            return error.InvalidAtlasParams;
        }
        const total_bytes = std.math.mul(usize, @as(usize, width), @as(usize, height)) catch {
            return error.InvalidAtlasParams;
        };
        if (total_bytes > max_c_int) {
            return error.InvalidAtlasParams;
        }

        try validateTtfBytes(font_bytes);

        const owned_font = try allocator.dupe(u8, font_bytes);
        errdefer allocator.free(owned_font);

        const offset = huey_stbtt_get_font_offset_for_index(owned_font.ptr, 0);
        if (offset < 0 or @as(usize, @intCast(offset)) >= owned_font.len) {
            return error.InvalidFont;
        }
        var font_info: StbttFontInfo = .{};
        if (huey_stbtt_init_font(&font_info, owned_font.ptr, offset) == 0) {
            return error.InvalidFont;
        }

        var asc_i: c_int = 0;
        var desc_i: c_int = 0;
        var gap_i: c_int = 0;
        huey_stbtt_get_font_vmetrics(&font_info, &asc_i, &desc_i, &gap_i);
        if (asc_i - desc_i <= 0) {
            return error.InvalidFont;
        }

        const pixels = try allocator.alloc(u8, total_bytes);
        @memset(pixels, 0);

        return .{
            .allocator = allocator,
            .font_bytes = owned_font,
            .font = font_info,
            .width = width,
            .height = height,
            .pixels = pixels,
            .entries = std.AutoHashMap(GlyphKey, GlyphEntry).init(allocator),
        };
    }

    pub fn deinit(self: *GlyphAtlas) void {
        self.shelves.deinit(self.allocator);
        self.entries.deinit();
        self.allocator.free(self.pixels);
        self.allocator.free(self.font_bytes);
        self.* = undefined;
    }

    pub fn cachedCount(self: *const GlyphAtlas) usize {
        return self.entries.count();
    }

    pub fn markUploaded(self: *GlyphAtlas) void {
        self.dirty = false;
    }

    pub fn setScaleFactor(self: *GlyphAtlas, scale: f32) void {
        if (!std.math.isFinite(scale) or scale <= 0.0) return;
        if (@abs(scale - self.scale_factor) <= 1e-3) return;
        self.scale_factor = scale;
        self.entries.clearRetainingCapacity();
        self.shelves.clearRetainingCapacity();
        self.next_shelf_y = 1;
        @memset(self.pixels, 0);
        self.dirty = true;
        self.repack_epoch +%= 1;
    }

    fn packRect(self: *GlyphAtlas, w: u32, h: u32) ?struct { x: u32, y: u32 } {
        // Reserve 1px border on all edges so adjacent glyphs never bleed under bilinear filtering.
        if (self.width < 2 or self.height < 2) return null;
        if (w > self.width - 2 or h > self.height - 2) return null;

        for (self.shelves.items) |*shelf| {
            if (h <= shelf.height and shelf.cursor_x <= self.width - 1 - w) {
                const px = shelf.cursor_x;
                shelf.cursor_x += w + 1;
                return .{ .x = px, .y = shelf.y };
            }
        }

        if (self.next_shelf_y <= self.height - 1 - h) {
            const sy = self.next_shelf_y;
            self.shelves.append(self.allocator, .{
                .y = sy,
                .height = h,
                .cursor_x = 1 + w + 1,
            }) catch return null;
            self.next_shelf_y = sy + h + 1;
            return .{ .x = 1, .y = sy };
        }

        return null;
    }

    fn rasterizeIntoAtlas(
        self: *GlyphAtlas,
        cp: u21,
        size_px: f32,
        frame_idx: u64,
    ) !?GlyphEntry {
        const stb_scale = huey_stbtt_scale_for_pixel_height(&self.font, size_px);
        var adv_w: c_int = 0;
        var lsb: c_int = 0;
        huey_stbtt_get_codepoint_hmetrics(&self.font, @intCast(cp), &adv_w, &lsb);
        const advance = @as(f32, @floatFromInt(adv_w)) * stb_scale;

        var ix0: c_int = 0;
        var iy0: c_int = 0;
        var ix1: c_int = 0;
        var iy1: c_int = 0;
        huey_stbtt_get_codepoint_bitmap_box(&self.font, @intCast(cp), stb_scale, stb_scale, &ix0, &iy0, &ix1, &iy1);

        const bw_i = ix1 - ix0;
        const bh_i = iy1 - iy0;
        if (bw_i <= 0 or bh_i <= 0) {
            return .{
                .metrics = .{
                    .w = 0,
                    .h = 0,
                    .x_off = 0,
                    .y_off = 0,
                    .advance = advance,
                    .u0 = 0,
                    .v0 = 0,
                    .u1 = 0,
                    .v1 = 0,
                },
                .last_used_frame = frame_idx,
            };
        }

        const bw: u32 = @intCast(bw_i);
        const bh: u32 = @intCast(bh_i);
        if (self.width < 2 or self.height < 2 or bw > self.width - 2 or bh > self.height - 2) {
            return error.GlyphTooLarge;
        }

        const pos = self.packRect(bw, bh) orelse return null;

        const dst_offset = @as(usize, pos.y) * @as(usize, self.width) + @as(usize, pos.x);
        huey_stbtt_make_codepoint_bitmap(
            &self.font,
            self.pixels[dst_offset..].ptr,
            @intCast(bw),
            @intCast(bh),
            @intCast(self.width),
            stb_scale,
            stb_scale,
            @intCast(cp),
        );
        self.dirty = true;

        const inv_w = 1.0 / @as(f32, @floatFromInt(self.width));
        const inv_h = 1.0 / @as(f32, @floatFromInt(self.height));
        return .{
            .metrics = .{
                .w = @floatFromInt(bw),
                .h = @floatFromInt(bh),
                .x_off = @floatFromInt(ix0),
                .y_off = @floatFromInt(iy0),
                .advance = advance,
                .u0 = @as(f32, @floatFromInt(pos.x)) * inv_w,
                .v0 = @as(f32, @floatFromInt(pos.y)) * inv_h,
                .u1 = @as(f32, @floatFromInt(pos.x + bw)) * inv_w,
                .v1 = @as(f32, @floatFromInt(pos.y + bh)) * inv_h,
            },
            .last_used_frame = frame_idx,
        };
    }

    fn evictHalfAndRepack(self: *GlyphAtlas, protect_frame: u64, allow_evict_protected: bool) !void {
        const total = self.entries.count();
        if (total == 0) return error.AtlasFull;

        const candidates = try self.allocator.alloc(EvictCandidate, total);
        defer self.allocator.free(candidates);

        var protected_count: usize = 0;
        var i: usize = 0;
        var it = self.entries.iterator();
        while (it.next()) |kv| {
            if (kv.value_ptr.last_used_frame == protect_frame) {
                protected_count += 1;
            }
            candidates[i] = .{
                .key = kv.key_ptr.*,
                .last_used_frame = kv.value_ptr.last_used_frame,
            };
            i += 1;
        }

        // Preserve entries from protect_frame first, then newest frames descending.
        std.sort.block(EvictCandidate, candidates, protect_frame, struct {
            fn lessThan(pf: u64, a: EvictCandidate, b: EvictCandidate) bool {
                const a_prot = a.last_used_frame == pf;
                const b_prot = b.last_used_frame == pf;
                if (a_prot != b_prot) return a_prot;
                return a.last_used_frame > b.last_used_frame;
            }
        }.lessThan);

        const keep_count = if (total <= 1)
            0
        else if (!allow_evict_protected and protected_count < total)
            @max(total / 2, protected_count)
        else
            total / 2;

        const evicted = total - keep_count;

        self.entries.clearRetainingCapacity();
        self.shelves.clearRetainingCapacity();
        self.next_shelf_y = 1;
        @memset(self.pixels, 0);
        self.dirty = true;
        self.eviction_count += evicted;
        self.repack_epoch +%= 1;

        for (candidates[0..keep_count]) |cand| {
            const size_px = @as(f32, @floatFromInt(cand.key.size_px_q4)) / 16.0;
            if (try self.rasterizeIntoAtlas(cand.key.codepoint, size_px, cand.last_used_frame)) |entry| {
                try self.entries.put(cand.key, entry);
            } else {
                self.eviction_count += 1;
            }
        }
    }

    pub fn getOrRasterize(
        self: *GlyphAtlas,
        codepoint: u21,
        font_size_logical: f32,
        scale: f32,
        frame_idx: u64,
    ) !GlyphMetrics {
        const safe_scale = if (std.math.isFinite(scale) and scale > 0.0) scale else 1.0;
        if (self.scale_factor == 0.0) {
            self.scale_factor = safe_scale;
        }

        const q = quantizeSizePx(font_size_logical, safe_scale);
        const key = GlyphKey{
            .codepoint = codepoint,
            .size_px_q4 = q.q4,
        };

        if (self.entries.getPtr(key)) |existing| {
            existing.last_used_frame = frame_idx;
            return existing.metrics;
        }

        if (try self.rasterizeIntoAtlas(codepoint, q.px, frame_idx)) |entry| {
            try self.entries.put(key, entry);
            return entry.metrics;
        }

        // Atlas shelf packer is full; evict older entries first (protecting frame_idx), then retry.
        var allow_evict_protected = false;
        while (self.entries.count() > 0) {
            try self.evictHalfAndRepack(frame_idx, allow_evict_protected);
            if (try self.rasterizeIntoAtlas(codepoint, q.px, frame_idx)) |entry| {
                try self.entries.put(key, entry);
                return entry.metrics;
            }
            allow_evict_protected = true;
        }

        return error.GlyphTooLarge;
    }

    pub fn measureText(
        self: *const GlyphAtlas,
        text: []const u8,
        font_size_logical: f32,
        scale: f32,
    ) TextMetrics {
        const safe_scale = if (std.math.isFinite(scale) and scale > 0.0) scale else 1.0;
        const q = quantizeSizePx(font_size_logical, safe_scale);
        const stb_scale_px = huey_stbtt_scale_for_pixel_height(&self.font, q.px);
        const inv_scale = 1.0 / safe_scale;

        var asc_i: c_int = 0;
        var desc_i: c_int = 0;
        var gap_i: c_int = 0;
        huey_stbtt_get_font_vmetrics(&self.font, &asc_i, &desc_i, &gap_i);

        const ascent = @as(f32, @floatFromInt(asc_i)) * stb_scale_px * inv_scale;
        const descent = @as(f32, @floatFromInt(desc_i)) * stb_scale_px * inv_scale;
        const height = ascent - descent;

        var width_px: f32 = 0.0;
        var prev_cp: ?u21 = null;
        var idx: usize = 0;
        while (idx < text.len) {
            const cp = nextUtf8Codepoint(text, &idx);
            if (prev_cp) |p| {
                const kern = huey_stbtt_get_codepoint_kern_advance(&self.font, @intCast(p), @intCast(cp));
                width_px += @as(f32, @floatFromInt(kern)) * stb_scale_px;
            }
            var adv_w: c_int = 0;
            var lsb: c_int = 0;
            huey_stbtt_get_codepoint_hmetrics(&self.font, @intCast(cp), &adv_w, &lsb);
            width_px += @as(f32, @floatFromInt(adv_w)) * stb_scale_px;
            prev_cp = cp;
        }

        return .{
            .width = @max(0.0, width_px * inv_scale),
            .height = @max(0.0, height),
            .ascent = ascent,
            .descent = descent,
        };
    }

    const unbounded_clip: [4]f32 = .{ -1e9, -1e9, 1e9, 1e9 };

    pub fn emitTextQuads(
        self: *GlyphAtlas,
        text: []const u8,
        logical_x: f32,
        logical_y: f32,
        font_size_logical: f32,
        scale: f32,
        color: core.Color,
        out_buf: []core.QuadInstance,
        frame_idx: u64,
    ) usize {
        return self.emitTextQuadsClipped(
            text,
            logical_x,
            logical_y,
            font_size_logical,
            scale,
            color,
            unbounded_clip,
            out_buf,
            frame_idx,
        );
    }

    pub fn emitTextQuadsClipped(
        self: *GlyphAtlas,
        text: []const u8,
        logical_x: f32,
        logical_y: f32,
        font_size_logical: f32,
        scale: f32,
        color: core.Color,
        active_clip: [4]f32,
        out_buf: []core.QuadInstance,
        frame_idx: u64,
    ) usize {
        if (text.len == 0 or out_buf.len == 0) return 0;
        if (!std.math.isFinite(scale) or scale <= 0.0) return 0;
        if (!std.math.isFinite(logical_x) or !std.math.isFinite(logical_y)) return 0;
        if (!(active_clip[2] > active_clip[0] and active_clip[3] > active_clip[1])) return 0;

        const q = quantizeSizePx(font_size_logical, scale);
        const stb_scale_px = huey_stbtt_scale_for_pixel_height(&self.font, q.px);

        var asc_i: c_int = 0;
        var desc_i: c_int = 0;
        var gap_i: c_int = 0;
        huey_stbtt_get_font_vmetrics(&self.font, &asc_i, &desc_i, &gap_i);
        const ascent_px = @as(f32, @floatFromInt(asc_i)) * stb_scale_px;

        var pen_x_px = logical_x * scale;
        const baseline_px = @round(logical_y * scale + ascent_px);

        var emitted: usize = 0;
        var prev_cp: ?u21 = null;
        var idx: usize = 0;
        while (idx < text.len and emitted < out_buf.len) {
            const cp = nextUtf8Codepoint(text, &idx);
            if (prev_cp) |p| {
                const kern = huey_stbtt_get_codepoint_kern_advance(&self.font, @intCast(p), @intCast(cp));
                pen_x_px += @as(f32, @floatFromInt(kern)) * stb_scale_px;
            }

            var adv_w: c_int = 0;
            var lsb: c_int = 0;
            huey_stbtt_get_codepoint_hmetrics(&self.font, @intCast(cp), &adv_w, &lsb);
            const advance_px = @as(f32, @floatFromInt(adv_w)) * stb_scale_px;

            var ix0: c_int = 0;
            var iy0: c_int = 0;
            var ix1: c_int = 0;
            var iy1: c_int = 0;
            huey_stbtt_get_codepoint_bitmap_box(&self.font, @intCast(cp), stb_scale_px, stb_scale_px, &ix0, &iy0, &ix1, &iy1);
            const bw_i = ix1 - ix0;
            const bh_i = iy1 - iy0;
            if (bw_i <= 0 or bh_i <= 0) {
                pen_x_px += advance_px;
                prev_cp = cp;
                continue;
            }

            const gx_pre = @round(pen_x_px + @as(f32, @floatFromInt(ix0)));
            const gy_pre = @round(baseline_px + @as(f32, @floatFromInt(iy0)));
            const gw_pre: f32 = @floatFromInt(bw_i);
            const gh_pre: f32 = @floatFromInt(bh_i);
            if (!(gx_pre + gw_pre > active_clip[0] and gx_pre < active_clip[2] and
                gy_pre + gh_pre > active_clip[1] and gy_pre < active_clip[3]))
            {
                pen_x_px += advance_px;
                prev_cp = cp;
                continue;
            }

            const g = self.getOrRasterize(cp, font_size_logical, scale, frame_idx) catch {
                pen_x_px += advance_px;
                prev_cp = cp;
                continue;
            };

            if (g.w > 0.0 and g.h > 0.0) {
                const gx = @round(pen_x_px + g.x_off);
                const gy = @round(baseline_px + g.y_off);
                out_buf[emitted] = .{
                    .pos_size = .{ gx, gy, g.w, g.h },
                    .uv_rect = .{ g.u0, g.v0, g.u1, g.v1 },
                    .color = color,
                    .border_color = core.Nord.transparent,
                    .params = .{ 0.0, 0.0, 0.0, 1.0 },
                    .clip_rect = active_clip,
                };
                emitted += 1;
            }

            pen_x_px += g.advance;
            prev_cp = cp;
        }

        return emitted;
    }
};
