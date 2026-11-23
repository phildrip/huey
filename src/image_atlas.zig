const std = @import("std");

pub const MAX_ATLAS_BYTES: usize = 64 * 1024 * 1024;

pub const IconKey = struct {
    id_hash: u64,
    size_px: u16,
};

pub const BuiltinIcon = enum(u8) {
    lock,
    unlock,
    wifi,
    battery,
    volume,
    bluetooth,
    search,
    close,
    settings,
    check,
};

pub const Entry = struct {
    x: u32,
    y: u32,
    w: u32,
    h: u32,
    u0: f32,
    v0: f32,
    u1: f32,
    v1: f32,
    last_used_frame: u64,
    last_used_seq: u64 = 0,
};

const Shelf = struct {
    y: u32,
    height: u32,
    cursor_x: u32,
};

const EvictCandidate = struct {
    key: IconKey,
    entry: Entry,
    new_x: u32 = 0,
    new_y: u32 = 0,
    keep: bool = false,
};

fn fnv1a64(bytes: []const u8) u64 {
    var h: u64 = 0xcbf29ce484222325;
    for (bytes) |b| {
        h ^= b;
        h *%= 0x100000001b3;
    }
    return h;
}

pub fn builtinIconKey(icon: BuiltinIcon, size_px: u16) IconKey {
    var buf: [48]u8 = undefined;
    const prefix = "huey:builtin:";
    const name = @tagName(icon);
    @memcpy(buf[0..prefix.len], prefix);
    @memcpy(buf[prefix.len .. prefix.len + name.len], name);
    return .{
        .id_hash = fnv1a64(buf[0 .. prefix.len + name.len]),
        .size_px = size_px,
    };
}

fn makeEntry(
    atlas_w: u32,
    atlas_h: u32,
    x: u32,
    y: u32,
    w: u32,
    h: u32,
    frame_idx: u64,
    seq: u64,
) Entry {
    const inv_w = 1.0 / @as(f32, @floatFromInt(atlas_w));
    const inv_h = 1.0 / @as(f32, @floatFromInt(atlas_h));
    return .{
        .x = x,
        .y = y,
        .w = w,
        .h = h,
        .u0 = @as(f32, @floatFromInt(x)) * inv_w,
        .v0 = @as(f32, @floatFromInt(y)) * inv_h,
        .u1 = @as(f32, @floatFromInt(x + w)) * inv_w,
        .v1 = @as(f32, @floatFromInt(y + h)) * inv_h,
        .last_used_frame = frame_idx,
        .last_used_seq = seq,
    };
}

fn packRectInShelves(
    allocator: std.mem.Allocator,
    shelves: *std.ArrayListUnmanaged(Shelf),
    next_shelf_y: *u32,
    atlas_w: u32,
    atlas_h: u32,
    w: u32,
    h: u32,
) !?struct { x: u32, y: u32 } {
    if (atlas_w < 4 or atlas_h < 4) return null;
    if (w == 0 or h == 0) return null;
    if (w > atlas_w - 2 or h > atlas_h - 2) return null;

    for (shelves.items) |*shelf| {
        if (h <= shelf.height and shelf.cursor_x <= atlas_w - 1 - w) {
            const px = shelf.cursor_x;
            shelf.cursor_x += w + 1;
            return .{ .x = px, .y = shelf.y };
        }
    }

    if (next_shelf_y.* <= atlas_h - 1 - h) {
        const sy = next_shelf_y.*;
        try shelves.append(allocator, .{
            .y = sy,
            .height = h,
            .cursor_x = 1 + w + 1,
        });
        next_shelf_y.* = sy + h + 1;
        return .{ .x = 1, .y = sy };
    }

    return null;
}

fn blitRgba(
    dst: []u8,
    dst_stride_px: u32,
    dst_x: u32,
    dst_y: u32,
    w: u32,
    h: u32,
    src: []const u8,
) void {
    const row_bytes = @as(usize, w) * 4;
    const dst_stride_bytes = @as(usize, dst_stride_px) * 4;
    var row: u32 = 0;
    while (row < h) : (row += 1) {
        const src_off = @as(usize, row) * row_bytes;
        const dst_off = (@as(usize, dst_y + row) * dst_stride_bytes) + @as(usize, dst_x) * 4;
        @memcpy(dst[dst_off .. dst_off + row_bytes], src[src_off .. src_off + row_bytes]);
    }
}

