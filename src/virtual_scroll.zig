const std = @import("std");

pub const VisibleRange = struct {
    first_idx: usize,
    end_idx: usize,
    first_y_offset: f64,
};

/// Flat bottom-up binary segment tree storing row heights in f64 internal nodes
/// for O(log N) prefix sums, O(log N) height updates with zero floating-point
/// cancellation drift, and O(log N) Y-to-row lookup over 1,000,000+ rows.
pub const SumTree = struct {
    allocator: std.mem.Allocator,
    count: usize,
    size: usize,
    heights: []f32,
    tree: []f64,
    total: f64,

    fn sanitizeHeight(h: f32) f32 {
        if (!std.math.isFinite(h) or h <= 0.0) return 0.0;
        return h;
    }

    fn nextPow2(n: usize) usize {
        if (n == 0) return 0;
        if (n == 1) return 1;
        const shift: u6 = @intCast(@bitSizeOf(usize) - @clz(n - 1));
        return @as(usize, 1) << shift;
    }

    pub fn initUniform(allocator: std.mem.Allocator, count: usize, row_height: f32) !SumTree {
        if (count == 0) {
            return .{
                .allocator = allocator,
                .count = 0,
                .size = 0,
                .heights = &.{},
                .tree = &.{},
                .total = 0.0,
            };
        }

        const h = sanitizeHeight(row_height);
        const size = nextPow2(count);

        const heights = try allocator.alloc(f32, count);
        errdefer allocator.free(heights);

        const tree = try allocator.alloc(f64, 2 * size);
        errdefer allocator.free(tree);

        @memset(heights, h);
        @memset(tree[0..size], 0.0);
        @memset(tree[size .. size + count], @as(f64, h));
        @memset(tree[size + count .. 2 * size], 0.0);

        var p: usize = size - 1;
        while (p >= 1) : (p -= 1) {
            tree[p] = tree[2 * p] + tree[2 * p + 1];
        }

        return .{
            .allocator = allocator,
            .count = count,
            .size = size,
            .heights = heights,
            .tree = tree,
            .total = tree[1],
        };
    }

    pub fn deinit(self: *SumTree) void {
        if (self.heights.len > 0) self.allocator.free(self.heights);
        if (self.tree.len > 0) self.allocator.free(self.tree);
        self.heights = &.{};
        self.tree = &.{};
        self.count = 0;
        self.size = 0;
        self.total = 0.0;
    }

    pub fn setRowHeight(self: *SumTree, idx: usize, height: f32) void {
        if (idx >= self.count) return;
        const new_h = sanitizeHeight(height);
        if (self.heights[idx] == new_h) return;

        self.heights[idx] = new_h;
        var p: usize = self.size + idx;
        self.tree[p] = @as(f64, new_h);
        p >>= 1;
        while (p >= 1) : (p >>= 1) {
            self.tree[p] = self.tree[2 * p] + self.tree[2 * p + 1];
        }
        self.total = self.tree[1];
    }

    pub fn getRowHeight(self: *const SumTree, idx: usize) f32 {
        if (idx >= self.count) return 0.0;
        return self.heights[idx];
    }

    pub fn totalHeight(self: *const SumTree) f64 {
        return self.total;
    }

    pub fn prefixSum(self: *const SumTree, idx: usize) f64 {
        const clamped = @min(idx, self.count);
        if (clamped == 0) return 0.0;
        if (clamped == self.count) return self.total;

        var sum: f64 = 0.0;
        var l: usize = self.size;
        var r: usize = self.size + clamped;
        while (l < r) {
            if ((l & 1) != 0) {
                sum += self.tree[l];
                l += 1;
            }
            if ((r & 1) != 0) {
                r -= 1;
                sum += self.tree[r];
            }
            l >>= 1;
            r >>= 1;
        }
        return sum;
    }

    pub fn findRowAtY(self: *const SumTree, y: f64) usize {
        if (self.count == 0) return 0;
        if (std.math.isNan(y) or y <= 0.0) return 0;
        if (y >= self.total) return self.count;

        var node: usize = 1;
        var rem: f64 = y;
        while (node < self.size) {
            const left = node * 2;
            const left_sum = self.tree[left];
            if (left_sum <= rem) {
                rem -= left_sum;
                node = left + 1;
            } else {
                node = left;
            }
        }

        var pos = @min(node - self.size, self.count);
        while (pos > 0 and self.prefixSum(pos) > y) : (pos -= 1) {}
        while (pos < self.count and self.prefixSum(pos + 1) <= y) : (pos += 1) {}
        return pos;
    }

    pub fn visibleRange(self: *const SumTree, scroll_y: f64, viewport_h: f64) VisibleRange {
        if (self.count == 0 or
            !std.math.isFinite(viewport_h) or viewport_h <= 0.0 or
            !std.math.isFinite(scroll_y))
        {
            return .{ .first_idx = 0, .end_idx = 0, .first_y_offset = 0.0 };
        }
        if (scroll_y >= self.total) {
            return .{ .first_idx = self.count, .end_idx = self.count, .first_y_offset = self.total };
        }

        const y_end = scroll_y + viewport_h;
        if (y_end <= 0.0) {
            return .{ .first_idx = 0, .end_idx = 0, .first_y_offset = 0.0 };
        }

        const y_start = @max(0.0, scroll_y);
        const first_idx = self.findRowAtY(y_start);
        if (first_idx >= self.count) {
            return .{ .first_idx = self.count, .end_idx = self.count, .first_y_offset = self.total };
        }
        const first_y_offset = self.prefixSum(first_idx);

        var end_idx = self.findRowAtY(y_end);
        while (end_idx < self.count and self.prefixSum(end_idx) < y_end) : (end_idx += 1) {}
        if (end_idx < first_idx) {
            end_idx = first_idx;
        }

        return .{
            .first_idx = first_idx,
            .end_idx = end_idx,
            .first_y_offset = first_y_offset,
        };
    }
};

