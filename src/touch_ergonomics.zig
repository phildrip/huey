const std = @import("std");
const core = @import("core.zig");

pub const MIN_TOUCH_TARGET_DP: f32 = 44.0;
pub const DRAG_SLOP_DP: f32 = 8.0;

pub const GestureDecision = enum {
    idle,
    pending,
    tap,
    vertical_scroll,
    horizontal_drag,
    scroll_end,
    drag_end,
    cancelled,
};

fn isInteractiveKind(kind: core.NodeKind) bool {
    return kind == .toggle or kind == .slider;
}

fn isPositiveFiniteRect(r: core.Rect) bool {
    return std.math.isFinite(r.x) and
        std.math.isFinite(r.y) and
        std.math.isFinite(r.w) and
        std.math.isFinite(r.h) and
        r.w > 0.0 and
        r.h > 0.0 and
        std.math.isFinite(r.x + r.w) and
        std.math.isFinite(r.y + r.h);
}

fn rectContains(r: core.Rect, x: f32, y: f32) bool {
    return x >= r.x and x <= r.x + r.w and y >= r.y and y <= r.y + r.h;
}

fn intersectClip(clip: [4]f32, r: core.Rect) [4]f32 {
    return .{
        @max(clip[0], r.x),
        @max(clip[1], r.y),
        @min(clip[2], r.x + r.w),
        @min(clip[3], r.y + r.h),
    };
}

fn isClipEmpty(clip: [4]f32) bool {
    return clip[2] <= clip[0] or clip[3] <= clip[1];
}

fn clipContains(clip: [4]f32, x: f32, y: f32) bool {
    return x >= clip[0] and x <= clip[2] and y >= clip[1] and y <= clip[3];
}

fn resolveDepth(arena: *const core.LayoutArena, idx: u16) ?usize {
    const parents = arena.nodes.items(.parent);
    const limit = arena.nodes.len;
    var cur: ?u16 = idx;
    var depth: usize = 0;
    while (cur) |c| {
        if (c >= limit) return null;
        if (parents[c]) |p| {
            depth += 1;
            if (depth >= limit) return null;
            cur = p;
        } else {
            return depth;
        }
    }
    return null;
}

pub fn isNodeAbove(arena: *const core.LayoutArena, a: core.NodeId, b: core.NodeId) bool {
    if (arena.getKind(a) == null or arena.getKind(b) == null) return false;
    if (a.index == b.index) return false;

    const a_depth = resolveDepth(arena, a.index) orelse return false;
    const b_depth = resolveDepth(arena, b.index) orelse return false;

    const slice = arena.nodes.slice();
    const parents = slice.items(.parent);
    const next_siblings = slice.items(.next_sibling);
    const limit = arena.nodes.len;

    var cur_a = a.index;
    var cur_b = b.index;
    var da = a_depth;
    var db = b_depth;

    while (da > db) : (da -= 1) {
        cur_a = parents[cur_a] orelse return false;
    }
    while (db > da) : (db -= 1) {
        cur_b = parents[cur_b] orelse return false;
    }

    if (cur_a == cur_b) {
        return a_depth > b_depth;
    }

    var steps: usize = 0;
    while (steps < limit) : (steps += 1) {
        const pa = parents[cur_a] orelse return false;
        const pb = parents[cur_b] orelse return false;
        if (pa == pb) {
            var sib_opt = next_siblings[cur_b];
            var sib_steps: usize = 0;
            while (sib_opt) |sib| : (sib_steps += 1) {
                if (sib == cur_a) return true;
                if (sib_steps >= limit) return false;
                sib_opt = next_siblings[sib];
            }
            return false;
        }
        cur_a = pa;
        cur_b = pb;
    }
    return false;
}

fn visitSiblingsReverse(
    arena: *const core.LayoutArena,
    child_opt: ?u16,
    clip: [4]f32,
    x: f32,
    y: f32,
    top_hit: ?core.NodeId,
    best_id: *?core.NodeId,
    best_dist2: *f64,
    budget: *usize,
) void {
    const c = child_opt orelse return;
    if (budget.* == 0 or c >= arena.nodes.len) return;
    budget.* -= 1;

    const next = arena.nodes.items(.next_sibling)[c];
    if (next) |n| {
        visitSiblingsReverse(arena, n, clip, x, y, top_hit, best_id, best_dist2, budget);
    }
    visitSubtreeReverse(arena, c, clip, x, y, top_hit, best_id, best_dist2, budget);
}