fn clearRgbaRect(
    dst: []u8,
    dst_stride_px: u32,
    dst_x: u32,
    dst_y: u32,
    w: u32,
    h: u32,
) void {
    const row_bytes = @as(usize, w) * 4;
    const dst_stride_bytes = @as(usize, dst_stride_px) * 4;
    var row: u32 = 0;
    while (row < h) : (row += 1) {
        const dst_off = (@as(usize, dst_y + row) * dst_stride_bytes) + @as(usize, dst_x) * 4;
        @memset(dst[dst_off .. dst_off + row_bytes], 0);
    }
}

fn copyRgbaSubrect(
    src: []const u8,
    src_stride_px: u32,
    src_x: u32,
    src_y: u32,
    dst: []u8,
    dst_stride_px: u32,
    dst_x: u32,
    dst_y: u32,
    w: u32,
    h: u32,
) void {
    const row_bytes = @as(usize, w) * 4;
    const src_stride_bytes = @as(usize, src_stride_px) * 4;
    const dst_stride_bytes = @as(usize, dst_stride_px) * 4;
    var row: u32 = 0;
    while (row < h) : (row += 1) {
        const src_off = (@as(usize, src_y + row) * src_stride_bytes) + @as(usize, src_x) * 4;
        const dst_off = (@as(usize, dst_y + row) * dst_stride_bytes) + @as(usize, dst_x) * 4;
        @memcpy(dst[dst_off .. dst_off + row_bytes], src[src_off .. src_off + row_bytes]);
    }
}

