const std = @import("std");

pub const MAX_OUTPUTS: usize = 16;
pub const MAX_WINDOWS: usize = 64;
pub const DEFAULT_FRAME_INTERVAL_US: u32 = 16666;
pub const SCALE_EPSILON: f32 = 0.001;

pub const OutputState = struct {
    id: u32,
    name: [32]u8 = @splat(0),
    name_len: u8 = 0,
    logical_x: i32 = 0,
    logical_y: i32 = 0,
    logical_w: u32,
    logical_h: u32,
    scale_factor: f32 = 1.0,
    refresh_mhz: u32 = 60_000,
    connected: bool = true,
};

pub const WindowKind = enum {
    toplevel,
    layer_shell,
    popup,
};

pub const WindowEntry = struct {
    id: u32,
    kind: WindowKind,
    output_id: u32,
    logical_w: f32,
    logical_h: f32,
    scale_factor: f32,
    refresh_mhz: u32,
    needs_reraster: bool,
    dirty: bool,
    has_fractional_scale: bool = false,
    frame_budget_us: u32,
};

pub const PhysicalSize = struct {
    w: u32,
    h: u32,
};

pub const Error = error{
    InvalidOutput,
    InvalidScale,
    InvalidRefresh,
    DuplicateOutput,
    TooManyOutputs,
    OutputNotFound,
    InvalidWindowSize,
    TooManyWindows,
    WindowNotFound,
};

/// Quantizes a float scale factor into `scale_120` (clamped to [60, 1200],
/// with non-positive/NaN/Inf defaulting to 120) so 1.0x (120), 1.25x (150), 1.5x (180),
/// and 2.0x (240) coexist in GlyphAtlas without thrashing.
pub fn glyphScaleKey(scale_factor: f32) u16 {
    if (!std.math.isFinite(scale_factor) or scale_factor <= 0.0) return 120;
    const clamped_scale = std.math.clamp(scale_factor, 0.5, 10.0);
    const rounded = @round(clamped_scale * 120.0);
    const clamped_key = std.math.clamp(rounded, 60.0, 1200.0);
    return @intFromFloat(clamped_key);
}

fn scaleChanged(old: f32, new: f32) bool {
    return @abs(old - new) > SCALE_EPSILON or glyphScaleKey(old) != glyphScaleKey(new);
}

fn frameBudgetUs(refresh_mhz: u32) u32 {
    if (refresh_mhz == 0) return DEFAULT_FRAME_INTERVAL_US;
    return @max(@as(u32, 1), 1_000_000_000 / refresh_mhz);
}

fn validateOutput(out: OutputState) Error!void {
    if (out.id == 0 or !out.connected or out.logical_w == 0 or out.logical_h == 0) {
        return error.InvalidOutput;
    }
    if (!std.math.isFinite(out.scale_factor) or out.scale_factor < 0.5 or out.scale_factor > 10.0) {
        return error.InvalidScale;
    }
    if (out.refresh_mhz < 1_000 or out.refresh_mhz > 1_000_000) {
        return error.InvalidRefresh;
    }
}

fn sanitizeOutput(out: OutputState) OutputState {
    var sanitized = out;
    sanitized.name_len = @min(out.name_len, @as(u8, @intCast(out.name.len)));
    return sanitized;
}

fn scaleDimension(logical: f32, scale: f32) u32 {
    if (!std.math.isFinite(logical) or !std.math.isFinite(scale)) return 1;
    if (logical <= 0.0 or scale <= 0.0) return 1;
    const product: f64 = @as(f64, logical) * @as(f64, scale);
    if (!std.math.isFinite(product) or product <= 1.0) return 1;
    const rounded: f64 = @round(product);
    const max_u32_f64: f64 = @floatFromInt(std.math.maxInt(u32));
    if (rounded >= max_u32_f64) return std.math.maxInt(u32);
    return @max(@as(u32, 1), @as(u32, @intFromFloat(rounded)));
}

