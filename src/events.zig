const std = @import("std");
const core = @import("core.zig");

pub const PointerButton = enum {
    primary,
    secondary,
    middle,
};

pub const Modifiers = packed struct {
    ctrl: bool = false,
    shift: bool = false,
    alt: bool = false,
    super: bool = false,
};

pub const Key = enum {
    escape,
    enter,
    tab,
    space,
    backspace,
    up,
    down,
    left,
    right,
    home,
    end,
    char,
};

pub const InputEvent = union(enum) {
    pointer_down: struct {
        pointer_id: i32,
        x: f32,
        y: f32,
        button: PointerButton = .primary,
        is_touch: bool = false,
    },
    pointer_move: struct {
        pointer_id: i32,
        x: f32,
        y: f32,
        is_touch: bool = false,
    },
    pointer_up: struct {
        pointer_id: i32,
        x: f32,
        y: f32,
        button: PointerButton = .primary,
        is_touch: bool = false,
    },
    pointer_cancel: struct {
        pointer_id: i32,
    },
    wheel: struct {
        x: f32,
        y: f32,
        dx: f32,
        dy: f32,
    },
    key_down: struct {
        key: Key,
        mods: Modifiers = .{},
        repeat: bool = false,
        codepoint: u21 = 0,
    },
    key_up: struct {
        key: Key,
        mods: Modifiers = .{},
    },
    text_input: struct {
        codepoint: u21,
    },
    focus_lost: void,
};

pub const UiEvent = union(enum) {
    clicked: struct { id: core.NodeId, test_id: []const u8 },
    toggled: struct { id: core.NodeId, test_id: []const u8, checked: bool },
    changed_f32: struct { id: core.NodeId, test_id: []const u8, value: f32 },
    hover_changed: struct { id: core.NodeId, test_id: []const u8, hovered: bool },
    scrolled: struct { id: core.NodeId, test_id: []const u8, dx: f32, dy: f32 },
    submitted: struct { id: ?core.NodeId, test_id: []const u8 },
    shortcut: struct { key: Key, mods: Modifiers, codepoint: u21 = 0 },
};

fn nodeIdEql(a: core.NodeId, b: core.NodeId) bool {
    return a.index == b.index and a.gen == b.gen;
}

fn nodeIdOptEql(a: ?core.NodeId, b: ?core.NodeId) bool {
    if (a == null and b == null) return true;
    if (a == null or b == null) return false;
    return nodeIdEql(a.?, b.?);
}