/// 60 Hz display-link inertial scroller with rubber-band overscroll damping,
/// exponential fling friction, critically damped spring-back, and clean
/// zero-tick sleep settling.
pub const InertialScroller = struct {
    pub const RUBBER_BAND_FACTOR: f64 = 0.35;
    pub const MAX_VELOCITY: f64 = 6000.0;
    pub const FRICTION_DECAY: f64 = 4.5;
    pub const SPRING_OMEGA: f64 = 14.0;
    pub const VELOCITY_SMOOTH_TAU: f64 = 0.02;
    pub const MIN_FLING_VELOCITY: f64 = 15.0;
    pub const SETTLE_VELOCITY: f64 = 5.0;
    pub const SETTLE_EPSILON: f64 = 0.5;
    pub const MAX_STEP_DT: f64 = 0.05;
    pub const MAX_RESIZE_OVERSCROLL: f64 = 200.0;

    offset: f64 = 0.0,
    velocity: f64 = 0.0,
    max_scroll: f64 = 0.0,
    dragging: bool = false,
    animating: bool = false,
    last_drag_y: f64 = 0.0,
    last_drag_t: f64 = 0.0,
    vel_accum_dy: f64 = 0.0,
    vel_last_t: f64 = 0.0,

    fn sanitizeMaxScroll(max_scroll: f64) f64 {
        if (!std.math.isFinite(max_scroll) or max_scroll <= 0.0) return 0.0;
        return max_scroll;
    }

    pub fn init(max_scroll: f64) InertialScroller {
        return .{
            .max_scroll = sanitizeMaxScroll(max_scroll),
        };
    }

    pub fn setMaxScroll(self: *InertialScroller, max_scroll: f64) void {
        self.max_scroll = sanitizeMaxScroll(max_scroll);
        if (!self.dragging) {
            if (!self.animating) {
                self.offset = std.math.clamp(self.offset, 0.0, self.max_scroll);
            } else if (self.offset > self.max_scroll and self.offset - self.max_scroll > MAX_RESIZE_OVERSCROLL) {
                self.offset = self.max_scroll;
            }
        }
    }

    pub fn isAnimating(self: *const InertialScroller) bool {
        return self.animating;
    }

    pub fn beginDrag(self: *InertialScroller, y: f64, time_s: f64) void {
        if (!std.math.isFinite(y) or !std.math.isFinite(time_s)) return;
        self.dragging = true;
        self.animating = false;
        self.velocity = 0.0;
        self.last_drag_y = y;
        self.last_drag_t = time_s;
        self.vel_accum_dy = 0.0;
        self.vel_last_t = time_s;
    }

    pub fn updateDrag(self: *InertialScroller, y: f64, time_s: f64) void {
        if (!std.math.isFinite(y) or !std.math.isFinite(time_s)) return;
        if (!self.dragging) {
            self.beginDrag(y, time_s);
            return;
        }

        const raw_delta = self.last_drag_y - y;
        var applied_delta = raw_delta;
        const next_offset = self.offset + raw_delta;
        if (next_offset < 0.0) {
            if (self.offset > 0.0) {
                applied_delta = -self.offset + next_offset * RUBBER_BAND_FACTOR;
            } else if (raw_delta < 0.0) {
                applied_delta = raw_delta * RUBBER_BAND_FACTOR;
            }
        } else if (next_offset > self.max_scroll) {
            if (self.offset < self.max_scroll) {
                applied_delta = (self.max_scroll - self.offset) + (next_offset - self.max_scroll) * RUBBER_BAND_FACTOR;
            } else if (raw_delta > 0.0) {
                applied_delta = raw_delta * RUBBER_BAND_FACTOR;
            }
        }
        self.offset += applied_delta;

        self.vel_accum_dy += raw_delta;
        if (time_s >= self.vel_last_t) {
            const dt = time_s - self.vel_last_t;
            if (dt > 0.0001) {
                const inst_v = std.math.clamp(self.vel_accum_dy / dt, -MAX_VELOCITY, MAX_VELOCITY);
                const alpha = 1.0 - @exp(-dt / VELOCITY_SMOOTH_TAU);
                self.velocity = std.math.clamp(
                    self.velocity + (inst_v - self.velocity) * alpha,
                    -MAX_VELOCITY,
                    MAX_VELOCITY,
                );
                self.vel_accum_dy = 0.0;
                self.vel_last_t = time_s;
            }
        }

        self.last_drag_y = y;
        if (time_s > self.last_drag_t) {
            self.last_drag_t = time_s;
        }
    }

    pub fn endDrag(self: *InertialScroller) void {
        self.dragging = false;
        self.vel_accum_dy = 0.0;
        const overscrolled = (self.offset < 0.0 or self.offset > self.max_scroll);
        if (overscrolled or @abs(self.velocity) > MIN_FLING_VELOCITY) {
            self.animating = true;
        } else {
            self.velocity = 0.0;
            self.animating = false;
        }
    }

    pub fn onWheel(self: *InertialScroller, dy: f64) void {
        if (!std.math.isFinite(dy)) return;
        self.dragging = false;
        self.animating = false;
        self.velocity = 0.0;
        self.vel_accum_dy = 0.0;
        self.offset = std.math.clamp(self.offset + dy, 0.0, self.max_scroll);
    }

    pub fn step(self: *InertialScroller, dt_s: f64) bool {
        if (!std.math.isFinite(self.offset) or !std.math.isFinite(self.velocity)) {
            self.offset = 0.0;
            self.velocity = 0.0;
            self.animating = false;
            return false;
        }
        if (self.dragging or !self.animating) return false;
        if (!std.math.isFinite(dt_s) or dt_s <= 0.0) return self.animating;

        const dt = @min(dt_s, MAX_STEP_DT);

        if (self.offset < 0.0 or self.offset > self.max_scroll) {
            const target: f64 = if (self.offset < 0.0) 0.0 else self.max_scroll;
            const x = self.offset - target;
            const exp_term = @exp(-SPRING_OMEGA * dt);
            const new_x = (x + (self.velocity + SPRING_OMEGA * x) * dt) * exp_term;
            const new_v = (self.velocity - SPRING_OMEGA * (self.velocity + SPRING_OMEGA * x) * dt) * exp_term;
            self.offset = target + new_x;
            self.velocity = new_v;
        } else {
            self.offset += self.velocity * dt;
            self.velocity *= @exp(-FRICTION_DECAY * dt);
        }

        const dist_out: f64 = if (self.offset < 0.0)
            -self.offset
        else if (self.offset > self.max_scroll)
            self.offset - self.max_scroll
        else
            0.0;

        if (@abs(self.velocity) < SETTLE_VELOCITY and dist_out <= SETTLE_EPSILON) {
            self.offset = std.math.clamp(self.offset, 0.0, self.max_scroll);
            self.velocity = 0.0;
            self.animating = false;
        }

        return self.animating;
    }
};