pub const ImageAtlas = struct {
    allocator: std.mem.Allocator,
    width: u32,
    height: u32,
    pixels: []u8,
    entries: std.AutoHashMap(IconKey, Entry),
    shelves: std.ArrayListUnmanaged(Shelf) = .empty,
    next_shelf_y: u32 = 1,
    access_seq: u64 = 0,
    dirty: bool = false,
    eviction_count: usize = 0,
    repack_epoch: u64 = 0,

    pub fn init(allocator: std.mem.Allocator, width: u32, height: u32) !ImageAtlas {
        const max_c_int: usize = @intCast(std.math.maxInt(c_int));
        if (width < 4 or height < 4 or width > max_c_int or height > max_c_int) {
            return error.InvalidAtlasParams;
        }
        const px_count = std.math.mul(usize, @as(usize, width), @as(usize, height)) catch {
            return error.InvalidAtlasParams;
        };
        const total_bytes = std.math.mul(usize, px_count, 4) catch {
            return error.InvalidAtlasParams;
        };
        if (total_bytes > MAX_ATLAS_BYTES or total_bytes > max_c_int) {
            return error.InvalidAtlasParams;
        }

        const pixels = try allocator.alloc(u8, total_bytes);
        @memset(pixels, 0);

        return .{
            .allocator = allocator,
            .width = width,
            .height = height,
            .pixels = pixels,
            .entries = std.AutoHashMap(IconKey, Entry).init(allocator),
        };
    }

    pub fn deinit(self: *ImageAtlas) void {
        self.shelves.deinit(self.allocator);
        self.entries.deinit();
        self.allocator.free(self.pixels);
        self.* = undefined;
    }

    pub fn memoryBytes(self: *const ImageAtlas) usize {
        return self.pixels.len;
    }

    pub fn cachedCount(self: *const ImageAtlas) usize {
        return self.entries.count();
    }

    pub fn markUploaded(self: *ImageAtlas) void {
        self.dirty = false;
    }

    fn nextSeq(self: *ImageAtlas) u64 {
        self.access_seq +%= 1;
        return self.access_seq;
    }

    pub fn getUv(self: *ImageAtlas, key: IconKey, frame_idx: u64) ?[4]f32 {
        if (self.entries.getPtr(key)) |entry| {
            entry.last_used_frame = frame_idx;
            entry.last_used_seq = self.nextSeq();
            return .{ entry.u0, entry.v0, entry.u1, entry.v1 };
        }
        return null;
    }

    fn evictHalfAndRepack(
        self: *ImageAtlas,
        protect_frame: u64,
        allow_evict_protected: bool,
        skip_key: ?IconKey,
    ) !void {
        const raw_total = self.entries.count();
        if (raw_total == 0) return;

        const candidates = try self.allocator.alloc(EvictCandidate, raw_total);
        defer self.allocator.free(candidates);

        var protected_count: usize = 0;
        var idx: usize = 0;
        var it = self.entries.iterator();
        while (it.next()) |kv| {
            if (skip_key) |sk| {
                if (std.meta.eql(kv.key_ptr.*, sk)) continue;
            }
            if (kv.value_ptr.last_used_frame >= protect_frame) {
                protected_count += 1;
            }
            candidates[idx] = .{
                .key = kv.key_ptr.*,
                .entry = kv.value_ptr.*,
            };
            idx += 1;
        }

        const total = idx;
        if (total == 0) {
            try self.shelves.ensureUnusedCapacity(self.allocator, 1);
            self.entries.clearRetainingCapacity();
            self.shelves.clearRetainingCapacity();
            self.next_shelf_y = 1;
            @memset(self.pixels, 0);
            self.dirty = true;
            self.repack_epoch +%= 1;
            return;
        }

        const active = candidates[0..total];

        // Preserve entries from protect_frame (>=) first, then newest frames descending,
        // breaking intra-frame ties by monotonic access sequence.
        std.sort.block(EvictCandidate, active, protect_frame, struct {
            fn lessThan(pf: u64, a: EvictCandidate, b: EvictCandidate) bool {
                const a_prot = a.entry.last_used_frame >= pf;
                const b_prot = b.entry.last_used_frame >= pf;
                if (a_prot != b_prot) return a_prot;
                if (a.entry.last_used_frame != b.entry.last_used_frame) {
                    return a.entry.last_used_frame > b.entry.last_used_frame;
                }
                if (a.entry.last_used_seq != b.entry.last_used_seq) {
                    return a.entry.last_used_seq > b.entry.last_used_seq;
                }
                if (a.key.id_hash != b.key.id_hash) return a.key.id_hash < b.key.id_hash;
                return a.key.size_px < b.key.size_px;
            }
        }.lessThan);

        const keep_count = if (total <= 1)
            0
        else if (!allow_evict_protected and protected_count < total)
            @max(total / 2, protected_count)
        else
            total / 2;

        if (keep_count == 0) {
            try self.shelves.ensureUnusedCapacity(self.allocator, 1);
            self.entries.clearRetainingCapacity();
            self.shelves.clearRetainingCapacity();
            self.next_shelf_y = 1;
            @memset(self.pixels, 0);
            self.dirty = true;
            self.eviction_count += total;
            self.repack_epoch +%= 1;
            return;
        }

        // Pack kept entries tallest-first to minimize shelf fragmentation.
        std.sort.block(EvictCandidate, active[0..keep_count], {}, struct {
            fn lessThan(_: void, a: EvictCandidate, b: EvictCandidate) bool {
                if (a.entry.h != b.entry.h) return a.entry.h > b.entry.h;
                return a.entry.w > b.entry.w;
            }
        }.lessThan);

        var new_shelves: std.ArrayListUnmanaged(Shelf) = .empty;
        errdefer new_shelves.deinit(self.allocator);

        var new_entries = std.AutoHashMap(IconKey, Entry).init(self.allocator);
        errdefer new_entries.deinit();
        try new_entries.ensureTotalCapacity(@intCast(keep_count + 1));

        var new_next_shelf_y: u32 = 1;
        var kept_ok: usize = 0;
        var kept_bytes: usize = 0;

        for (active[0..keep_count]) |*cand| {
            if (try packRectInShelves(
                self.allocator,
                &new_shelves,
                &new_next_shelf_y,
                self.width,
                self.height,
                cand.entry.w,
                cand.entry.h,
            )) |pos| {
                cand.new_x = pos.x;
                cand.new_y = pos.y;
                cand.keep = true;
                kept_ok += 1;
                kept_bytes += @as(usize, cand.entry.w) * @as(usize, cand.entry.h) * 4;
                new_entries.putAssumeCapacity(cand.key, makeEntry(
                    self.width,
                    self.height,
                    pos.x,
                    pos.y,
                    cand.entry.w,
                    cand.entry.h,
                    cand.entry.last_used_frame,
                    cand.entry.last_used_seq,
                ));
            }
        }

        // Ensure room for at least one subsequent shelf before committing state swap.
        try new_shelves.ensureUnusedCapacity(self.allocator, 1);

        const staging = try self.allocator.alloc(u8, kept_bytes);
        defer self.allocator.free(staging);

        var stage_off: usize = 0;
        for (active[0..keep_count]) |cand| {
            if (!cand.keep) continue;
            copyRgbaSubrect(
                self.pixels,
                self.width,
                cand.entry.x,
                cand.entry.y,
                staging[stage_off..],
                cand.entry.w,
                0,
                0,
                cand.entry.w,
                cand.entry.h,
            );
            stage_off += @as(usize, cand.entry.w) * @as(usize, cand.entry.h) * 4;
        }

        // Commit infallibly
        @memset(self.pixels, 0);
        stage_off = 0;
        for (active[0..keep_count]) |cand| {
            if (!cand.keep) continue;
            const bytes = @as(usize, cand.entry.w) * @as(usize, cand.entry.h) * 4;
            blitRgba(
                self.pixels,
                self.width,
                cand.new_x,
                cand.new_y,
                cand.entry.w,
                cand.entry.h,
                staging[stage_off .. stage_off + bytes],
            );
            stage_off += bytes;
        }

        self.shelves.deinit(self.allocator);
        self.shelves = new_shelves;
        self.entries.deinit();
        self.entries = new_entries;
        self.next_shelf_y = new_next_shelf_y;
        self.dirty = true;
        self.eviction_count += total - kept_ok;
        self.repack_epoch +%= 1;
    }

    pub fn insertRgba(
        self: *ImageAtlas,
        key: IconKey,
        w: u32,
        h: u32,
        rgba: []const u8,
        frame_idx: u64,
    ) ![4]f32 {
        if (w == 0 or h == 0) return error.InvalidImageData;
        const px_count = std.math.mul(usize, @as(usize, w), @as(usize, h)) catch {
            return error.InvalidImageData;
        };
        const expected_len = std.math.mul(usize, px_count, 4) catch {
            return error.InvalidImageData;
        };
        if (rgba.len != expected_len) return error.InvalidImageData;

        // Check bounds with 1px transparent border BEFORE mutating or evicting cached icons.
        if (self.width < 4 or self.height < 4 or w > self.width - 2 or h > self.height - 2) {
            return error.ImageTooLarge;
        }

        if (self.entries.getPtr(key)) |existing| {
            if (existing.w == w and existing.h == h) {
                blitRgba(self.pixels, self.width, existing.x, existing.y, w, h, rgba);
                existing.last_used_frame = frame_idx;
                existing.last_used_seq = self.nextSeq();
                self.dirty = true;
                return .{ existing.u0, existing.v0, existing.u1, existing.v1 };
            }

            if (self.entries.count() == 1) {
                try self.shelves.ensureUnusedCapacity(self.allocator, 1);
                clearRgbaRect(self.pixels, self.width, existing.x, existing.y, existing.w, existing.h);
                self.shelves.clearRetainingCapacity();
                self.next_shelf_y = 1;
                const pos = (try packRectInShelves(self.allocator, &self.shelves, &self.next_shelf_y, self.width, self.height, w, h)).?;
                const seq = self.nextSeq();
                existing.* = makeEntry(self.width, self.height, pos.x, pos.y, w, h, frame_idx, seq);
                blitRgba(self.pixels, self.width, pos.x, pos.y, w, h, rgba);
                self.dirty = true;
                return .{ existing.u0, existing.v0, existing.u1, existing.v1 };
            }

            // Try packing alongside existing entry first; only clear old rect after packing succeeds.
            if (try packRectInShelves(self.allocator, &self.shelves, &self.next_shelf_y, self.width, self.height, w, h)) |pos| {
                clearRgbaRect(self.pixels, self.width, existing.x, existing.y, existing.w, existing.h);
                const seq = self.nextSeq();
                existing.* = makeEntry(self.width, self.height, pos.x, pos.y, w, h, frame_idx, seq);
                blitRgba(self.pixels, self.width, pos.x, pos.y, w, h, rgba);
                self.dirty = true;
                return .{ existing.u0, existing.v0, existing.u1, existing.v1 };
            }

            // Transactional eviction repack excluding `key` so OOM preserves `existing` intact.
            var allow_evict_protected = false;
            var skip_key: ?IconKey = key;
            while (self.entries.count() > (if (skip_key != null) @as(usize, 1) else @as(usize, 0))) {
                try self.evictHalfAndRepack(frame_idx, allow_evict_protected, skip_key);
                skip_key = null;
                if (try packRectInShelves(self.allocator, &self.shelves, &self.next_shelf_y, self.width, self.height, w, h)) |pos| {
                    try self.entries.ensureUnusedCapacity(1);
                    const seq = self.nextSeq();
                    const entry = makeEntry(self.width, self.height, pos.x, pos.y, w, h, frame_idx, seq);
                    self.entries.putAssumeCapacity(key, entry);
                    blitRgba(self.pixels, self.width, pos.x, pos.y, w, h, rgba);
                    self.dirty = true;
                    return .{ entry.u0, entry.v0, entry.u1, entry.v1 };
                }
                allow_evict_protected = true;
            }

            return error.ImageTooLarge;
        }

        try self.entries.ensureUnusedCapacity(1);

        if (try packRectInShelves(self.allocator, &self.shelves, &self.next_shelf_y, self.width, self.height, w, h)) |pos| {
            const seq = self.nextSeq();
            const entry = makeEntry(self.width, self.height, pos.x, pos.y, w, h, frame_idx, seq);
            self.entries.putAssumeCapacity(key, entry);
            blitRgba(self.pixels, self.width, pos.x, pos.y, w, h, rgba);
            self.dirty = true;
            return .{ entry.u0, entry.v0, entry.u1, entry.v1 };
        }

        var allow_evict_protected = false;
        while (self.entries.count() > 0) {
            try self.evictHalfAndRepack(frame_idx, allow_evict_protected, null);
            if (try packRectInShelves(self.allocator, &self.shelves, &self.next_shelf_y, self.width, self.height, w, h)) |pos| {
                try self.entries.ensureUnusedCapacity(1);
                const seq = self.nextSeq();
                const entry = makeEntry(self.width, self.height, pos.x, pos.y, w, h, frame_idx, seq);
                self.entries.putAssumeCapacity(key, entry);
                blitRgba(self.pixels, self.width, pos.x, pos.y, w, h, rgba);
                self.dirty = true;
                return .{ entry.u0, entry.v0, entry.u1, entry.v1 };
            }
            allow_evict_protected = true;
        }

        return error.ImageTooLarge;
    }

    pub fn getOrRasterizeIcon(
        self: *ImageAtlas,
        icon: BuiltinIcon,
        size_logical: u16,
        scale: f32,
        frame_idx: u64,
    ) ![4]f32 {
        if (size_logical == 0) {
            return error.InvalidImageData;
        }
        if (!std.math.isFinite(scale) or scale <= 0.0) {
            return error.InvalidScale;
        }
        const raw_px_f = @as(f32, @floatFromInt(size_logical)) * scale;
        const clamped_px_f = if (std.math.isFinite(raw_px_f))
            std.math.clamp(@round(raw_px_f), 8.0, 256.0)
        else
            256.0;
        const px: u16 = @intFromFloat(clamped_px_f);

        const key = builtinIconKey(icon, px);
        if (self.getUv(key, frame_idx)) |uv| {
            return uv;
        }

        const px_u32: u32 = px;
        if (self.width < 4 or self.height < 4 or px_u32 > self.width - 2 or px_u32 > self.height - 2) {
            return error.ImageTooLarge;
        }

        const buf = try self.allocator.alloc(u8, @as(usize, px_u32) * @as(usize, px_u32) * 4);
        defer self.allocator.free(buf);

        rasterizeBuiltinIconSdf(icon, px_u32, buf);
        return try self.insertRgba(key, px_u32, px_u32, buf, frame_idx);
    }
};

