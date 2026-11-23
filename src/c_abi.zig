const std = @import("std");
const core = @import("core.zig");
const events = @import("events.zig");

pub const ZigguiContext = opaque {};

pub const ZigguiRect = extern struct {
    x: f32,
    y: f32,
    w: f32,
    h: f32,
};

pub const ZigguiQuad = core.QuadInstance;

pub const ZigguiEventKind = enum(u32) {
    none = 0,
    clicked = 1,
    toggled = 2,
    changed_f32 = 3,
    hover_changed = 4,
    scrolled = 5,
    submitted = 6,
    shortcut = 7,
};

pub const ZigguiEvent = extern struct {
    kind: ZigguiEventKind,
    node_id: u32,
    bool_val: bool,
    _pad0: [3]u8 = .{ 0, 0, 0 },
    f32_val: f32,
    dx: f32,
    dy: f32,
    key: u32,
    mods: u32,
    codepoint: u32,
    test_id: [64]u8,
    test_id_len: u32,
};

comptime {
    if (@sizeOf(ZigguiRect) != 16) @compileError("ZigguiRect must be 16 bytes");
    if (@alignOf(ZigguiRect) != 4) @compileError("ZigguiRect must be 4-byte aligned");
    if (@offsetOf(ZigguiRect, "x") != 0) @compileError("ZigguiRect.x offset mismatch");
    if (@offsetOf(ZigguiRect, "y") != 4) @compileError("ZigguiRect.y offset mismatch");
    if (@offsetOf(ZigguiRect, "w") != 8) @compileError("ZigguiRect.w offset mismatch");
    if (@offsetOf(ZigguiRect, "h") != 12) @compileError("ZigguiRect.h offset mismatch");

    if (@sizeOf(ZigguiQuad) != 96) @compileError("ZigguiQuad must be 96 bytes");
    if (@alignOf(ZigguiQuad) != 4) @compileError("ZigguiQuad must be 4-byte aligned");
    if (@offsetOf(ZigguiQuad, "pos_size") != 0) @compileError("ZigguiQuad.pos_size offset mismatch");
    if (@offsetOf(ZigguiQuad, "uv_rect") != 16) @compileError("ZigguiQuad.uv_rect offset mismatch");
    if (@offsetOf(ZigguiQuad, "color") != 32) @compileError("ZigguiQuad.color offset mismatch");
    if (@offsetOf(ZigguiQuad, "border_color") != 48) @compileError("ZigguiQuad.border_color offset mismatch");
    if (@offsetOf(ZigguiQuad, "params") != 64) @compileError("ZigguiQuad.params offset mismatch");
    if (@offsetOf(ZigguiQuad, "clip_rect") != 80) @compileError("ZigguiQuad.clip_rect offset mismatch");

    if (@sizeOf(ZigguiEvent) != 104) @compileError("ZigguiEvent must be 104 bytes");
    if (@alignOf(ZigguiEvent) != 4) @compileError("ZigguiEvent must be 4-byte aligned");
    if (@sizeOf(ZigguiEventKind) != 4) @compileError("ZigguiEventKind must be 4 bytes");
    if (@offsetOf(ZigguiEvent, "kind") != 0) @compileError("ZigguiEvent.kind offset mismatch");
    if (@offsetOf(ZigguiEvent, "node_id") != 4) @compileError("ZigguiEvent.node_id offset mismatch");
    if (@offsetOf(ZigguiEvent, "bool_val") != 8) @compileError("ZigguiEvent.bool_val offset mismatch");
    if (@offsetOf(ZigguiEvent, "_pad0") != 9) @compileError("ZigguiEvent._pad0 offset mismatch");
    if (@offsetOf(ZigguiEvent, "f32_val") != 12) @compileError("ZigguiEvent.f32_val offset mismatch");
    if (@offsetOf(ZigguiEvent, "dx") != 16) @compileError("ZigguiEvent.dx offset mismatch");
    if (@offsetOf(ZigguiEvent, "dy") != 20) @compileError("ZigguiEvent.dy offset mismatch");
    if (@offsetOf(ZigguiEvent, "key") != 24) @compileError("ZigguiEvent.key offset mismatch");
    if (@offsetOf(ZigguiEvent, "mods") != 28) @compileError("ZigguiEvent.mods offset mismatch");
    if (@offsetOf(ZigguiEvent, "codepoint") != 32) @compileError("ZigguiEvent.codepoint offset mismatch");
    if (@offsetOf(ZigguiEvent, "test_id") != 36) @compileError("ZigguiEvent.test_id offset mismatch");
    if (@offsetOf(ZigguiEvent, "test_id_len") != 100) @compileError("ZigguiEvent.test_id_len offset mismatch");
}