fn visitSubtreeReverse(
    arena: *const core.LayoutArena,
    idx: u16,
    clip: [4]f32,
    x: f32,
    y: f32,
    top_hit: ?core.NodeId,
    best_id: *?core.NodeId,
    best_dist2: *f64,
    budget: *usize,
) void {
    if (budget.* == 0 or idx >= arena.nodes.len) return;
    budget.* -= 1;

    const slice = arena.nodes.slice();
    if (slice.items(.disabled)[idx]) return;

    const r = slice.items(.rect)[idx];
    const clip_children = slice.items(.scroll_props)[idx].clip_children;
    const first_child = slice.items(.first_child)[idx];

    if (first_child != null) {
        if (clip_children) {
            if (isPositiveFiniteRect(r)) {
                const child_clip = intersectClip(clip, r);
                if (!isClipEmpty(child_clip) and clipContains(child_clip, x, y)) {
                    visitSiblingsReverse(arena, first_child, child_clip, x, y, top_hit, best_id, best_dist2, budget);
                }
            }
        } else {
            visitSiblingsReverse(arena, first_child, clip, x, y, top_hit, best_id, best_dist2, budget);
        }
    }

    const kind = slice.items(.kind)[idx];
    if (!isInteractiveKind(kind)) return;
    if (!isPositiveFiniteRect(r)) return;
    if (!clipContains(clip, x, y)) return;

    const vis_x0 = @max(r.x, clip[0]);
    const vis_y0 = @max(r.y, clip[1]);
    const vis_x1 = @min(r.x + r.w, clip[2]);
    const vis_y1 = @min(r.y + r.h, clip[3]);
    if (vis_x1 <= vis_x0 or vis_y1 <= vis_y0) return;

    const vis_cx = (vis_x0 + vis_x1) * 0.5;
    const vis_cy = (vis_y0 + vis_y1) * 0.5;
    if (!std.math.isFinite(vis_cx) or !std.math.isFinite(vis_cy)) return;

    const pad_x: f32 = @max(0.0, (MIN_TOUCH_TARGET_DP - r.w) * 0.5);
    const pad_y: f32 = @max(0.0, (MIN_TOUCH_TARGET_DP - r.h) * 0.5);
    const expanded = core.Rect{
        .x = r.x - pad_x,
        .y = r.y - pad_y,
        .w = r.w + pad_x * 2.0,
        .h = r.h + pad_y * 2.0,
    };
    if (!rectContains(expanded, x, y)) return;

    const id: core.NodeId = .{ .index = idx, .gen = slice.items(.gen)[idx] };
    if (top_hit) |th| {
        if (isNodeAbove(arena, th, id)) return;
    }
    if (arena.hitTest(vis_cx, vis_cy)) |center_hit| {
        if (isNodeAbove(arena, center_hit, id)) return;
    }

    const dx: f64 = @as(f64, x) - @as(f64, vis_cx);
    const dy: f64 = @as(f64, y) - @as(f64, vis_cy);
    const dist2: f64 = dx * dx + dy * dy;
    if (!std.math.isFinite(dist2)) return;

    if (best_id.* == null or dist2 < best_dist2.*) {
        best_id.* = id;
        best_dist2.* = dist2;
    }
}