// --- SDF Vector Icon Rasterizer (monochrome white RGB, anti-aliased SDF coverage alpha) ---

const Vec2 = struct {
    x: f32,
    y: f32,

    fn sub(a: Vec2, b: Vec2) Vec2 {
        return .{ .x = a.x - b.x, .y = a.y - b.y };
    }

    fn dot(a: Vec2, b: Vec2) f32 {
        return a.x * b.x + a.y * b.y;
    }

    fn len(a: Vec2) f32 {
        return @sqrt(a.x * a.x + a.y * a.y);
    }
};

fn sdCircle(p: Vec2, center: Vec2, r: f32) f32 {
    return p.sub(center).len() - r;
}

fn sdRing(p: Vec2, center: Vec2, r: f32, half_thick: f32) f32 {
    return @abs(p.sub(center).len() - r) - half_thick;
}

fn sdRoundBox(p: Vec2, center: Vec2, half_ext: Vec2, r: f32) f32 {
    const qx = @abs(p.x - center.x) - (half_ext.x - r);
    const qy = @abs(p.y - center.y) - (half_ext.y - r);
    const ox = @max(qx, 0.0);
    const oy = @max(qy, 0.0);
    return @sqrt(ox * ox + oy * oy) + @min(@max(qx, qy), 0.0) - r;
}