const MAX_CSTR_LEN: usize = 1024;

const Impl = struct {
    arena: core.LayoutArena,
    router: events.EventRouter,
    string_arena: std.heap.ArenaAllocator,
    viewport_w: f32,
    viewport_h: f32,
    scale: f32,

    fn fromCtx(ctx: ?*ZigguiContext) ?*Impl {
        const ptr = ctx orelse return null;
        return @ptrCast(@alignCast(ptr));
    }

    fn dupeCStr(self: *Impl, cstr: ?[*:0]const u8) error{OutOfMemory}![]const u8 {
        const ptr = cstr orelse return "";
        var len: usize = 0;
        while (len < MAX_CSTR_LEN and ptr[len] != 0) : (len += 1) {}
        if (len == 0) return "";
        return self.string_arena.allocator().dupe(u8, ptr[0..len]);
    }

    fn addWidget(self: *Impl, parent_id: u32, desc: core.NodeDesc) u32 {
        const id = if (parent_id == 0)
            self.arena.addNode(desc) catch return 0
        else blk: {
            const pid: core.NodeId = @bitCast(parent_id);
            break :blk self.arena.addChild(pid, desc) catch return 0;
        };
        return @bitCast(id);
    }

    fn validateParent(self: *const Impl, parent_id: u32) bool {
        if (self.arena.nodes.len >= std.math.maxInt(u16)) return false;
        if (parent_id == 0) return self.arena.root_index == null;
        const pid: core.NodeId = @bitCast(parent_id);
        return self.arena.getKind(pid) != null;
    }
};

fn isPositiveFinite(v: f32) bool {
    return std.math.isFinite(v) and v > 0.0;
}

fn copyTestId(out: *ZigguiEvent, src: []const u8) void {
    const max_len = @min(src.len, out.test_id.len - 1);
    var len: usize = 0;
    while (len < max_len) {
        const cp_len = std.unicode.utf8ByteSequenceLength(src[len]) catch break;
        if (len + cp_len > max_len) break;
        if (cp_len > 1) {
            _ = std.unicode.utf8Decode(src[len .. len + cp_len]) catch break;
        }
        len += cp_len;
    }
    if (len > 0) {
        @memcpy(out.test_id[0..len], src[0..len]);
    }
    out.test_id[len] = 0;
    out.test_id_len = @intCast(len);
}

fn keyFromU32(raw: u32) ?events.Key {
    return switch (raw) {
        0 => .escape,
        1 => .enter,
        2 => .tab,
        3 => .space,
        4 => .backspace,
        5 => .up,
        6 => .down,
        7 => .left,
        8 => .right,
        9 => .home,
        10 => .end,
        11 => .char,
        else => null,
    };
}

fn keyToU32(k: events.Key) u32 {
    return switch (k) {
        .escape => 0,
        .enter => 1,
        .tab => 2,
        .space => 3,
        .backspace => 4,
        .up => 5,
        .down => 6,
        .left => 7,
        .right => 8,
        .home => 9,
        .end => 10,
        .char => 11,
    };
}

fn modsFromU32(raw: u32) events.Modifiers {
    return .{
        .ctrl = (raw & 1) != 0,
        .shift = (raw & 2) != 0,
        .alt = (raw & 4) != 0,
        .super = (raw & 8) != 0,
    };
}

fn modsToU32(m: events.Modifiers) u32 {
    var out: u32 = 0;
    if (m.ctrl) out |= 1;
    if (m.shift) out |= 2;
    if (m.alt) out |= 4;
    if (m.super) out |= 8;
    return out;
}

