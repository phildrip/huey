const std = @import("std");
const core = @import("core.zig");

pub const MAX_SCOPES: usize = 8;
pub const MAX_TAB_ORDER: usize = 256;

pub const FocusScope = struct {
    container: core.NodeId,
    trap: bool,
    saved_focus: ?core.NodeId,
    saved_focus_visible: bool,
};

fn nodeIdEql(a: core.NodeId, b: core.NodeId) bool {
    return a.index == b.index and a.gen == b.gen;
}

fn hasEnabledPath(arena: *const core.LayoutArena, ancestor: core.NodeId, node: core.NodeId) bool {
    const limit = arena.nodes.len;
    var cur_opt: ?core.NodeId = node;
    var steps: usize = 0;
    while (cur_opt) |cur| : (steps += 1) {
        if (steps >= limit) return false;
        if (arena.getKind(cur) == null) return false;
        if (arena.isDisabled(cur)) return false;
        if (nodeIdEql(cur, ancestor)) return true;
        cur_opt = arena.getParent(cur);
    }
    return false;
}

fn updateRovingAncestors(arena: *core.LayoutArena, id: core.NodeId, trap_c: ?core.NodeId) void {
    const limit = arena.nodes.len;
    var cur_opt = arena.getParent(id);
    var steps: usize = 0;
    while (cur_opt) |cur| : (steps += 1) {
        if (steps >= limit) break;
        if (arena.isRovingGroup(cur)) {
            arena.setRovingActiveChild(cur, id);
        }
        if (trap_c) |tc| {
            if (nodeIdEql(cur, tc)) break;
        }
        cur_opt = arena.getParent(cur);
    }
}

fn findFirstFocusableDescendant(
    arena: *const core.LayoutArena,
    parent: core.NodeId,
    depth: usize,
) ?core.NodeId {
    const limit = arena.nodes.len;
    if (depth >= limit) return null;
    var child_opt = arena.getFirstChild(parent);
    var sib_steps: usize = 0;
    while (child_opt) |child| : ({
        child_opt = arena.getNextSibling(child);
        sib_steps += 1;
    }) {
        if (sib_steps >= limit) break;
        if (arena.isDisabled(child)) continue;
        if (arena.isRovingGroup(child)) {
            if (resolveRovingStop(arena, child, depth + 1)) |stop| return stop;
            continue;
        }
        if (arena.isFocusable(child)) return child;
        if (findFirstFocusableDescendant(arena, child, depth + 1)) |found| return found;
    }
    return null;
}

fn resolveRovingStop(
    arena: *const core.LayoutArena,
    rg: core.NodeId,
    depth: usize,
) ?core.NodeId {
    if (arena.getRovingActiveChild(rg)) |active| {
        if (!nodeIdEql(active, rg) and
            arena.isFocusable(active) and
            hasEnabledPath(arena, rg, active))
        {
            return active;
        }
    }
    return findFirstFocusableDescendant(arena, rg, depth);
}

fn collectTabOrderNode(
    arena: *const core.LayoutArena,
    node: core.NodeId,
    out: *[MAX_TAB_ORDER]core.NodeId,
    len: *usize,
    depth: usize,
) void {
    const limit = arena.nodes.len;
    if (depth >= limit or len.* >= MAX_TAB_ORDER) return;
    if (arena.getKind(node) == null) return;
    if (depth == 0) {
        if (!arena.isEnabledTree(node)) return;
    } else {
        if (arena.isDisabled(node)) return;
    }

    if (arena.isRovingGroup(node)) {
        if (resolveRovingStop(arena, node, depth + 1)) |stop| {
            out[len.*] = stop;
            len.* += 1;
        }
        return;
    }

    if (arena.isFocusable(node)) {
        out[len.*] = node;
        len.* += 1;
        if (len.* >= MAX_TAB_ORDER) return;
    }

    var child_opt = arena.getFirstChild(node);
    var sib_steps: usize = 0;
    while (child_opt) |child| : ({
        child_opt = arena.getNextSibling(child);
        sib_steps += 1;
    }) {
        if (sib_steps >= limit) break;
        collectTabOrderNode(arena, child, out, len, depth + 1);
        if (len.* >= MAX_TAB_ORDER) break;
    }
}

