const std = @import("std");

/// Deterministic 64-bit widget identity derived from parent key and local ID or index.
/// Zero is reserved as the root/null sentinel and is never returned by key derivation.
pub const WidgetKey = u64;

fn wyhashWithParent(parent_key: WidgetKey, separator: u8, payload: []const u8) WidgetKey {
    var parent_bytes: [8]u8 = undefined;
    std.mem.writeInt(u64, &parent_bytes, parent_key, .little);

    var hasher = std.hash.Wyhash.init(0);
    hasher.update(&parent_bytes);
    hasher.update(&.{separator});
    hasher.update(payload);
    const h = hasher.final();
    return if (h == 0) 1 else h;
}

/// Derives a deterministic non-zero 64-bit Wyhash widget key from `parent_key`
/// (all 8 bytes + separator `0xFF`) and `local_id` bytes.
pub fn deriveKey(parent_key: WidgetKey, local_id: []const u8) WidgetKey {
    return wyhashWithParent(parent_key, 0xFF, local_id);
}

/// Derives a deterministic non-zero 64-bit Wyhash widget key for keyed list items by index.
pub fn deriveIndexKey(parent_key: WidgetKey, index: usize) WidgetKey {
    var index_bytes: [8]u8 = undefined;
    std.mem.writeInt(u64, &index_bytes, @as(u64, index), .little);
    return wyhashWithParent(parent_key, 0xFE, &index_bytes);
}

/// Retained per-widget interactive and scroll/animation state across frames.
pub const RetainedState = struct {
    scroll_x: f32 = 0.0,
    scroll_y: f32 = 0.0,
    anim_t: f32 = 0.0,
    cursor_pos: usize = 0,
    hovered: bool = false,
    pressed: bool = false,
    checked: bool = false,
    slider_val: f32 = 0.0,
};

const Entry = struct {
    state: RetainedState = .{},
    last_frame: u64 = 0,
};

/// Hybrid immediate/retained widget state store with end-of-frame mark-and-sweep GC.
/// Backed by `std.array_hash_map.Auto` (`AutoArrayHashMap`) for O(1) lookup,
/// contiguous value iteration, and zero-allocation swap-remove sweeping.
pub const WidgetStateStore = struct {
    allocator: std.mem.Allocator,
    map: std.array_hash_map.Auto(WidgetKey, Entry) = .empty,
    /// Internal monotonic frame epoch (always >= 1 once any frame has begun)
    /// so non-monotonic, repeated, or wrapping frame indices never break GC.
    epoch: u64 = 0,
    in_frame: bool = false,

    pub fn init(allocator: std.mem.Allocator) WidgetStateStore {
        return .{
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *WidgetStateStore) void {
        self.map.deinit(self.allocator);
        self.* = undefined;
    }

    /// Pre-allocates backing storage for at least `cap` widget entries so
    /// subsequent `touch()` calls up to `cap` perform zero heap allocations.
    /// Invalidates any previously returned `*RetainedState` pointers.
    pub fn ensureTotalCapacity(self: *WidgetStateStore, cap: usize) !void {
        try self.map.ensureTotalCapacity(self.allocator, cap);
    }

    /// Begins a new frame epoch. Caller-supplied `frame_idx` is accepted for API
    /// compatibility, while GC liveness uses the internal non-zero wrapping `epoch`.
    pub fn beginFrame(self: *WidgetStateStore, frame_idx: u64) void {
        _ = frame_idx;
        self.epoch +%= 1;
        if (self.epoch == 0) self.epoch = 1;
        self.in_frame = true;
    }

    /// Marks `key` alive for the current frame and returns a mutable pointer to its
    /// retained state, inserting default state on first visit.
    /// Performs zero heap allocations on cache hit.
    ///
    /// Returns `error.InvalidWidgetKey` if `key == 0` and `error.FrameNotActive` if
    /// called outside an active `beginFrame`..`endFrame` pair.
    ///
    /// Pointer invalidation: returned `*RetainedState` pointers are invalidated by
    /// any inserting `touch()`, `ensureTotalCapacity()`, `endFrame()`, or `clear()`.
    pub fn touch(self: *WidgetStateStore, key: WidgetKey) !*RetainedState {
        if (key == 0) return error.InvalidWidgetKey;
        if (!self.in_frame) return error.FrameNotActive;
        if (self.map.getPtr(key)) |existing| {
            existing.last_frame = self.epoch;
            return &existing.state;
        }
        const gop = try self.map.getOrPut(self.allocator, key);
        gop.value_ptr.* = .{ .last_frame = self.epoch };
        return &gop.value_ptr.state;
    }

    /// Returns a pointer to existing retained state without touching `last_frame`,
    /// or `null` if `key == 0` or not present.
    ///
    /// Pointer invalidation: returned `*RetainedState` pointers are invalidated by
    /// any inserting `touch()`, `ensureTotalCapacity()`, `endFrame()`, or `clear()`.
    pub fn get(self: *WidgetStateStore, key: WidgetKey) ?*RetainedState {
        if (key == 0) return null;
        const entry = self.map.getPtr(key) orelse return null;
        return &entry.state;
    }

    /// Returns the number of currently retained widget entries.
    pub fn count(self: *const WidgetStateStore) usize {
        return self.map.count();
    }

    /// Sweeps all entries not touched in the current frame via backward swap-remove,
    /// performing zero heap allocations. Returns the number of swept entries.
    /// No-ops and returns `0` if called when no frame is active.
    pub fn endFrame(self: *WidgetStateStore) usize {
        if (!self.in_frame) return 0;
        defer self.in_frame = false;

        var swept: usize = 0;
        var i: usize = self.map.count();
        while (i > 0) {
            i -= 1;
            if (self.map.values()[i].last_frame != self.epoch) {
                self.map.swapRemoveAt(i);
                swept += 1;
            }
        }
        return swept;
    }

    /// Clears all retained widget entries while keeping allocated capacity and `in_frame`
    /// unchanged so mid-frame `beginFrame -> clear -> endFrame` remains valid.
    pub fn clear(self: *WidgetStateStore) void {
        self.map.clearRetainingCapacity();
    }
};