pub fn hitTestWithTouchSlop(
    arena: *const core.LayoutArena,
    x: f32,
    y: f32,
    trapped_container: ?core.NodeId,
) ?core.NodeId {
    if (!std.math.isFinite(x) or !std.math.isFinite(y)) return null;

    if (arena.layout_eval_count > 0) {
        if (!std.math.isFinite(arena.viewport_w) or
            !std.math.isFinite(arena.viewport_h) or
            arena.viewport_w <= 0.0 or
            arena.viewport_h <= 0.0 or
            x < 0.0 or
            y < 0.0 or
            x > arena.viewport_w or
            y > arena.viewport_h)
        {
            return null;
        }
    }

    const trap: ?core.NodeId = if (trapped_container) |tc|
        (if (arena.isEnabledTree(tc)) tc else null)
    else
        null;

    const top_hit = arena.hitTest(x, y);
    if (top_hit) |hit_id| {
        if (arena.getKind(hit_id)) |kind| {
            if (isInteractiveKind(kind) and arena.isEnabledTree(hit_id)) {
                if (trap) |tc| {
                    if (arena.isDescendantOrSelf(tc, hit_id)) return hit_id;
                } else {
                    return hit_id;
                }
            }
        }
    }

    const start_node = trap orelse (arena.getRoot() orelse return null);

    var clip: [4]f32 = .{
        -std.math.inf(f32),
        -std.math.inf(f32),
        std.math.inf(f32),
        std.math.inf(f32),
    };
    var anc_opt = arena.getParent(start_node);
    var anc_steps: usize = 0;
    while (anc_opt) |anc| : (anc_steps += 1) {
        if (anc_steps >= arena.nodes.len) return null;
        if (arena.isClipChildren(anc)) {
            const ar = arena.getRect(anc) orelse return null;
            if (!isPositiveFiniteRect(ar)) return null;
            clip = intersectClip(clip, ar);
            if (isClipEmpty(clip) or !clipContains(clip, x, y)) return null;
        }
        anc_opt = arena.getParent(anc);
    }

    var best_id: ?core.NodeId = null;
    var best_dist2: f64 = std.math.inf(f64);
    var budget: usize = arena.nodes.len * 2 + 1;
    visitSubtreeReverse(arena, start_node.index, clip, x, y, top_hit, &best_id, &best_dist2, &budget);
    return best_id;
}

pub const TouchArbiter = struct {
    active_pointer: ?i32 = null,
    down_x: f32 = 0,
    down_y: f32 = 0,
    target_kind: ?core.NodeKind = null,
    state: GestureDecision = .idle,

    pub fn init() TouchArbiter {
        return .{};
    }

    pub fn reset(self: *TouchArbiter) void {
        self.* = .{};
    }

    pub fn onDown(
        self: *TouchArbiter,
        pointer_id: i32,
        x: f32,
        y: f32,
        target_kind: ?core.NodeKind,
    ) void {
        if (!std.math.isFinite(x) or !std.math.isFinite(y)) return;
        if (self.active_pointer) |ap| {
            if (ap != pointer_id) return;
        }
        self.active_pointer = pointer_id;
        self.down_x = x;
        self.down_y = y;
        self.target_kind = target_kind;
        self.state = .pending;
    }

    pub fn onMove(self: *TouchArbiter, pointer_id: i32, x: f32, y: f32) GestureDecision {
        const active = self.active_pointer orelse return .idle;
        if (active != pointer_id) return .idle;
        if (!std.math.isFinite(x) or !std.math.isFinite(y)) return self.state;

        switch (self.state) {
            .vertical_scroll, .horizontal_drag => return self.state,
            .pending => {
                const dx: f64 = @as(f64, x) - @as(f64, self.down_x);
                const dy: f64 = @as(f64, y) - @as(f64, self.down_y);
                const slop: f64 = @as(f64, DRAG_SLOP_DP);
                if (dx * dx + dy * dy >= slop * slop) {
                    const adx = @abs(dx);
                    const ady = @abs(dy);
                    if (self.target_kind == .slider and adx >= ady) {
                        self.state = .horizontal_drag;
                    } else if (ady >= adx) {
                        self.state = .vertical_scroll;
                    } else {
                        self.state = .cancelled;
                    }
                }
                return self.state;
            },
            else => return self.state,
        }
    }

    pub fn onUp(self: *TouchArbiter, pointer_id: i32) GestureDecision {
        const active = self.active_pointer orelse return .idle;
        if (active != pointer_id) return .idle;
        const decision: GestureDecision = switch (self.state) {
            .pending => .tap,
            .vertical_scroll => .scroll_end,
            .horizontal_drag => .drag_end,
            else => .cancelled,
        };
        self.reset();
        return decision;
    }

    pub fn onCancel(self: *TouchArbiter, pointer_id: i32) GestureDecision {
        const active = self.active_pointer orelse return .idle;
        if (active != pointer_id) return .idle;
        self.reset();
        return .cancelled;
    }
};