fn sdSegment(p: Vec2, a: Vec2, b: Vec2, half_thick: f32) f32 {
    const pa = p.sub(a);
    const ba = b.sub(a);
    const denom = ba.dot(ba);
    const h = if (denom > 1e-8) std.math.clamp(pa.dot(ba) / denom, 0.0, 1.0) else 0.0;
    const dx = pa.x - ba.x * h;
    const dy = pa.y - ba.y * h;
    return @sqrt(dx * dx + dy * dy) - half_thick;
}

fn sdArcOriented(p: Vec2, center: Vec2, dir_x: f32, dir_y: f32, r: f32, half_aperture_rad: f32, half_thick: f32) f32 {
    const rel = p.sub(center);
    // Rotate rel into frame where (dir_x, dir_y) aligns with +X
    const lx = rel.x * dir_x + rel.y * dir_y;
    const ly = @abs(-rel.x * dir_y + rel.y * dir_x);
    const sin_a = @sin(half_aperture_rad);
    const cos_a = @cos(half_aperture_rad);
    if (sin_a * lx > cos_a * ly) {
        return @abs(rel.len() - r) - half_thick;
    }
    const ex = r * cos_a;
    const ey = r * sin_a;
    const dx = lx - ex;
    const dy = ly - ey;
    return @sqrt(dx * dx + dy * dy) - half_thick;
}