pub const MultiWindowManager = struct {
    outputs: [MAX_OUTPUTS]OutputState = undefined,
    output_count: usize = 0,
    windows: [MAX_WINDOWS]WindowEntry = undefined,
    window_count: usize = 0,
    next_window_id: u32 = 1,

    /// Initializes an empty MultiWindowManager.
    pub fn init() MultiWindowManager {
        return .{};
    }

    fn findOutputIndex(self: *const MultiWindowManager, output_id: u32) ?usize {
        if (output_id == 0) return null;
        for (self.outputs[0..self.output_count], 0..) |out, idx| {
            if (out.id == output_id) return idx;
        }
        return null;
    }

    fn findConnectedOutput(self: *const MultiWindowManager, output_id: u32) ?*const OutputState {
        const idx = self.findOutputIndex(output_id) orelse return null;
        if (!self.outputs[idx].connected) return null;
        return &self.outputs[idx];
    }

    fn firstConnectedOutput(self: *const MultiWindowManager) ?*const OutputState {
        for (self.outputs[0..self.output_count]) |*out| {
            if (out.connected) return out;
        }
        return null;
    }

    fn findWindowIndex(self: *const MultiWindowManager, window_id: u32) ?usize {
        if (window_id == 0) return null;
        for (self.windows[0..self.window_count], 0..) |win, idx| {
            if (win.id == window_id) return idx;
        }
        return null;
    }

    fn findWindowMut(self: *MultiWindowManager, window_id: u32) ?*WindowEntry {
        const idx = self.findWindowIndex(window_id) orelse return null;
        return &self.windows[idx];
    }

    fn allocateWindowId(self: *MultiWindowManager) u32 {
        var attempts: usize = 0;
        while (attempts <= MAX_WINDOWS) : (attempts += 1) {
            const candidate = self.next_window_id;
            self.next_window_id +%= 1;
            if (self.next_window_id == 0) self.next_window_id = 1;
            if (candidate != 0 and self.findWindowIndex(candidate) == null) {
                return candidate;
            }
        }
        unreachable;
    }

    fn attachWindowToOutput(win: *WindowEntry, out: OutputState, force_dirty: bool) bool {
        win.output_id = out.id;
        win.refresh_mhz = out.refresh_mhz;
        win.frame_budget_us = frameBudgetUs(out.refresh_mhz);
        win.has_fractional_scale = false;
        const old_scale = win.scale_factor;
        win.scale_factor = out.scale_factor;
        const changed = scaleChanged(old_scale, out.scale_factor);
        if (changed) win.needs_reraster = true;
        if (changed or force_dirty) win.dirty = true;
        return changed;
    }

    fn reattachOrphanedWindows(self: *MultiWindowManager, out: OutputState) void {
        for (self.windows[0..self.window_count]) |*win| {
            if (win.output_id == 0) {
                _ = attachWindowToOutput(win, out, true);
            }
        }
    }

    fn migrateWindowsFromOutput(self: *MultiWindowManager, output_id: u32) void {
        const fallback = self.firstConnectedOutput();
        for (self.windows[0..self.window_count]) |*win| {
            if (win.output_id != output_id) continue;
            if (fallback) |fb| {
                _ = attachWindowToOutput(win, fb.*, true);
            } else {
                win.output_id = 0;
                win.refresh_mhz = 60_000;
                win.frame_budget_us = DEFAULT_FRAME_INTERVAL_US;
                win.has_fractional_scale = false;
                win.dirty = true;
            }
        }
    }

    /// Registers a new output after validating its ID, connectivity, dimensions, scale factor, and refresh rate.
    pub fn addOutput(self: *MultiWindowManager, out: OutputState) Error!void {
        try validateOutput(out);
        const sanitized = sanitizeOutput(out);

        if (self.findOutputIndex(sanitized.id)) |idx| {
            if (self.outputs[idx].connected) return error.DuplicateOutput;
            self.outputs[idx] = sanitized;
        } else if (self.output_count >= MAX_OUTPUTS) {
            // Reclaim a disconnected slot if capacity is full of stale disconnected entries.
            const stale_idx = blk: {
                for (self.outputs[0..self.output_count], 0..) |existing, idx| {
                    if (!existing.connected) break :blk idx;
                }
                return error.TooManyOutputs;
            };
            var i = stale_idx;
            while (i + 1 < self.output_count) : (i += 1) {
                self.outputs[i] = self.outputs[i + 1];
            }
            self.outputs[self.output_count - 1] = sanitized;
        } else {
            self.outputs[self.output_count] = sanitized;
            self.output_count += 1;
        }

        self.reattachOrphanedWindows(sanitized);
    }

    /// Updates an existing output's properties and propagates scale/refresh changes to its windows.
    pub fn updateOutput(self: *MultiWindowManager, out: OutputState) Error!void {
        if (out.id == 0) return error.InvalidOutput;
        const idx = self.findOutputIndex(out.id) orelse return error.OutputNotFound;
        if (!out.connected) {
            self.outputs[idx].connected = false;
            self.migrateWindowsFromOutput(out.id);
            return;
        }

        try validateOutput(out);
        const sanitized = sanitizeOutput(out);
        self.outputs[idx] = sanitized;

        const budget = frameBudgetUs(sanitized.refresh_mhz);
        for (self.windows[0..self.window_count]) |*win| {
            if (win.output_id != sanitized.id) continue;
            win.refresh_mhz = sanitized.refresh_mhz;
            win.frame_budget_us = budget;
            if (!win.has_fractional_scale) {
                const old_scale = win.scale_factor;
                win.scale_factor = sanitized.scale_factor;
                if (scaleChanged(old_scale, sanitized.scale_factor)) {
                    win.needs_reraster = true;
                    win.dirty = true;
                }
            }
        }

        self.reattachOrphanedWindows(sanitized);
    }

    /// Removes an output and migrates its windows to the first remaining connected output.
    pub fn removeOutput(self: *MultiWindowManager, output_id: u32) void {
        const idx = self.findOutputIndex(output_id) orelse return;
        var i = idx;
        while (i + 1 < self.output_count) : (i += 1) {
            self.outputs[i] = self.outputs[i + 1];
        }
        self.output_count -= 1;
        self.migrateWindowsFromOutput(output_id);
    }

    /// Creates a window bound to a connected output and returns its unique non-zero ID.
    pub fn createWindow(
        self: *MultiWindowManager,
        kind: WindowKind,
        output_id: u32,
        logical_w: f32,
        logical_h: f32,
    ) Error!u32 {
        if (!std.math.isFinite(logical_w) or !std.math.isFinite(logical_h) or
            logical_w <= 0.0 or logical_h <= 0.0)
        {
            return error.InvalidWindowSize;
        }
        const out = self.findConnectedOutput(output_id) orelse return error.OutputNotFound;
        if (self.window_count >= MAX_WINDOWS) return error.TooManyWindows;

        const id = self.allocateWindowId();
        self.windows[self.window_count] = .{
            .id = id,
            .kind = kind,
            .output_id = out.id,
            .logical_w = logical_w,
            .logical_h = logical_h,
            .scale_factor = out.scale_factor,
            .refresh_mhz = out.refresh_mhz,
            .needs_reraster = true,
            .dirty = true,
            .frame_budget_us = frameBudgetUs(out.refresh_mhz),
        };
        self.window_count += 1;
        return id;
    }

    /// Destroys a window by ID, returning true if it existed.
    pub fn destroyWindow(self: *MultiWindowManager, id: u32) bool {
        const idx = self.findWindowIndex(id) orelse return false;
        var i = idx;
        while (i + 1 < self.window_count) : (i += 1) {
            self.windows[i] = self.windows[i + 1];
        }
        self.window_count -= 1;
        return true;
    }

    /// Returns a read-only pointer to a window entry, or null if not found.
    pub fn getWindow(self: *const MultiWindowManager, id: u32) ?*const WindowEntry {
        const idx = self.findWindowIndex(id) orelse return null;
        return &self.windows[idx];
    }

    /// Moves a window to another connected output and flags reraster/dirty if scale changed.
    pub fn moveWindowToOutput(self: *MultiWindowManager, window_id: u32, new_output_id: u32) Error!bool {
        const out = self.findConnectedOutput(new_output_id) orelse return error.OutputNotFound;
        const win = self.findWindowMut(window_id) orelse return error.WindowNotFound;
        const output_changed = win.output_id != out.id;
        return attachWindowToOutput(win, out.*, output_changed);
    }

    /// Updates a window's scale from a wp_fractional_scale_v1 120-based denominator value.
    pub fn setWindowFractionalScale(self: *MultiWindowManager, window_id: u32, scale_120: u32) Error!bool {
        if (scale_120 < 60 or scale_120 > 1200) return error.InvalidScale;
        const win = self.findWindowMut(window_id) orelse return error.WindowNotFound;

        const new_scale: f32 = @as(f32, @floatFromInt(scale_120)) / 120.0;
        const changed = scaleChanged(win.scale_factor, new_scale);
        win.scale_factor = new_scale;
        win.has_fractional_scale = true;
        if (changed) {
            win.needs_reraster = true;
            win.dirty = true;
        }
        return changed;
    }

    /// Computes physical pixel dimensions for a window with overflow and minimum-1px safety.
    pub fn physicalSize(self: *const MultiWindowManager, window_id: u32) ?PhysicalSize {
        const win = self.getWindow(window_id) orelse return null;
        return .{
            .w = scaleDimension(win.logical_w, win.scale_factor),
            .h = scaleDimension(win.logical_h, win.scale_factor),
        };
    }

    /// Returns the shortest frame interval in microseconds across all connected outputs.
    pub fn minFrameIntervalUs(self: *const MultiWindowManager) u32 {
        var max_refresh_mhz: u32 = 0;
        for (self.outputs[0..self.output_count]) |out| {
            if (out.connected and out.refresh_mhz > max_refresh_mhz) {
                max_refresh_mhz = out.refresh_mhz;
            }
        }
        return frameBudgetUs(max_refresh_mhz);
    }

    /// Returns true if any managed window is marked dirty.
    pub fn anyDirty(self: *const MultiWindowManager) bool {
        for (self.windows[0..self.window_count]) |win| {
            if (win.dirty) return true;
        }
        return false;
    }

    /// Clears the dirty and reraster flags for a window after rendering.
    pub fn clearDirty(self: *MultiWindowManager, window_id: u32) void {
        if (self.findWindowMut(window_id)) |win| {
            win.dirty = false;
            win.needs_reraster = false;
        }
    }
};