pub export fn ziggui_create(viewport_w: f32, viewport_h: f32, scale: f32) callconv(.c) ?*ZigguiContext {
    if (!isPositiveFinite(viewport_w) or !isPositiveFinite(viewport_h) or !isPositiveFinite(scale)) {
        return null;
    }
    const impl = std.heap.c_allocator.create(Impl) catch return null;
    impl.* = .{
        .arena = core.LayoutArena.init(std.heap.c_allocator),
        .router = events.EventRouter.init(),
        .string_arena = std.heap.ArenaAllocator.init(std.heap.c_allocator),
        .viewport_w = viewport_w,
        .viewport_h = viewport_h,
        .scale = scale,
    };
    return @ptrCast(impl);
}

pub export fn ziggui_destroy(ctx: ?*ZigguiContext) callconv(.c) void {
    const impl = Impl.fromCtx(ctx) orelse return;
    impl.arena.deinit();
    impl.string_arena.deinit();
    std.heap.c_allocator.destroy(impl);
}

pub export fn ziggui_reset(ctx: ?*ZigguiContext) callconv(.c) void {
    const impl = Impl.fromCtx(ctx) orelse return;
    impl.router = events.EventRouter.init();
    impl.arena.reset();
    _ = impl.string_arena.reset(.free_all);
}

pub export fn ziggui_set_viewport(ctx: ?*ZigguiContext, w: f32, h: f32, scale: f32) callconv(.c) void {
    const impl = Impl.fromCtx(ctx) orelse return;
    if (!isPositiveFinite(w) or !isPositiveFinite(h) or !isPositiveFinite(scale)) return;
    impl.viewport_w = w;
    impl.viewport_h = h;
    impl.scale = scale;
    impl.arena.layout(w, h);
    impl.arena.requestRedraw();
}

pub export fn ziggui_add_vstack(
    ctx: ?*ZigguiContext,
    parent_id: u32,
    test_id: ?[*:0]const u8,
    padding: f32,
    gap: f32,
) callconv(.c) u32 {
    const impl = Impl.fromCtx(ctx) orelse return 0;
    if (!impl.validateParent(parent_id)) return 0;
    const tid = impl.dupeCStr(test_id) catch return 0;
    return impl.addWidget(parent_id, .{
        .kind = .vstack,
        .role = .container,
        .test_id = tid,
        .padding = padding,
        .gap = gap,
        .fill = if (parent_id == 0) core.Nord.polar_night_0 else core.Nord.transparent,
    });
}

pub export fn ziggui_add_hstack(
    ctx: ?*ZigguiContext,
    parent_id: u32,
    test_id: ?[*:0]const u8,
    padding: f32,
    gap: f32,
) callconv(.c) u32 {
    const impl = Impl.fromCtx(ctx) orelse return 0;
    if (!impl.validateParent(parent_id)) return 0;
    const tid = impl.dupeCStr(test_id) catch return 0;
    return impl.addWidget(parent_id, .{
        .kind = .hstack,
        .role = .container,
        .test_id = tid,
        .padding = padding,
        .gap = gap,
        .fill = if (parent_id == 0) core.Nord.polar_night_0 else core.Nord.transparent,
    });
}

pub export fn ziggui_add_card(
    ctx: ?*ZigguiContext,
    parent_id: u32,
    test_id: ?[*:0]const u8,
    label: ?[*:0]const u8,
    height: f32,
) callconv(.c) u32 {
    const impl = Impl.fromCtx(ctx) orelse return 0;
    if (!impl.validateParent(parent_id)) return 0;
    const tid = impl.dupeCStr(test_id) catch return 0;
    const lbl = impl.dupeCStr(label) catch return 0;
    return impl.addWidget(parent_id, .{
        .kind = .card,
        .role = .panel,
        .test_id = tid,
        .label = lbl,
        .height = height,
        .corner_radius = 12.0,
        .border_width = 1.0,
        .fill = core.Nord.polar_night_1,
        .border = core.Nord.polar_night_3,
    });
}