fn sdTriangle(p: Vec2, a: Vec2, b: Vec2, c: Vec2) f32 {
    const e0 = b.sub(a);
    const e1 = c.sub(b);
    const e2 = a.sub(c);
    const v0 = p.sub(a);
    const v1 = p.sub(b);
    const v2 = p.sub(c);

    const d_e0 = e0.dot(e0);
    const d_e1 = e1.dot(e1);
    const d_e2 = e2.dot(e2);
    const t0 = if (d_e0 > 1e-8) std.math.clamp(v0.dot(e0) / d_e0, 0.0, 1.0) else 0.0;
    const t1 = if (d_e1 > 1e-8) std.math.clamp(v1.dot(e1) / d_e1, 0.0, 1.0) else 0.0;
    const t2 = if (d_e2 > 1e-8) std.math.clamp(v2.dot(e2) / d_e2, 0.0, 1.0) else 0.0;

    const pq0 = Vec2{ .x = v0.x - e0.x * t0, .y = v0.y - e0.y * t0 };
    const pq1 = Vec2{ .x = v1.x - e1.x * t1, .y = v1.y - e1.y * t1 };
    const pq2 = Vec2{ .x = v2.x - e2.x * t2, .y = v2.y - e2.y * t2 };

    const s = std.math.sign(e0.x * e2.y - e0.y * e2.x);
    const d0 = pq0.dot(pq0);
    const d1 = pq1.dot(pq1);
    const d2 = pq2.dot(pq2);

    const c0 = s * (v0.x * e0.y - v0.y * e0.x);
    const c1 = s * (v1.x * e1.y - v1.y * e1.x);
    const c2 = s * (v2.x * e2.y - v2.y * e2.x);

    const min_d = @min(d0, @min(d1, d2));
    const min_c = @min(c0, @min(c1, c2));
    return if (min_c > 0.0) -@sqrt(min_d) else @sqrt(min_d);
}