test "glyphScaleKey: quantizes standard scales and handles edge values" {
    try std.testing.expectEqual(@as(u16, 120), glyphScaleKey(1.0));
    try std.testing.expectEqual(@as(u16, 150), glyphScaleKey(1.25));
    try std.testing.expectEqual(@as(u16, 180), glyphScaleKey(1.5));
    try std.testing.expectEqual(@as(u16, 240), glyphScaleKey(2.0));
    try std.testing.expectEqual(@as(u16, 60), glyphScaleKey(0.1));
    try std.testing.expectEqual(@as(u16, 1200), glyphScaleKey(20.0));
    try std.testing.expectEqual(@as(u16, 120), glyphScaleKey(std.math.nan(f32)));
    try std.testing.expectEqual(@as(u16, 120), glyphScaleKey(std.math.inf(f32)));
    try std.testing.expectEqual(@as(u16, 120), glyphScaleKey(-std.math.inf(f32)));
}

test "MultiWindowManager: validates outputs, updates, and unplug to zero outputs" {
    var mgr = MultiWindowManager.init();

    try std.testing.expectError(error.InvalidOutput, mgr.addOutput(.{ .id = 0, .logical_w = 1920, .logical_h = 1080 }));
    try std.testing.expectError(error.InvalidScale, mgr.addOutput(.{ .id = 1, .logical_w = 1920, .logical_h = 1080, .scale_factor = std.math.nan(f32) }));
    try std.testing.expectError(error.InvalidScale, mgr.addOutput(.{ .id = 1, .logical_w = 1920, .logical_h = 1080, .scale_factor = 0.25 }));
    try std.testing.expectError(error.InvalidRefresh, mgr.addOutput(.{ .id = 1, .logical_w = 1920, .logical_h = 1080, .refresh_mhz = 500 }));

    try mgr.addOutput(.{ .id = 1, .logical_w = 1920, .logical_h = 1080, .scale_factor = 1.0, .refresh_mhz = 60_000 });
    try mgr.addOutput(.{ .id = 2, .logical_w = 1920, .logical_h = 1080, .scale_factor = 1.0, .refresh_mhz = 120_000 });

    const wid = try mgr.createWindow(.popup, 1, 200, 100);
    mgr.clearDirty(wid);

    // Moving to same scale returns false and does not set needs_reraster, but updates refresh/budget.
    const changed = try mgr.moveWindowToOutput(wid, 2);
    try std.testing.expect(!changed);
    const win_after_move = mgr.getWindow(wid).?;
    try std.testing.expectEqual(@as(u32, 120_000), win_after_move.refresh_mhz);
    try std.testing.expectEqual(@as(u32, 8333), win_after_move.frame_budget_us);
    try std.testing.expect(!win_after_move.needs_reraster);

    // Updating output 2 scale propagates to window.
    try mgr.updateOutput(.{ .id = 2, .logical_w = 1920, .logical_h = 1080, .scale_factor = 1.5, .refresh_mhz = 144_000 });
    const win_after_update = mgr.getWindow(wid).?;
    try std.testing.expectApproxEqAbs(@as(f32, 1.5), win_after_update.scale_factor, 0.001);
    try std.testing.expect(win_after_update.needs_reraster);
    try std.testing.expect(mgr.anyDirty());

    // Removing remaining outputs sets output_id = 0 and default interval.
    mgr.removeOutput(1);
    mgr.removeOutput(2);
    try std.testing.expectEqual(@as(u32, 0), mgr.getWindow(wid).?.output_id);
    try std.testing.expectEqual(@as(u32, 16666), mgr.minFrameIntervalUs());

    try std.testing.expect(mgr.destroyWindow(wid));
    try std.testing.expect(!mgr.destroyWindow(wid));
    try std.testing.expect(mgr.getWindow(wid) == null);
    try std.testing.expect(mgr.physicalSize(wid) == null);
}

test "MultiWindowManager: physicalSize handles extreme dimensions without overflow" {
    var mgr = MultiWindowManager.init();
    try mgr.addOutput(.{ .id = 1, .logical_w = 1920, .logical_h = 1080, .scale_factor = 2.0 });
    const wid = try mgr.createWindow(.toplevel, 1, 1e38, 0.01);
    const p = mgr.physicalSize(wid).?;
    try std.testing.expectEqual(std.math.maxInt(u32), p.w);
    try std.testing.expectEqual(@as(u32, 1), p.h);
}