pub const EventRouter = struct {
    pub const TOUCH_DRAG_SLOP: f32 = 8.0;
    pub const MOUSE_DRAG_SLOP: f32 = 4.0;
    pub const QUEUE_CAPACITY: usize = 128;

    queue: [QUEUE_CAPACITY]UiEvent = undefined,
    queue_len: usize = 0,
    dropped_events: usize = 0,

    captured_node: ?core.NodeId = null,
    captured_pointer_id: ?i32 = null,
    pressed_node: ?core.NodeId = null,
    pressed_pointer_id: ?i32 = null,
    press_x: f32 = 0,
    press_y: f32 = 0,
    press_cancelled: bool = false,
    hovered_node: ?core.NodeId = null,
    focused_node: ?core.NodeId = null,

    pub fn init() EventRouter {
        return .{};
    }

    pub fn pollEvents(self: *const EventRouter) []const UiEvent {
        return self.queue[0..self.queue_len];
    }

    pub fn clearEvents(self: *EventRouter) void {
        self.queue_len = 0;
    }

    pub fn nextEvent(self: *EventRouter) ?UiEvent {
        if (self.queue_len == 0) return null;
        const first = self.queue[0];
        if (self.queue_len > 1) {
            std.mem.copyForwards(UiEvent, self.queue[0 .. self.queue_len - 1], self.queue[1..self.queue_len]);
        }
        self.queue_len -= 1;
        return first;
    }

    fn pushEvent(self: *EventRouter, ev: UiEvent) void {
        if (self.queue_len < self.queue.len) {
            self.queue[self.queue_len] = ev;
            self.queue_len += 1;
        } else {
            self.dropped_events += 1;
        }
    }

    fn validateHandles(self: *EventRouter, arena: *const core.LayoutArena) void {
        if (self.captured_node) |id| {
            if (arena.getKind(id) == null) {
                self.captured_node = null;
                self.captured_pointer_id = null;
            }
        } else {
            self.captured_pointer_id = null;
        }

        if (self.pressed_node) |id| {
            if (arena.getKind(id) == null) {
                self.pressed_node = null;
                self.pressed_pointer_id = null;
                self.press_cancelled = false;
            }
        } else {
            self.pressed_pointer_id = null;
            self.press_cancelled = false;
        }

        if (self.hovered_node) |id| {
            if (arena.getKind(id) == null) {
                self.hovered_node = null;
            }
        }

        if (self.focused_node) |id| {
            if (arena.getKind(id) == null) {
                self.focused_node = null;
            }
        }
    }

    fn updateSlider(self: *EventRouter, arena: *core.LayoutArena, id: core.NodeId, x: f32) void {
        const prev = arena.getSliderValue(id);
        if (arena.setSliderFromX(id, x)) |val| {
            if (prev == null or val != prev.?) {
                self.pushEvent(.{ .changed_f32 = .{
                    .id = id,
                    .test_id = arena.getTestId(id) orelse "",
                    .value = val,
                } });
            }
        }
    }

    fn resolvePressTarget(arena: *const core.LayoutArena, start_id: core.NodeId) ?core.NodeId {
        var cur_opt: ?core.NodeId = start_id;
        while (cur_opt) |cur| {
            const kind = arena.getKind(cur) orelse return null;
            switch (kind) {
                .slider, .toggle, .card => return cur,
                .bar, .vstack, .hstack, .zstack => cur_opt = arena.getParent(cur),
            }
        }
        return null;
    }

    fn updateHover(self: *EventRouter, arena: *const core.LayoutArena, x: f32, y: f32) void {
        const new_hover = arena.hitTest(x, y);
        if (nodeIdOptEql(self.hovered_node, new_hover)) return;

        if (self.hovered_node) |old_id| {
            self.pushEvent(.{ .hover_changed = .{
                .id = old_id,
                .test_id = arena.getTestId(old_id) orelse "",
                .hovered = false,
            } });
        }
        self.hovered_node = new_hover;
        if (new_hover) |new_id| {
            self.pushEvent(.{ .hover_changed = .{
                .id = new_id,
                .test_id = arena.getTestId(new_id) orelse "",
                .hovered = true,
            } });
        }
    }

    fn clearHover(self: *EventRouter, arena: *const core.LayoutArena) void {
        if (self.hovered_node) |old_id| {
            self.hovered_node = null;
            if (arena.getKind(old_id) != null) {
                self.pushEvent(.{ .hover_changed = .{
                    .id = old_id,
                    .test_id = arena.getTestId(old_id) orelse "",
                    .hovered = false,
                } });
            }
        }
    }

    fn exceedsDragSlop(self: *const EventRouter, x: f32, y: f32, is_touch: bool) bool {
        const slop = if (is_touch) TOUCH_DRAG_SLOP else MOUSE_DRAG_SLOP;
        const dx = x - self.press_x;
        const dy = y - self.press_y;
        return (dx * dx + dy * dy) > (slop * slop);
    }

    pub fn dispatch(self: *EventRouter, arena: *core.LayoutArena, ev: InputEvent) void {
        self.validateHandles(arena);

        switch (ev) {
            .pointer_down => |pd| {
                if (!std.math.isFinite(pd.x) or !std.math.isFinite(pd.y)) return;
                if (self.captured_pointer_id) |cpid| {
                    if (cpid != pd.pointer_id) return;
                }
                if (self.pressed_pointer_id) |ppid| {
                    if (ppid != pd.pointer_id) return;
                }
                if (pd.button != .primary) return;

                if (self.captured_pointer_id == pd.pointer_id or self.pressed_pointer_id == pd.pointer_id) {
                    self.captured_node = null;
                    self.captured_pointer_id = null;
                    self.pressed_node = null;
                    self.pressed_pointer_id = null;
                    self.press_cancelled = false;
                }

                const hit_id = arena.hitTest(pd.x, pd.y) orelse {
                    self.focused_node = null;
                    return;
                };
                const target_id = resolvePressTarget(arena, hit_id) orelse {
                    self.focused_node = null;
                    return;
                };
                const kind = arena.getKind(target_id) orelse return;
                switch (kind) {
                    .slider => {
                        self.focused_node = target_id;
                        self.captured_node = target_id;
                        self.captured_pointer_id = pd.pointer_id;
                        self.pressed_node = target_id;
                        self.pressed_pointer_id = pd.pointer_id;
                        self.press_x = pd.x;
                        self.press_y = pd.y;
                        self.press_cancelled = false;
                        self.updateSlider(arena, target_id, pd.x);
                    },
                    .toggle, .card => {
                        self.focused_node = target_id;
                        self.pressed_node = target_id;
                        self.pressed_pointer_id = pd.pointer_id;
                        self.press_x = pd.x;
                        self.press_y = pd.y;
                        self.press_cancelled = false;
                    },
                    else => {
                        self.focused_node = null;
                    },
                }
            },
            .pointer_move => |pm| {
                if (!std.math.isFinite(pm.x) or !std.math.isFinite(pm.y)) return;
                if (self.captured_pointer_id) |cpid| {
                    if (cpid != pm.pointer_id) return;
                    if (self.captured_node) |cap_id| {
                        if (arena.getKind(cap_id) == .slider) {
                            self.updateSlider(arena, cap_id, pm.x);
                        }
                    }
                    return;
                }

                if (self.pressed_pointer_id) |ppid| {
                    if (ppid != pm.pointer_id) return;
                    if (!self.press_cancelled and self.exceedsDragSlop(pm.x, pm.y, pm.is_touch)) {
                        self.press_cancelled = true;
                    }
                }

                if (!pm.is_touch) {
                    self.updateHover(arena, pm.x, pm.y);
                }
            },
            .pointer_up => |pu| {
                if (pu.button != .primary) return;
                if (!std.math.isFinite(pu.x) or !std.math.isFinite(pu.y)) {
                    if (self.captured_pointer_id == pu.pointer_id) {
                        self.captured_node = null;
                        self.captured_pointer_id = null;
                    }
                    if (self.pressed_pointer_id == pu.pointer_id) {
                        self.pressed_node = null;
                        self.pressed_pointer_id = null;
                        self.press_cancelled = false;
                    }
                    return;
                }

                if (self.captured_pointer_id) |cpid| {
                    if (cpid != pu.pointer_id) return;
                    if (self.captured_node) |cap_id| {
                        if (arena.getKind(cap_id) == .slider) {
                            self.updateSlider(arena, cap_id, pu.x);
                        }
                    }
                    self.captured_node = null;
                    self.captured_pointer_id = null;
                    self.pressed_node = null;
                    self.pressed_pointer_id = null;
                    self.press_cancelled = false;
                    if (!pu.is_touch) {
                        self.updateHover(arena, pu.x, pu.y);
                    }
                    return;
                }

                if (self.pressed_pointer_id) |ppid| {
                    if (ppid != pu.pointer_id) return;
                    const p_id = self.pressed_node;
                    const was_cancelled = self.press_cancelled or self.exceedsDragSlop(pu.x, pu.y, pu.is_touch);
                    self.pressed_node = null;
                    self.pressed_pointer_id = null;
                    self.press_cancelled = false;

                    if (was_cancelled) return;
                    const target_id = p_id orelse return;
                    const hit_id = arena.hitTest(pu.x, pu.y) orelse return;
                    const resolved_id = resolvePressTarget(arena, hit_id) orelse return;
                    if (!nodeIdEql(resolved_id, target_id)) return;

                    const kind = arena.getKind(target_id) orelse return;
                    switch (kind) {
                        .toggle => {
                            if (arena.toggleNode(target_id)) |checked| {
                                self.pushEvent(.{ .toggled = .{
                                    .id = target_id,
                                    .test_id = arena.getTestId(target_id) orelse "",
                                    .checked = checked,
                                } });
                            }
                        },
                        .card => {
                            self.pushEvent(.{ .clicked = .{
                                .id = target_id,
                                .test_id = arena.getTestId(target_id) orelse "",
                            } });
                        },
                        else => {},
                    }
                }
            },
            .pointer_cancel => |pc| {
                if (self.captured_pointer_id) |cpid| {
                    if (cpid == pc.pointer_id) {
                        self.captured_node = null;
                        self.captured_pointer_id = null;
                    }
                }
                if (self.pressed_pointer_id) |ppid| {
                    if (ppid == pc.pointer_id) {
                        self.pressed_node = null;
                        self.pressed_pointer_id = null;
                        self.press_cancelled = false;
                    }
                }
            },
            .wheel => |w| {
                if (!std.math.isFinite(w.x) or !std.math.isFinite(w.y) or
                    !std.math.isFinite(w.dx) or !std.math.isFinite(w.dy))
                {
                    return;
                }
                const hit_id = arena.hitTest(w.x, w.y) orelse return;
                self.pushEvent(.{ .scrolled = .{
                    .id = hit_id,
                    .test_id = arena.getTestId(hit_id) orelse "",
                    .dx = w.dx,
                    .dy = w.dy,
                } });
            },
            .key_down => |kd| {
                if (kd.repeat) return;
                if (kd.key == .escape or kd.mods.ctrl or kd.mods.alt or kd.mods.super) {
                    self.pushEvent(.{ .shortcut = .{
                        .key = kd.key,
                        .mods = kd.mods,
                        .codepoint = kd.codepoint,
                    } });
                } else if (kd.key == .enter) {
                    const fid = self.focused_node;
                    const tid = if (fid) |id| (arena.getTestId(id) orelse "") else "";
                    self.pushEvent(.{ .submitted = .{
                        .id = fid,
                        .test_id = tid,
                    } });
                }
            },
            .key_up => {},
            .text_input => {},
            .focus_lost => {
                self.captured_node = null;
                self.captured_pointer_id = null;
                self.pressed_node = null;
                self.pressed_pointer_id = null;
                self.press_cancelled = false;
                self.focused_node = null;
                self.clearHover(arena);
            },
        }
    }
};