fn collectFocusableDescendants(
    arena: *const core.LayoutArena,
    parent: core.NodeId,
    out: *[MAX_TAB_ORDER]core.NodeId,
    len: *usize,
    depth: usize,
) void {
    const limit = arena.nodes.len;
    if (depth >= limit or len.* >= MAX_TAB_ORDER) return;
    var child_opt = arena.getFirstChild(parent);
    var sib_steps: usize = 0;
    while (child_opt) |child| : ({
        child_opt = arena.getNextSibling(child);
        sib_steps += 1;
    }) {
        if (sib_steps >= limit) break;
        if (arena.isDisabled(child)) continue;
        if (arena.isFocusable(child)) {
            out[len.*] = child;
            len.* += 1;
            if (len.* >= MAX_TAB_ORDER) return;
        }
        collectFocusableDescendants(arena, child, out, len, depth + 1);
        if (len.* >= MAX_TAB_ORDER) return;
    }
}

pub const FocusManager = struct {
    focused_node: ?core.NodeId = null,
    focus_visible: bool = false,
    scopes: [MAX_SCOPES]FocusScope = undefined,
    scope_len: usize = 0,

    pub fn init() FocusManager {
        return .{};
    }

    pub fn focused(self: *const FocusManager) ?core.NodeId {
        return self.focused_node;
    }

    pub fn isFocusVisible(self: *const FocusManager) bool {
        return self.focus_visible;
    }

    pub fn clearFocus(self: *FocusManager) void {
        self.focused_node = null;
        self.focus_visible = false;
    }

    pub fn topTrappedContainer(self: *const FocusManager, arena: *const core.LayoutArena) ?core.NodeId {
        var i = self.scope_len;
        while (i > 0) {
            i -= 1;
            const s = self.scopes[i];
            if (s.trap and arena.isEnabledTree(s.container)) {
                return s.container;
            }
        }
        return null;
    }

    pub fn validate(self: *FocusManager, arena: *const core.LayoutArena) void {
        var write_idx: usize = 0;
        for (self.scopes[0..self.scope_len]) |s| {
            if (arena.getKind(s.container) == null) continue;
            var kept = s;
            if (kept.saved_focus) |sf| {
                if (!arena.isFocusable(sf)) {
                    kept.saved_focus = null;
                    kept.saved_focus_visible = false;
                }
            }
            self.scopes[write_idx] = kept;
            write_idx += 1;
        }
        self.scope_len = write_idx;

        if (self.focused_node) |id| {
            const allowed = if (self.topTrappedContainer(arena)) |tc|
                hasEnabledPath(arena, tc, id)
            else
                true;
            if (!arena.isFocusable(id) or !allowed) {
                self.focused_node = null;
                self.focus_visible = false;
            }
        } else {
            self.focus_visible = false;
        }
    }

    fn setFocusedInternal(self: *FocusManager, arena: *core.LayoutArena, id: core.NodeId, visible: bool) void {
        if (!arena.isFocusable(id)) return;
        const trap_c = self.topTrappedContainer(arena);
        if (trap_c) |tc| {
            if (!hasEnabledPath(arena, tc, id)) return;
        }
        updateRovingAncestors(arena, id, trap_c);
        self.focused_node = id;
        self.focus_visible = visible;
        arena.requestRedraw();
    }

    pub fn setFocusedByKeyboard(self: *FocusManager, arena: *core.LayoutArena, id: core.NodeId) void {
        self.setFocusedInternal(arena, id, true);
    }

    pub fn setFocusedByPointer(self: *FocusManager, arena: *core.LayoutArena, id: core.NodeId) void {
        self.setFocusedInternal(arena, id, false);
    }

    pub fn pushScope(
        self: *FocusManager,
        arena: *core.LayoutArena,
        container: core.NodeId,
        trap: bool,
    ) error{ InvalidNodeId, ScopeStackOverflow }!void {
        self.validate(arena);
        if (arena.getKind(container) == null) return error.InvalidNodeId;
        if (self.scope_len >= MAX_SCOPES) return error.ScopeStackOverflow;

        self.scopes[self.scope_len] = .{
            .container = container,
            .trap = trap,
            .saved_focus = self.focused_node,
            .saved_focus_visible = self.focus_visible,
        };
        self.scope_len += 1;

        var buf: [MAX_TAB_ORDER]core.NodeId = undefined;
        var len: usize = 0;
        collectTabOrderNode(arena, container, &buf, &len, 0);
        if (len > 0) {
            self.setFocusedByKeyboard(arena, buf[0]);
        } else {
            self.clearFocus();
            arena.requestRedraw();
        }
    }

    pub fn popScope(self: *FocusManager, arena: *core.LayoutArena) void {
        self.validate(arena);
        if (self.scope_len == 0) return;
        self.scope_len -= 1;
        const popped = self.scopes[self.scope_len];

        const trap_c_opt = self.topTrappedContainer(arena);
        if (popped.saved_focus) |sf| {
            if (arena.isFocusable(sf)) {
                const in_trap = if (trap_c_opt) |tc| hasEnabledPath(arena, tc, sf) else true;
                if (in_trap) {
                    self.setFocusedInternal(arena, sf, popped.saved_focus_visible);
                    return;
                }
            }
        }

        if (trap_c_opt) |tc| {
            var buf: [MAX_TAB_ORDER]core.NodeId = undefined;
            var len: usize = 0;
            collectTabOrderNode(arena, tc, &buf, &len, 0);
            if (len > 0) {
                self.setFocusedInternal(arena, buf[0], self.focus_visible);
                return;
            }
        }

        self.clearFocus();
        arena.requestRedraw();
    }

    pub fn enclosingRovingGroup(self: *const FocusManager, arena: *const core.LayoutArena) ?core.NodeId {
        const id = self.focused_node orelse return null;
        if (!arena.isFocusable(id)) return null;
        const trap_c = self.topTrappedContainer(arena);
        if (trap_c) |tc| {
            if (!hasEnabledPath(arena, tc, id)) return null;
        }

        const limit = arena.nodes.len;
        var cur_opt = arena.getParent(id);
        var steps: usize = 0;
        var outermost: ?core.NodeId = null;
        while (cur_opt) |cur| : (steps += 1) {
            if (steps >= limit) return null;
            if (arena.isDisabled(cur)) return null;
            if (arena.isRovingGroup(cur)) {
                outermost = cur;
            }
            if (trap_c) |tc| {
                if (nodeIdEql(cur, tc)) break;
            }
            cur_opt = arena.getParent(cur);
        }
        return outermost;
    }

    fn stepFocus(self: *FocusManager, arena: *core.LayoutArena, forward: bool) ?core.NodeId {
        self.validate(arena);

        const search_root = self.topTrappedContainer(arena) orelse (arena.getRoot() orelse return null);
        var tab_order: [MAX_TAB_ORDER]core.NodeId = undefined;
        var len: usize = 0;
        collectTabOrderNode(arena, search_root, &tab_order, &len, 0);
        if (len == 0) return null;

        var cur_idx_opt: ?usize = null;
        if (self.focused_node) |cur| {
            for (tab_order[0..len], 0..) |item, i| {
                if (nodeIdEql(item, cur)) {
                    cur_idx_opt = i;
                    break;
                }
            }
            if (cur_idx_opt == null) {
                if (self.enclosingRovingGroup(arena)) |rg| {
                    for (tab_order[0..len], 0..) |item, i| {
                        if (arena.isDescendantOrSelf(rg, item)) {
                            cur_idx_opt = i;
                            break;
                        }
                    }
                }
            }
        }

        const next_idx: usize = if (cur_idx_opt) |idx| blk: {
            if (forward) {
                break :blk (idx + 1) % len;
            } else {
                break :blk if (idx == 0) len - 1 else idx - 1;
            }
        } else (if (forward) 0 else len - 1);

        const target = tab_order[next_idx];
        self.setFocusedByKeyboard(arena, target);
        return self.focused_node;
    }

    pub fn focusNext(self: *FocusManager, arena: *core.LayoutArena) ?core.NodeId {
        return self.stepFocus(arena, true);
    }

    pub fn focusPrev(self: *FocusManager, arena: *core.LayoutArena) ?core.NodeId {
        return self.stepFocus(arena, false);
    }

    pub fn moveInRovingGroup(self: *FocusManager, arena: *core.LayoutArena, delta: i32) ?core.NodeId {
        self.validate(arena);
        const cur_id = self.focused_node orelse return null;
        if (!arena.isFocusable(cur_id)) return null;
        const rg = self.enclosingRovingGroup(arena) orelse return null;
        if (arena.isDisabled(rg)) return null;

        var items: [MAX_TAB_ORDER]core.NodeId = undefined;
        var len: usize = 0;
        collectFocusableDescendants(arena, rg, &items, &len, 0);
        if (len == 0) return null;

        var cur_idx_opt: ?usize = null;
        for (items[0..len], 0..) |item, i| {
            if (nodeIdEql(item, cur_id)) {
                cur_idx_opt = i;
                break;
            }
        }
        const cur_idx = cur_idx_opt orelse return null;
        const len_i: i64 = @intCast(len);
        const raw: i64 = @as(i64, @intCast(cur_idx)) + @as(i64, delta);
        const next_idx: usize = @intCast(@mod(raw, len_i));
        const target = items[next_idx];

        self.setFocusedByKeyboard(arena, target);
        return self.focused_node;
    }
};