pub export fn ziggui_add_toggle(
    ctx: ?*ZigguiContext,
    parent_id: u32,
    test_id: ?[*:0]const u8,
    label: ?[*:0]const u8,
    height: f32,
    checked: bool,
) callconv(.c) u32 {
    const impl = Impl.fromCtx(ctx) orelse return 0;
    if (!impl.validateParent(parent_id)) return 0;
    const tid = impl.dupeCStr(test_id) catch return 0;
    const lbl = impl.dupeCStr(label) catch return 0;
    return impl.addWidget(parent_id, .{
        .kind = .toggle,
        .role = .switch_control,
        .test_id = tid,
        .label = lbl,
        .height = height,
        .corner_radius = 12.0,
        .border_width = 1.5,
        .fill = core.Nord.polar_night_1,
        .border = core.Nord.polar_night_3,
        .accent = core.Nord.frost_1,
        .checked = checked,
    });
}

pub export fn ziggui_add_slider(
    ctx: ?*ZigguiContext,
    parent_id: u32,
    test_id: ?[*:0]const u8,
    label: ?[*:0]const u8,
    height: f32,
    value: f32,
) callconv(.c) u32 {
    const impl = Impl.fromCtx(ctx) orelse return 0;
    if (!impl.validateParent(parent_id)) return 0;
    const tid = impl.dupeCStr(test_id) catch return 0;
    const lbl = impl.dupeCStr(label) catch return 0;
    return impl.addWidget(parent_id, .{
        .kind = .slider,
        .role = .slider,
        .test_id = tid,
        .label = lbl,
        .height = height,
        .corner_radius = 12.0,
        .border_width = 1.0,
        .fill = core.Nord.polar_night_1,
        .border = core.Nord.polar_night_3,
        .accent = core.Nord.frost_1,
        .slider_val = value,
    });
}

pub export fn ziggui_layout(ctx: ?*ZigguiContext) callconv(.c) void {
    const impl = Impl.fromCtx(ctx) orelse return;
    impl.arena.layout(impl.viewport_w, impl.viewport_h);
}

pub export fn ziggui_get_rect(ctx: ?*ZigguiContext, node_id: u32, out_rect: ?*ZigguiRect) callconv(.c) bool {
    const impl = Impl.fromCtx(ctx) orelse return false;
    const dst = out_rect orelse return false;
    if (node_id == 0) return false;
    const id: core.NodeId = @bitCast(node_id);
    const r = impl.arena.getRect(id) orelse return false;
    dst.* = .{
        .x = r.x,
        .y = r.y,
        .w = r.w,
        .h = r.h,
    };
    return true;
}

pub export fn ziggui_pointer_down(
    ctx: ?*ZigguiContext,
    pointer_id: i32,
    x: f32,
    y: f32,
    is_touch: bool,
) callconv(.c) void {
    const impl = Impl.fromCtx(ctx) orelse return;
    impl.router.dispatch(&impl.arena, .{ .pointer_down = .{
        .pointer_id = pointer_id,
        .x = x,
        .y = y,
        .button = .primary,
        .is_touch = is_touch,
    } });
}

pub export fn ziggui_pointer_move(
    ctx: ?*ZigguiContext,
    pointer_id: i32,
    x: f32,
    y: f32,
    is_touch: bool,
) callconv(.c) void {
    const impl = Impl.fromCtx(ctx) orelse return;
    impl.router.dispatch(&impl.arena, .{ .pointer_move = .{
        .pointer_id = pointer_id,
        .x = x,
        .y = y,
        .is_touch = is_touch,
    } });
}

pub export fn ziggui_pointer_up(
    ctx: ?*ZigguiContext,
    pointer_id: i32,
    x: f32,
    y: f32,
    is_touch: bool,
) callconv(.c) void {
    const impl = Impl.fromCtx(ctx) orelse return;
    impl.router.dispatch(&impl.arena, .{ .pointer_up = .{
        .pointer_id = pointer_id,
        .x = x,
        .y = y,
        .button = .primary,
        .is_touch = is_touch,
    } });
}

pub export fn ziggui_pointer_cancel(ctx: ?*ZigguiContext, pointer_id: i32) callconv(.c) void {
    const impl = Impl.fromCtx(ctx) orelse return;
    impl.router.dispatch(&impl.arena, .{ .pointer_cancel = .{
        .pointer_id = pointer_id,
    } });
}

