const std = @import("std");
const core = @import("core.zig");
const focus = @import("focus.zig");

pub const MAX_ANNOUNCEMENTS: usize = 32;
pub const MAX_ANNOUNCEMENT_LEN: usize = 128;

pub const A11yRole = enum(u8) {
    container,
    panel,
    button,
    switch_control,
    slider,
    progress_bar,
    swatch,
    text_input,
};

pub const A11yStates = packed struct(u8) {
    focusable: bool = false,
    focused: bool = false,
    focus_visible: bool = false,
    checked: bool = false,
    disabled: bool = false,
    expanded: bool = false,
    hidden: bool = false,
    _pad: u1 = 0,
};

pub const A11yActions = packed struct(u8) {
    click: bool = false,
    toggle: bool = false,
    focus: bool = false,
    set_value: bool = false,
    scroll: bool = false,
    _pad: u3 = 0,
};

pub const LivePoliteness = enum(u8) {
    off,
    polite,
    assertive,
};

pub const Announcement = struct {
    message: []const u8,
    politeness: LivePoliteness,
};

pub const A11yNode = struct {
    id: core.NodeId,
    parent: ?core.NodeId,
    role: A11yRole,
    test_id: []const u8,
    name: []const u8,
    rect: core.Rect,
    states: A11yStates,
    actions: A11yActions,
    numeric_value: ?f32 = null,
    min_value: f32 = 0.0,
    max_value: f32 = 1.0,
};

pub const A11yActionRequest = union(enum) {
    click: core.NodeId,
    toggle: core.NodeId,
    focus: core.NodeId,
    set_value: struct { id: core.NodeId, value: f32 },
    scroll: struct { id: core.NodeId, x: f32, y: f32 },
};

const DfsFrame = struct {
    idx: u16,
    parent_enabled: bool,
    clip_rect: [4]f32,
};

fn nodeIdEql(a: core.NodeId, b: core.NodeId) bool {
    return a.index == b.index and a.gen == b.gen;
}

fn mapRole(kind: core.NodeKind, role: core.SemanticRole) A11yRole {
    return switch (role) {
        .container => switch (kind) {
            .toggle => .switch_control,
            .slider => .slider,
            .bar => .progress_bar,
            else => .container,
        },
        .panel => .panel,
        .switch_control => .switch_control,
        .slider => .slider,
        .progress_bar => .progress_bar,
        .swatch => .swatch,
    };
}

fn finiteOrZero32(v: f32) f32 {
    if (!std.math.isFinite(v) or v == 0.0) return 0.0;
    return v;
}

fn isRectValidPositive(r: core.Rect) bool {
    return std.math.isFinite(r.x) and std.math.isFinite(r.y) and
        std.math.isFinite(r.w) and std.math.isFinite(r.h) and
        r.w > 0.0 and r.h > 0.0;
}

fn isClipEmpty(clip: [4]f32) bool {
    return !(clip[2] > clip[0] and clip[3] > clip[1]);
}

fn intersectsClip(r: core.Rect, clip: [4]f32) bool {
    if (!isRectValidPositive(r) or isClipEmpty(clip)) return false;
    const x1 = r.x + r.w;
    const y1 = r.y + r.h;
    if (!std.math.isFinite(x1) or !std.math.isFinite(y1)) return false;
    return x1 > clip[0] and r.x < clip[2] and y1 > clip[1] and r.y < clip[3];
}

fn intersectClip(clip: [4]f32, r: core.Rect) [4]f32 {
    if (!isRectValidPositive(r)) return .{ 0.0, 0.0, 0.0, 0.0 };
    const x1 = r.x + r.w;
    const y1 = r.y + r.h;
    if (!std.math.isFinite(x1) or !std.math.isFinite(y1)) return .{ 0.0, 0.0, 0.0, 0.0 };
    return .{
        @max(clip[0], r.x),
        @max(clip[1], r.y),
        @min(clip[2], x1),
        @min(clip[3], y1),
    };
}