fn evalBuiltinIconSdf(icon: BuiltinIcon, p: Vec2) f32 {
    return switch (icon) {
        .lock => blk: {
            const body = sdRoundBox(p, .{ .x = 0.0, .y = 0.25 }, .{ .x = 0.50, .y = 0.40 }, 0.09);
            const keyhole_top = sdCircle(p, .{ .x = 0.0, .y = 0.20 }, 0.085);
            const keyhole_slot = sdSegment(p, .{ .x = 0.0, .y = 0.20 }, .{ .x = 0.0, .y = 0.41 }, 0.045);
            const keyhole = @min(keyhole_top, keyhole_slot);
            const body_cut = @max(body, -keyhole);

            const arch = sdArcOriented(p, .{ .x = 0.0, .y = -0.22 }, 0.0, -1.0, 0.28, std.math.pi * 0.5, 0.085);
            const leg_l = sdSegment(p, .{ .x = -0.28, .y = -0.22 }, .{ .x = -0.28, .y = -0.05 }, 0.085);
            const leg_r = sdSegment(p, .{ .x = 0.28, .y = -0.22 }, .{ .x = 0.28, .y = -0.05 }, 0.085);
            break :blk @min(body_cut, @min(arch, @min(leg_l, leg_r)));
        },
        .unlock => blk: {
            const body = sdRoundBox(p, .{ .x = 0.0, .y = 0.27 }, .{ .x = 0.50, .y = 0.39 }, 0.09);
            const keyhole_top = sdCircle(p, .{ .x = 0.0, .y = 0.22 }, 0.085);
            const keyhole_slot = sdSegment(p, .{ .x = 0.0, .y = 0.22 }, .{ .x = 0.0, .y = 0.42 }, 0.045);
            const keyhole = @min(keyhole_top, keyhole_slot);
            const body_cut = @max(body, -keyhole);

            // Shackle open on the right side (lifted above body)
            const arch = sdArcOriented(p, .{ .x = 0.0, .y = -0.27 }, 0.0, -1.0, 0.28, std.math.pi * 0.5, 0.085);
            const leg_l = sdSegment(p, .{ .x = -0.28, .y = -0.27 }, .{ .x = -0.28, .y = -0.05 }, 0.085);
            break :blk @min(body_cut, @min(arch, leg_l));
        },
        .wifi => blk: {
            const origin = Vec2{ .x = 0.0, .y = 0.55 };
            const dot = sdCircle(p, origin, 0.11);
            const a1 = sdArcOriented(p, origin, 0.0, -1.0, 0.42, std.math.pi * 0.26, 0.075);
            const a2 = sdArcOriented(p, origin, 0.0, -1.0, 0.72, std.math.pi * 0.26, 0.075);
            const a3 = sdArcOriented(p, origin, 0.0, -1.0, 1.02, std.math.pi * 0.26, 0.075);
            break :blk @min(dot, @min(a1, @min(a2, a3)));
        },
        .battery => blk: {
            const outer = sdRoundBox(p, .{ .x = -0.06, .y = 0.0 }, .{ .x = 0.64, .y = 0.40 }, 0.09);
            const inner = sdRoundBox(p, .{ .x = -0.06, .y = 0.0 }, .{ .x = 0.52, .y = 0.28 }, 0.04);
            const shell = @max(outer, -inner);
            const fill = sdRoundBox(p, .{ .x = -0.18, .y = 0.0 }, .{ .x = 0.34, .y = 0.18 }, 0.03);
            const nub = sdRoundBox(p, .{ .x = 0.66, .y = 0.0 }, .{ .x = 0.10, .y = 0.16 }, 0.04);
            break :blk @min(shell, @min(fill, nub));
        },
        .volume => blk: {
            const base = sdRoundBox(p, .{ .x = -0.52, .y = 0.0 }, .{ .x = 0.16, .y = 0.20 }, 0.04);
            const cone = sdTriangle(
                p,
                .{ .x = -0.52, .y = 0.0 },
                .{ .x = -0.10, .y = -0.46 },
                .{ .x = -0.10, .y = 0.46 },
            );
            const wave1 = sdArcOriented(p, .{ .x = -0.04, .y = 0.0 }, 1.0, 0.0, 0.34, std.math.pi * 0.28, 0.07);
            const wave2 = sdArcOriented(p, .{ .x = -0.04, .y = 0.0 }, 1.0, 0.0, 0.62, std.math.pi * 0.28, 0.07);
            break :blk @min(@min(base, cone), @min(wave1, wave2));
        },
        .bluetooth => blk: {
            const spine = sdSegment(p, .{ .x = 0.0, .y = -0.68 }, .{ .x = 0.0, .y = 0.68 }, 0.075);
            const top_out = sdSegment(p, .{ .x = 0.0, .y = -0.68 }, .{ .x = 0.40, .y = -0.30 }, 0.075);
            const top_in = sdSegment(p, .{ .x = 0.40, .y = -0.30 }, .{ .x = -0.36, .y = 0.32 }, 0.075);
            const bot_out = sdSegment(p, .{ .x = 0.0, .y = 0.68 }, .{ .x = 0.40, .y = 0.30 }, 0.075);
            const bot_in = sdSegment(p, .{ .x = 0.40, .y = 0.30 }, .{ .x = -0.36, .y = -0.32 }, 0.075);
            break :blk @min(spine, @min(@min(top_out, top_in), @min(bot_out, bot_in)));
        },
        .search => blk: {
            const lens = sdRing(p, .{ .x = -0.14, .y = -0.14 }, 0.42, 0.085);
            const handle = sdSegment(p, .{ .x = 0.16, .y = 0.16 }, .{ .x = 0.64, .y = 0.64 }, 0.095);
            break :blk @min(lens, handle);
        },
        .close => blk: {
            const s1 = sdSegment(p, .{ .x = -0.50, .y = -0.50 }, .{ .x = 0.50, .y = 0.50 }, 0.095);
            const s2 = sdSegment(p, .{ .x = -0.50, .y = 0.50 }, .{ .x = 0.50, .y = -0.50 }, 0.095);
            break :blk @min(s1, s2);
        },
        .settings => blk: {
            const ring = sdRing(p, .{ .x = 0.0, .y = 0.0 }, 0.38, 0.14);
            var d = ring;
            var k: usize = 0;
            while (k < 8) : (k += 1) {
                const ang = @as(f32, @floatFromInt(k)) * (std.math.pi * 0.25);
                const ca = @cos(ang);
                const sa = @sin(ang);
                const tooth = sdSegment(
                    p,
                    .{ .x = ca * 0.44, .y = sa * 0.44 },
                    .{ .x = ca * 0.68, .y = sa * 0.68 },
                    0.10,
                );
                d = @min(d, tooth);
            }
            break :blk d;
        },
        .check => blk: {
            const s1 = sdSegment(p, .{ .x = -0.54, .y = 0.06 }, .{ .x = -0.14, .y = 0.46 }, 0.105);
            const s2 = sdSegment(p, .{ .x = -0.14, .y = 0.46 }, .{ .x = 0.56, .y = -0.42 }, 0.105);
            break :blk @min(s1, s2);
        },
    };
}

fn rasterizeBuiltinIconSdf(icon: BuiltinIcon, px: u32, out_rgba: []u8) void {
    const f_px = @as(f32, @floatFromInt(px));
    const px_unit = 2.0 / f_px;
    const aa = px_unit * 0.75;

    var y: u32 = 0;
    while (y < px) : (y += 1) {
        const ny = ((@as(f32, @floatFromInt(y)) + 0.5) / f_px) * 2.0 - 1.0;
        var x: u32 = 0;
        while (x < px) : (x += 1) {
            const nx = ((@as(f32, @floatFromInt(x)) + 0.5) / f_px) * 2.0 - 1.0;
            const d = evalBuiltinIconSdf(icon, .{ .x = nx, .y = ny });
            const cov = std.math.clamp(0.5 - d / (2.0 * aa), 0.0, 1.0);
            const alpha: u8 = @intFromFloat(@round(cov * 255.0));

            const off = (@as(usize, y) * @as(usize, px) + @as(usize, x)) * 4;
            out_rgba[off + 0] = 255;
            out_rgba[off + 1] = 255;
            out_rgba[off + 2] = 255;
            out_rgba[off + 3] = alpha;
        }
    }
}