pub export fn ziggui_wheel(ctx: ?*ZigguiContext, x: f32, y: f32, dx: f32, dy: f32) callconv(.c) void {
    const impl = Impl.fromCtx(ctx) orelse return;
    impl.router.dispatch(&impl.arena, .{ .wheel = .{
        .x = x,
        .y = y,
        .dx = dx,
        .dy = dy,
    } });
}

pub export fn ziggui_key_down(
    ctx: ?*ZigguiContext,
    key: u32,
    mods: u32,
    codepoint: u32,
    repeat: bool,
) callconv(.c) void {
    const impl = Impl.fromCtx(ctx) orelse return;
    const k = keyFromU32(key) orelse return;
    const cp: u21 = if (codepoint <= 0x10FFFF and (codepoint < 0xD800 or codepoint > 0xDFFF))
        @intCast(codepoint)
    else
        0;
    impl.router.dispatch(&impl.arena, .{ .key_down = .{
        .key = k,
        .mods = modsFromU32(mods),
        .repeat = repeat,
        .codepoint = cp,
    } });
}

pub export fn ziggui_poll_event(ctx: ?*ZigguiContext, out_ev: ?*ZigguiEvent) callconv(.c) bool {
    const impl = Impl.fromCtx(ctx) orelse return false;
    const dst = out_ev orelse return false;
    const ev = impl.router.nextEvent() orelse return false;

    dst.* = .{
        .kind = .none,
        .node_id = 0,
        .bool_val = false,
        .f32_val = 0.0,
        .dx = 0.0,
        .dy = 0.0,
        .key = 0,
        .mods = 0,
        .codepoint = 0,
        .test_id = [_]u8{0} ** 64,
        .test_id_len = 0,
    };

    switch (ev) {
        .clicked => |c| {
            dst.kind = .clicked;
            dst.node_id = @bitCast(c.id);
            copyTestId(dst, c.test_id);
        },
        .toggled => |t| {
            dst.kind = .toggled;
            dst.node_id = @bitCast(t.id);
            dst.bool_val = t.checked;
            copyTestId(dst, t.test_id);
        },
        .changed_f32 => |c| {
            dst.kind = .changed_f32;
            dst.node_id = @bitCast(c.id);
            dst.f32_val = c.value;
            copyTestId(dst, c.test_id);
        },
        .hover_changed => |h| {
            dst.kind = .hover_changed;
            dst.node_id = @bitCast(h.id);
            dst.bool_val = h.hovered;
            copyTestId(dst, h.test_id);
        },
        .scrolled => |s| {
            dst.kind = .scrolled;
            dst.node_id = @bitCast(s.id);
            dst.dx = s.dx;
            dst.dy = s.dy;
            copyTestId(dst, s.test_id);
        },
        .submitted => |s| {
            dst.kind = .submitted;
            dst.node_id = if (s.id) |id| @bitCast(id) else 0;
            copyTestId(dst, s.test_id);
        },
        .shortcut => |s| {
            dst.kind = .shortcut;
            dst.key = keyToU32(s.key);
            dst.mods = modsToU32(s.mods);
            dst.codepoint = @intCast(s.codepoint);
        },
    }
    return true;
}

pub export fn ziggui_needs_redraw(ctx: ?*ZigguiContext) callconv(.c) bool {
    const impl = Impl.fromCtx(ctx) orelse return false;
    return impl.arena.needsRedraw();
}

pub export fn ziggui_consume_redraw(ctx: ?*ZigguiContext) callconv(.c) void {
    const impl = Impl.fromCtx(ctx) orelse return;
    impl.arena.consumeRedraw();
}

pub export fn ziggui_emit_quads(
    ctx: ?*ZigguiContext,
    out_buf: ?[*]ZigguiQuad,
    cap: usize,
) callconv(.c) usize {
    const impl = Impl.fromCtx(ctx) orelse return 0;
    const buf_ptr = out_buf orelse return 0;
    if (cap == 0) return 0;
    const safe_cap = @min(cap, @as(usize, std.math.maxInt(u16)) * 4);
    return impl.arena.emitQuads(buf_ptr[0..safe_cap], impl.scale);
}