fn isInteractiveCard(fill: core.Color, bw_raw: f32, border: core.Color) bool {
    const bw = if (std.math.isFinite(bw_raw) and bw_raw > 0.0) bw_raw else 0.0;
    return fill[3] > 0.0 or (bw > 0.0 and border[3] > 0.0);
}

fn resolveNodeIndex(arena: *const core.LayoutArena, id: core.NodeId) ?u16 {
    if (arena.getKind(id) == null) return null;
    if (id.index >= arena.nodes.len) return null;
    return id.index;
}

fn isVisibleInClipTree(arena: *const core.LayoutArena, id: core.NodeId) bool {
    const idx = resolveNodeIndex(arena, id) orelse return false;
    const slice = arena.nodes.slice();
    const rects = slice.items(.rect);
    const parents = slice.items(.parent);
    const scroll_props = slice.items(.scroll_props);
    const n = arena.nodes.len;

    const node_rect = rects[idx];
    if (!isRectValidPositive(node_rect)) return false;

    var clip: [4]f32 = .{ -std.math.inf(f32), -std.math.inf(f32), std.math.inf(f32), std.math.inf(f32) };
    var cur_opt = parents[idx];
    var steps: usize = 0;
    while (cur_opt) |cur| : (steps += 1) {
        if (steps >= n or cur >= n) return false;
        if (scroll_props[cur].clip_children) {
            clip = intersectClip(clip, rects[cur]);
            if (isClipEmpty(clip)) return false;
        }
        cur_opt = parents[cur];
    }
    return intersectsClip(node_rect, clip);
}

fn utf8TruncateLen(s: []const u8, max_len: usize) usize {
    const limit = @min(s.len, max_len);
    var i: usize = 0;
    while (i < limit) {
        const seq_len = std.unicode.utf8ByteSequenceLength(s[i]) catch break;
        if (i + seq_len > limit) break;
        if (seq_len > 1) {
            _ = std.unicode.utf8Decode(s[i .. i + seq_len]) catch break;
        }
        i += seq_len;
    }
    return i;
}

fn writeJsonString(writer: anytype, s: []const u8) !void {
    try writer.writeByte('"');
    var i: usize = 0;
    while (i < s.len) {
        const b = s[i];
        if (b < 0x80) {
            switch (b) {
                '"' => try writer.writeAll("\\\""),
                '\\' => try writer.writeAll("\\\\"),
                '\n' => try writer.writeAll("\\n"),
                '\r' => try writer.writeAll("\\r"),
                '\t' => try writer.writeAll("\\t"),
                0x08 => try writer.writeAll("\\b"),
                0x0c => try writer.writeAll("\\f"),
                0x7f => try writer.writeAll("\\u007f"),
                else => {
                    if (b < 0x20) {
                        try writer.print("\\u{x:0>4}", .{b});
                    } else {
                        try writer.writeByte(b);
                    }
                },
            }
            i += 1;
        } else {
            const seq_len = std.unicode.utf8ByteSequenceLength(b) catch {
                try writer.writeAll("\\ufffd");
                i += 1;
                continue;
            };
            if (i + seq_len > s.len) {
                try writer.writeAll("\\ufffd");
                i += 1;
                continue;
            }
            _ = std.unicode.utf8Decode(s[i .. i + seq_len]) catch {
                try writer.writeAll("\\ufffd");
                i += 1;
                continue;
            };
            try writer.writeAll(s[i .. i + seq_len]);
            i += seq_len;
        }
    }
    try writer.writeByte('"');
}

/// Snapshot of the UI semantic/accessibility tree compatible with AT-SPI,
/// Android AccessibilityNodeInfo, and AccessKit bridges.
pub const A11yTree = struct {
    allocator: std.mem.Allocator,
    nodes: std.ArrayList(A11yNode) = .empty,
    dfs_stack: std.ArrayList(DfsFrame) = .empty,
    visited: std.ArrayList(bool) = .empty,
    generation: u64 = 0,

    ann_bufs: [MAX_ANNOUNCEMENTS][MAX_ANNOUNCEMENT_LEN]u8 = undefined,
    ann_lens: [MAX_ANNOUNCEMENTS]u8 = [_]u8{0} ** MAX_ANNOUNCEMENTS,
    ann_politeness: [MAX_ANNOUNCEMENTS]LivePoliteness = [_]LivePoliteness{.off} ** MAX_ANNOUNCEMENTS,
    ann_head: usize = 0,
    ann_count: usize = 0,

    pub fn init(allocator: std.mem.Allocator) A11yTree {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *A11yTree) void {
        self.nodes.deinit(self.allocator);
        self.dfs_stack.deinit(self.allocator);
        self.visited.deinit(self.allocator);
    }

    /// Rebuilds the accessibility snapshot in O(N) iterative DFS order from
    /// `arena` + `fm`. Pre-allocates capacities before mutating state so OOM
    /// preserves the prior snapshot, and reuses capacity on steady-state frames.
    pub fn syncFromArena(
        self: *A11yTree,
        arena: *const core.LayoutArena,
        fm: ?*const focus.FocusManager,
    ) !void {
        const root_opt = arena.root_index;
        const n = arena.nodes.len;
        if (root_opt == null or root_opt.? >= n) {
            self.nodes.clearRetainingCapacity();
            self.dfs_stack.clearRetainingCapacity();
            self.visited.clearRetainingCapacity();
            self.generation += 1;
            return;
        }
        const root_idx = root_opt.?;

        // Reserve all capacities up front so OOM leaves prior snapshot & generation intact.
        try self.nodes.ensureTotalCapacity(self.allocator, n);
        try self.dfs_stack.ensureTotalCapacity(self.allocator, n);
        try self.visited.ensureTotalCapacity(self.allocator, n);

        self.nodes.clearRetainingCapacity();
        self.dfs_stack.clearRetainingCapacity();
        self.visited.clearRetainingCapacity();
        self.visited.appendNTimesAssumeCapacity(false, n);
        self.generation += 1;

        const slice = arena.nodes.slice();
        const gens = slice.items(.gen);
        const kinds = slice.items(.kind);
        const roles = slice.items(.role);
        const test_ids = slice.items(.test_id);
        const labels = slice.items(.label);
        const parents = slice.items(.parent);
        const first_children = slice.items(.first_child);
        const next_siblings = slice.items(.next_sibling);
        const rects = slice.items(.rect);
        const fills = slice.items(.fill);
        const borders = slice.items(.border);
        const border_widths = slice.items(.border_width);
        const checkeds = slice.items(.checked);
        const slider_vals = slice.items(.slider_val);
        const disabled_items = slice.items(.disabled);
        const focusables = slice.items(.focusable);
        const scroll_props = slice.items(.scroll_props);

        const trap_c: ?core.NodeId = if (fm) |f| f.topTrappedContainer(arena) else null;
        const unclipped_rect: [4]f32 = .{
            -std.math.inf(f32),
            -std.math.inf(f32),
            std.math.inf(f32),
            std.math.inf(f32),
        };

        self.visited.items[root_idx] = true;
        self.dfs_stack.appendAssumeCapacity(.{
            .idx = root_idx,
            .parent_enabled = true,
            .clip_rect = unclipped_rect,
        });

        while (self.dfs_stack.pop()) |frame| {
            const idx = frame.idx;
            const id = core.NodeId{ .index = idx, .gen = gens[idx] };
            const parent_id: ?core.NodeId = if (parents[idx]) |p_idx|
                (if (p_idx < n) core.NodeId{ .index = p_idx, .gen = gens[p_idx] } else null)
            else
                null;

            const kind = kinds[idx];
            const raw_role = roles[idx];
            const a11y_role = mapRole(kind, raw_role);
            const test_id = test_ids[idx];
            const label = labels[idx];
            const name = if (label.len > 0) label else test_id;
            const rect = rects[idx];

            const enabled = frame.parent_enabled and !disabled_items[idx];
            const in_modal_trap = if (trap_c) |tc| arena.isDescendantOrSelf(tc, id) else true;
            const visible = intersectsClip(rect, frame.clip_rect);
            const hidden = !visible;

            const focusable_raw = if (focusables[idx]) |f| f else (kind == .toggle or kind == .slider);
            const focusable = enabled and in_modal_trap and visible and focusable_raw;
            const focused = if (fm) |f| blk: {
                const fid = f.focused() orelse break :blk false;
                break :blk enabled and in_modal_trap and visible and nodeIdEql(fid, id);
            } else false;
            const focus_visible = focused and (if (fm) |f| f.isFocusVisible() else false);
            const checked = if (kind == .toggle or raw_role == .switch_control) checkeds[idx] else false;

            const card_clickable = (kind == .card) and isInteractiveCard(fills[idx], border_widths[idx], borders[idx]);
            const actions: A11yActions = if (!enabled or hidden or !in_modal_trap) .{} else .{
                .click = (kind == .toggle or card_clickable),
                .toggle = (kind == .toggle),
                .focus = focusable,
                .set_value = (kind == .slider),
                .scroll = scroll_props[idx].clip_children,
            };

            const numeric_value: ?f32 = if (kind == .slider or kind == .bar) slider_vals[idx] else null;

            self.nodes.appendAssumeCapacity(.{
                .id = id,
                .parent = parent_id,
                .role = a11y_role,
                .test_id = test_id,
                .name = name,
                .rect = rect,
                .states = .{
                    .focusable = focusable,
                    .focused = focused,
                    .focus_visible = focus_visible,
                    .checked = checked,
                    .disabled = !enabled,
                    .expanded = false,
                    .hidden = hidden,
                },
                .actions = actions,
                .numeric_value = numeric_value,
                .min_value = 0.0,
                .max_value = 1.0,
            });

            const child_clip = if (scroll_props[idx].clip_children)
                intersectClip(frame.clip_rect, rect)
            else
                frame.clip_rect;

            const push_start = self.dfs_stack.items.len;
            var child_opt: ?u16 = first_children[idx];
            var sib_steps: usize = 0;
            while (child_opt) |c_idx| : (sib_steps += 1) {
                if (sib_steps >= n or c_idx >= n) break;
                if (!self.visited.items[c_idx]) {
                    self.visited.items[c_idx] = true;
                    self.dfs_stack.appendAssumeCapacity(.{
                        .idx = c_idx,
                        .parent_enabled = enabled,
                        .clip_rect = child_clip,
                    });
                }
                child_opt = next_siblings[c_idx];
            }
            std.mem.reverse(DfsFrame, self.dfs_stack.items[push_start..]);
        }
    }

    pub fn findByNodeId(self: *const A11yTree, id: core.NodeId) ?*const A11yNode {
        for (self.nodes.items) |*node| {
            if (nodeIdEql(node.id, id)) return node;
        }
        return null;
    }

    pub fn findByTestId(self: *const A11yTree, test_id: []const u8) ?*const A11yNode {
        if (test_id.len == 0) return null;
        for (self.nodes.items) |*node| {
            if (std.mem.eql(u8, node.test_id, test_id)) return node;
        }
        return null;
    }

    /// Executes an accessibility action directly against `arena` / `fm`,
    /// rejecting stale, disabled, hidden/scrolled-out, modal-blocked, or non-supporting nodes.
    pub fn invokeAction(
        self: *A11yTree,
        arena: *core.LayoutArena,
        fm: ?*focus.FocusManager,
        req: A11yActionRequest,
    ) bool {
        _ = self;
        const trap_c: ?core.NodeId = if (fm) |f| f.topTrappedContainer(arena) else null;
        switch (req) {
            .click => |id| {
                const idx = resolveNodeIndex(arena, id) orelse return false;
                if (!arena.isEnabledTree(id)) return false;
                if (trap_c) |tc| {
                    if (!arena.isDescendantOrSelf(tc, id)) return false;
                }
                if (!isVisibleInClipTree(arena, id)) return false;
                const slice = arena.nodes.slice();
                const kind = slice.items(.kind)[idx];
                return switch (kind) {
                    .toggle => arena.toggleNode(id) != null,
                    .card => blk: {
                        const fill = slice.items(.fill)[idx];
                        const bw = slice.items(.border_width)[idx];
                        const border = slice.items(.border)[idx];
                        if (!isInteractiveCard(fill, bw, border)) break :blk false;
                        arena.requestRedraw();
                        break :blk true;
                    },
                    else => false,
                };
            },
            .toggle => |id| {
                if (arena.getKind(id) != .toggle) return false;
                if (!arena.isEnabledTree(id)) return false;
                if (trap_c) |tc| {
                    if (!arena.isDescendantOrSelf(tc, id)) return false;
                }
                if (!isVisibleInClipTree(arena, id)) return false;
                return arena.toggleNode(id) != null;
            },
            .focus => |id| {
                const fm_ptr = fm orelse return false;
                if (!arena.isFocusable(id)) return false;
                if (trap_c) |tc| {
                    if (!arena.isDescendantOrSelf(tc, id)) return false;
                }
                if (!isVisibleInClipTree(arena, id)) return false;
                fm_ptr.setFocusedByKeyboard(arena, id);
                const actual = fm_ptr.focused() orelse return false;
                return nodeIdEql(actual, id);
            },
            .set_value => |sv| {
                if (!std.math.isFinite(sv.value)) return false;
                if (arena.getKind(sv.id) != .slider) return false;
                if (!arena.isEnabledTree(sv.id)) return false;
                if (trap_c) |tc| {
                    if (!arena.isDescendantOrSelf(tc, sv.id)) return false;
                }
                if (!isVisibleInClipTree(arena, sv.id)) return false;
                return arena.setSliderValue(sv.id, sv.value) != null;
            },
            .scroll => |sc| {
                if (!std.math.isFinite(sc.x) or !std.math.isFinite(sc.y)) return false;
                if (arena.getKind(sc.id) == null) return false;
                if (!arena.isClipChildren(sc.id)) return false;
                if (!arena.isEnabledTree(sc.id)) return false;
                if (trap_c) |tc| {
                    if (!arena.isDescendantOrSelf(tc, sc.id)) return false;
                }
                if (!isVisibleInClipTree(arena, sc.id)) return false;
                arena.setScroll(sc.id, sc.x, sc.y);
                return true;
            },
        }
    }

    /// Queues a live-region announcement in a fixed leak-proof ring buffer.
    /// Empty messages, `.off` politeness, and invalid leading UTF-8 are ignored.
    /// Copies through a stack staging buffer so aliasing a previously popped slice is safe.
    pub fn announce(
        self: *A11yTree,
        message: []const u8,
        politeness: LivePoliteness,
    ) error{OutOfMemory}!void {
        if (politeness == .off or message.len == 0) return;
        const copy_len = utf8TruncateLen(message, MAX_ANNOUNCEMENT_LEN);
        if (copy_len == 0) return;

        var tmp: [MAX_ANNOUNCEMENT_LEN]u8 = undefined;
        @memcpy(tmp[0..copy_len], message[0..copy_len]);

        const slot: usize = if (self.ann_count == MAX_ANNOUNCEMENTS) blk: {
            const oldest = self.ann_head;
            self.ann_head = (self.ann_head + 1) % MAX_ANNOUNCEMENTS;
            break :blk oldest;
        } else blk: {
            const tail = (self.ann_head + self.ann_count) % MAX_ANNOUNCEMENTS;
            self.ann_count += 1;
            break :blk tail;
        };

        @memcpy(self.ann_bufs[slot][0..copy_len], tmp[0..copy_len]);
        self.ann_lens[slot] = @intCast(copy_len);
        self.ann_politeness[slot] = politeness;
    }

    /// Pops the oldest queued announcement.
    /// IMPORTANT: The returned `message` slice points directly into this tree's
    /// internal ring buffer, requires no manual free, and remains valid ONLY
    /// until the next `announce()` call.
    pub fn popAnnouncement(self: *A11yTree) ?Announcement {
        if (self.ann_count == 0) return null;
        const idx = self.ann_head;
        const len: usize = self.ann_lens[idx];
        const pol = self.ann_politeness[idx];
        self.ann_head = (self.ann_head + 1) % MAX_ANNOUNCEMENTS;
        self.ann_count -= 1;
        return .{
            .message = self.ann_bufs[idx][0..len],
            .politeness = pol,
        };
    }

    /// Serializes the accessibility tree in AT-SPI / AccessKit-compatible JSON.
    pub fn writeAtSpiJson(self: *const A11yTree, writer: anytype) !void {
        try writer.writeAll("{\"schema\":\"at-spi-accesskit-v1\",");
        try writer.print("\"generation\":{d},", .{self.generation});

        if (self.nodes.items.len > 0) {
            const root_id = self.nodes.items[0].id;
            try writer.print("\"root_id\":{{\"index\":{d},\"gen\":{d}}},", .{ root_id.index, root_id.gen });
        } else {
            try writer.writeAll("\"root_id\":null,");
        }

        try writer.print("\"pending_announcements\":{d},\"nodes\":[", .{self.ann_count});

        for (self.nodes.items, 0..) |node, i| {
            if (i > 0) try writer.writeAll(",");
            try writer.print("{{\"id\":{{\"index\":{d},\"gen\":{d}}},\"parent\":", .{ node.id.index, node.id.gen });
            if (node.parent) |p| {
                try writer.print("{{\"index\":{d},\"gen\":{d}}}", .{ p.index, p.gen });
            } else {
                try writer.writeAll("null");
            }
            try writer.writeAll(",\"role\":");
            try writeJsonString(writer, @tagName(node.role));
            try writer.writeAll(",\"test_id\":");
            try writeJsonString(writer, node.test_id);
            try writer.writeAll(",\"name\":");
            try writeJsonString(writer, node.name);
            try writer.print(
                ",\"rect\":{{\"x\":{d:.2},\"y\":{d:.2},\"w\":{d:.2},\"h\":{d:.2}}}",
                .{
                    finiteOrZero32(node.rect.x),
                    finiteOrZero32(node.rect.y),
                    finiteOrZero32(node.rect.w),
                    finiteOrZero32(node.rect.h),
                },
            );
            try writer.print(
                ",\"states\":{{\"focusable\":{},\"focused\":{},\"focus_visible\":{},\"checked\":{},\"disabled\":{},\"expanded\":{},\"hidden\":{}}}",
                .{
                    node.states.focusable,
                    node.states.focused,
                    node.states.focus_visible,
                    node.states.checked,
                    node.states.disabled,
                    node.states.expanded,
                    node.states.hidden,
                },
            );
            try writer.print(
                ",\"actions\":{{\"click\":{},\"toggle\":{},\"focus\":{},\"set_value\":{},\"scroll\":{}}}",
                .{
                    node.actions.click,
                    node.actions.toggle,
                    node.actions.focus,
                    node.actions.set_value,
                    node.actions.scroll,
                },
            );
            try writer.writeAll(",\"numeric_value\":");
            if (node.numeric_value) |nv| {
                try writer.print("{d:.4}", .{finiteOrZero32(nv)});
            } else {
                try writer.writeAll("null");
            }
            try writer.print(
                ",\"min_value\":{d:.4},\"max_value\":{d:.4}}}",
                .{ finiteOrZero32(node.min_value), finiteOrZero32(node.max_value) },
            );
        }

        try writer.writeAll("]}");
    }
};
