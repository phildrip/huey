const std = @import("std");
const core = @import("core.zig");
const tokens = @import("tokens.zig");
const wayland = @import("wayland.zig");
const overlay = @import("overlay.zig");
const multi_window = @import("multi_window.zig");
const text_edit = @import("text_edit.zig");
const focus = @import("focus.zig");
const image_atlas = @import("image_atlas.zig");

pub const WORKSPACE_COUNT: u8 = 5;
pub const MAX_LAUNCHER_VISIBLE: usize = 6;

pub const LauncherItem = struct {
    name: []const u8,
    command: []const u8,
    icon: image_atlas.BuiltinIcon,
};

pub const DEFAULT_LAUNCHER_ITEMS = [_]LauncherItem{
    .{ .name = "Terminal", .command = "foot", .icon = .settings },
    .{ .name = "Browser", .command = "firefox", .icon = .wifi },
    .{ .name = "Files", .command = "thunar", .icon = .search },
    .{ .name = "Audio Mixer", .command = "pavucontrol", .icon = .volume },
    .{ .name = "Bluetooth", .command = "blueman-manager", .icon = .bluetooth },
    .{ .name = "Lock Screen", .command = "swaylock", .icon = .lock },
    .{ .name = "Power & Battery", .command = "upower", .icon = .battery },
    .{ .name = "Settings", .command = "stratifi-settings", .icon = .settings },
};

const WS_TEST_IDS = [WORKSPACE_COUNT][]const u8{
    "ws-1",
    "ws-2",
    "ws-3",
    "ws-4",
    "ws-5",
};

const WS_LABELS = [WORKSPACE_COUNT][]const u8{
    "1",
    "2",
    "3",
    "4",
    "5",
};

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (needle.len > haystack.len) return false;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        var matched = true;
        for (0..needle.len) |j| {
            if (std.ascii.toLower(haystack[i + j]) != std.ascii.toLower(needle[j])) {
                matched = false;
                break;
            }
        }
        if (matched) return true;
    }
    return false;
}

pub fn matchesQuery(item: LauncherItem, query: []const u8) bool {
    if (query.len == 0) return true;
    return containsIgnoreCase(item.name, query) or containsIgnoreCase(item.command, query);
}

fn withAlpha(c: core.Color, alpha: f32) core.Color {
    return .{ c[0], c[1], c[2], alpha };
}

fn makeOutputState(
    id: u32,
    name_str: []const u8,
    logical_x: i32,
    logical_y: i32,
    logical_w: u32,
    logical_h: u32,
    scale_factor: f32,
    refresh_mhz: u32,
) multi_window.OutputState {
    var out = multi_window.OutputState{
        .id = id,
        .logical_x = logical_x,
        .logical_y = logical_y,
        .logical_w = logical_w,
        .logical_h = logical_h,
        .scale_factor = scale_factor,
        .refresh_mhz = refresh_mhz,
    };
    const copy_len = @min(name_str.len, out.name.len);
    @memcpy(out.name[0..copy_len], name_str[0..copy_len]);
    out.name_len = @intCast(copy_len);
    return out;
}

pub const StratifiShell = struct {
    allocator: std.mem.Allocator,
    arena: core.LayoutArena,
    token_table: tokens.TokenTable,
    overlays: overlay.OverlayManager,
    windows: multi_window.MultiWindowManager,
    editor: text_edit.TextEditor,
    focus_mgr: focus.FocusManager,
    atlas: image_atlas.ImageAtlas,
    quads: std.ArrayList(core.QuadInstance) = .empty,

    active_ws: u8 = 1,
    launcher_open: bool = false,
    last_output_h: f32 = 1080.0,
    active_title: []const u8 = "alacritty — ~/projects/zig-gui-spike",
    launcher_modal_node: ?core.NodeId = null,
    bar_menu_id: u32 = 0,
    primary_bar_win_id: u32 = 0,
    secondary_bar_win_id: u32 = 0,
    frame_idx: u64 = 1,

    last_bar_quads: usize = 0,
    last_launcher_quads: usize = 0,
    last_overlay_quads: usize = 0,
    matched_count: usize = DEFAULT_LAUNCHER_ITEMS.len,
    last_positioner_wire_len: usize = 0,
    positioner_wire_buf: [256]u8 = undefined,
    query_label_buf: [256]u8 = undefined,
    deinitialized: bool = false,

    pub fn init(allocator: std.mem.Allocator) !StratifiShell {
        var arena = core.LayoutArena.init(allocator);
        errdefer arena.deinit();

        var editor = text_edit.TextEditor.init(allocator);
        errdefer editor.deinit();

        var atlas = try image_atlas.ImageAtlas.init(allocator, 256, 256);
        errdefer atlas.deinit();

        var windows = multi_window.MultiWindowManager.init();
        try windows.addOutput(makeOutputState(1, "DP-1", 0, 0, 2560, 1440, 1.5, 144_000));
        try windows.addOutput(makeOutputState(2, "HDMI-A-1", 2560, 0, 1920, 1080, 1.0, 60_000));
        const primary_bar_win_id = try windows.createWindow(.layer_shell, 1, 2560.0, 32.0);
        const secondary_bar_win_id = try windows.createWindow(.layer_shell, 2, 1920.0, 32.0);

        return .{
            .allocator = allocator,
            .arena = arena,
            .token_table = tokens.TokenTable.nordDefault(),
            .overlays = overlay.OverlayManager.init(),
            .windows = windows,
            .editor = editor,
            .focus_mgr = focus.FocusManager.init(),
            .atlas = atlas,
            .primary_bar_win_id = primary_bar_win_id,
            .secondary_bar_win_id = secondary_bar_win_id,
        };
    }

    pub fn deinit(self: *StratifiShell) void {
        if (self.deinitialized) return;
        self.deinitialized = true;
        self.quads.deinit(self.allocator);
        self.atlas.deinit();
        self.editor.deinit();
        self.arena.deinit();
    }

    pub fn primaryScale(self: *const StratifiShell) f32 {
        if (self.windows.getWindow(self.primary_bar_win_id)) |win| {
            return win.scale_factor;
        }
        return 1.0;
    }

    pub fn query(self: *const StratifiShell) []const u8 {
        return self.editor.text();
    }

    pub fn toggleLauncher(self: *StratifiShell) void {
        self.launcher_open = !self.launcher_open;
        if (!self.launcher_open) {
            self.focus_mgr.popScope(&self.arena);
            self.launcher_modal_node = null;
        }
    }

    pub fn typeLauncherChar(self: *StratifiShell, ch: []const u8) !void {
        try self.editor.insert(ch);
    }

    pub fn backspaceLauncher(self: *StratifiShell) !void {
        try self.editor.backspace();
    }

    const FocusSnapshot = struct {
        const ScopeEntry = struct {
            container_tid: [64]u8 = undefined,
            container_len: usize = 0,
            saved_tid: [64]u8 = undefined,
            saved_len: usize = 0,
            trap: bool = false,
            saved_visible: bool = false,
        };

        scopes: [focus.MAX_SCOPES]ScopeEntry = undefined,
        scope_len: usize = 0,
        focused_tid: [64]u8 = undefined,
        focused_len: usize = 0,
        focused_visible: bool = false,
    };

    fn copyTestId(buf: *[64]u8, tid_opt: ?[]const u8) usize {
        const tid = tid_opt orelse return 0;
        if (tid.len == 0 or tid.len > buf.len) return 0;
        @memcpy(buf[0..tid.len], tid);
        return tid.len;
    }

    fn snapshotFocus(self: *const StratifiShell) FocusSnapshot {
        var snap = FocusSnapshot{};
        for (self.focus_mgr.scopes[0..self.focus_mgr.scope_len]) |s| {
            var entry = FocusSnapshot.ScopeEntry{
                .trap = s.trap,
                .saved_visible = s.saved_focus_visible,
            };
            entry.container_len = copyTestId(&entry.container_tid, self.arena.getTestId(s.container));
            if (entry.container_len == 0) continue;
            if (s.saved_focus) |sf| {
                entry.saved_len = copyTestId(&entry.saved_tid, self.arena.getTestId(sf));
            }
            snap.scopes[snap.scope_len] = entry;
            snap.scope_len += 1;
        }
        if (self.focus_mgr.focused()) |fid| {
            snap.focused_len = copyTestId(&snap.focused_tid, self.arena.getTestId(fid));
            snap.focused_visible = self.focus_mgr.isFocusVisible();
        }
        return snap;
    }

    fn restoreFocus(self: *StratifiShell, snap: *const FocusSnapshot) void {
        self.focus_mgr = focus.FocusManager.init();
        for (snap.scopes[0..snap.scope_len]) |se| {
            const new_container = self.arena.findByTestId(se.container_tid[0..se.container_len]) orelse continue;
            const new_saved: ?core.NodeId = if (se.saved_len > 0)
                self.arena.findByTestId(se.saved_tid[0..se.saved_len])
            else
                null;
            self.focus_mgr.scopes[self.focus_mgr.scope_len] = .{
                .container = new_container,
                .trap = se.trap,
                .saved_focus = new_saved,
                .saved_focus_visible = se.saved_visible,
            };
            self.focus_mgr.scope_len += 1;
        }
        if (snap.focused_len > 0) {
            if (self.arena.findByTestId(snap.focused_tid[0..snap.focused_len])) |new_f| {
                if (snap.focused_visible) {
                    self.focus_mgr.setFocusedByKeyboard(&self.arena, new_f);
                } else {
                    self.focus_mgr.setFocusedByPointer(&self.arena, new_f);
                }
            }
        }
        self.focus_mgr.validate(&self.arena);
    }

    pub fn openBarMenu(
        self: *StratifiShell,
        anchor_x: f32,
        output_w: f32,
        output_h: f32,
    ) !u32 {
        if (!std.math.isFinite(output_w) or output_w <= 0.0 or
            !std.math.isFinite(output_h) or output_h <= 0.0 or
            !std.math.isFinite(anchor_x))
        {
            return error.InvalidMenuBounds;
        }

        if (self.bar_menu_id != 0 and !self.overlays.isOpen(self.bar_menu_id)) {
            self.bar_menu_id = 0;
        }
        if (self.bar_menu_id != 0) {
            _ = self.overlays.close(self.bar_menu_id);
            self.bar_menu_id = 0;
        }

        const card_style = self.token_table.resolve(.card, .{});
        const anchor_w: f32 = 88.0;
        const bar_h: f32 = 32.0;
        const popup_w: f32 = 210.0;
        const popup_h: f32 = 168.0;

        const id = try self.overlays.open(.{
            .anchor = .{ .x = anchor_x, .y = 0.0, .w = anchor_w, .h = bar_h },
            .width = popup_w,
            .height = popup_h,
            .placement = .bottom_start,
            .gap = 4.0,
            .flip_x = true,
            .flip_y = true,
            .slide_x = true,
            .slide_y = true,
            .modal = true,
            .bg_color = card_style.fill,
            .border_color = self.token_table.border_focus.toSrgb(),
            .backdrop_color = .{ 0.0, 0.0, 0.0, 0.25 },
            .corner_radius = self.token_table.corner_radius_md,
            .border_width = self.token_table.border_width_default,
            .shadow_blur = self.token_table.shadow_md,
        }, output_w, output_h);
        errdefer _ = self.overlays.close(id);

        const pos_id = std.math.add(u32, 100, id) catch return error.OverlayIdOverflow;
        const popup_id = std.math.add(u32, 200, id) catch return error.OverlayIdOverflow;

        // Encode corresponding Wayland xdg_positioner + zwlr_layer_surface_v1.get_popup wire messages.
        var enc = wayland.WireEncoder.init(&self.positioner_wire_buf);
        const clamped_ax: i32 = @intFromFloat(std.math.clamp(@round(anchor_x), -32768.0, 32768.0));
        try overlay.encodeXdgPositioner(&enc, pos_id, .{
            .width = @intFromFloat(popup_w),
            .height = @intFromFloat(popup_h),
            .anchor_x = clamped_ax,
            .anchor_y = 0,
            .anchor_w = @intFromFloat(anchor_w),
            .anchor_h = @intFromFloat(bar_h),
            .anchor = .bottom_left,
            .gravity = .bottom_right,
            .constraint_adjustment = .{
                .flip_x = true,
                .flip_y = true,
                .slide_x = true,
                .slide_y = true,
            },
            .offset_x = 0,
            .offset_y = 4,
        });
        try overlay.encodeLayerGetPopup(&enc, 10, popup_id);
        self.last_positioner_wire_len = enc.written().len;
        self.bar_menu_id = id;
        self.last_output_h = output_h;

        return id;
    }

    pub fn buildBarScene(
        self: *StratifiShell,
        output_w: f32,
        bar_h: f32,
        active_ws: u8,
        launcher_open: bool,
    ) !usize {
        if (!std.math.isFinite(output_w) or output_w <= 0.0 or output_w > 1e6 or
            !std.math.isFinite(bar_h) or bar_h <= 0.0 or bar_h > 1e6)
        {
            return error.InvalidViewport;
        }
        if (active_ws == 0 or active_ws > WORKSPACE_COUNT) {
            return error.InvalidWorkspace;
        }

        const w = output_w;
        const bh = bar_h;

        if (self.bar_menu_id != 0 and !self.overlays.isOpen(self.bar_menu_id)) {
            self.bar_menu_id = 0;
        }

        const was_launcher_open = self.launcher_modal_node != null;
        if (!launcher_open and self.focus_mgr.topTrappedContainer(&self.arena) != null) {
            self.focus_mgr.popScope(&self.arena);
        }
        const focus_snap = self.snapshotFocus();

        self.active_ws = active_ws;
        self.launcher_open = launcher_open;

        const scale = self.primaryScale();
        const scene_h: f32 = if (launcher_open or self.overlays.activeCount() > 0)
            @max(bh * 18.0, self.last_output_h)
        else
            bh;

        self.arena.reset();
        self.launcher_modal_node = null;

        const bar_style = self.token_table.resolve(.bar, .{});
        const card_style = self.token_table.resolve(.card, .{});
        const surface_style = self.token_table.resolve(.surface, .{});
        const input_style = self.token_table.resolve(.input, .{ .focus_visible = true });
        const chip_style = self.token_table.resolve(.button, .{});

        const root = try self.arena.addNode(.{
            .kind = .zstack,
            .test_id = "shell-root",
        });

        // 1. Top zwlr_layer_shell status bar
        const bar_node = try self.arena.addChild(root, .{
            .kind = .hstack,
            .test_id = "status-bar",
            .height = bh,
            .padding = 4.0,
            .gap = 8.0,
            .align_items = .center,
            .fill = bar_style.fill,
            .border = bar_style.border,
            .border_width = bar_style.border_width,
            .corner_radius = 0.0,
            .shadow_blur = bar_style.shadow_blur,
        });

        // 1a. Workspace pills 1..5
        const ws_strip = try self.arena.addChild(bar_node, .{
            .kind = .hstack,
            .test_id = "workspace-strip",
            .width = 184.0,
            .height = @max(16.0, bh - 8.0),
            .gap = 4.0,
            .align_items = .center,
            .roving_group = true,
        });

        for (0..WORKSPACE_COUNT) |idx| {
            const ws_num: u8 = @intCast(idx + 1);
            const is_active = ws_num == self.active_ws;
            const pill_style = self.token_table.resolve(.button, .{ .checked = is_active });
            _ = try self.arena.addChild(ws_strip, .{
                .kind = .card,
                .test_id = WS_TEST_IDS[idx],
                .label = WS_LABELS[idx],
                .width = 32.0,
                .height = @max(14.0, bh - 10.0),
                .corner_radius = pill_style.corner_radius,
                .border_width = pill_style.border_width,
                .fill = pill_style.fill,
                .border = pill_style.border,
                .text_color = pill_style.text,
                .checked = is_active,
                .focusable = true,
            });
        }

        // 1b. Active window title
        _ = try self.arena.addChild(bar_node, .{
            .kind = .card,
            .test_id = "active-window",
            .label = self.active_title,
            .flex = 1.0,
            .height = @max(14.0, bh - 10.0),
            .corner_radius = self.token_table.corner_radius_sm,
            .border_width = 1.0,
            .fill = surface_style.fill,
            .border = card_style.border,
            .text_color = card_style.text,
        });

        // 1c. System status chips (WiFi, Volume, Battery, Menu)
        const chips_row = try self.arena.addChild(bar_node, .{
            .kind = .hstack,
            .test_id = "status-chips",
            .width = 264.0,
            .height = @max(16.0, bh - 8.0),
            .gap = 6.0,
            .align_items = .center,
            .justify = .end,
        });

        const chip_net = try self.arena.addChild(chips_row, .{
            .kind = .card,
            .test_id = "chip-net",
            .label = "WiFi",
            .width = 62.0,
            .height = @max(14.0, bh - 10.0),
            .corner_radius = self.token_table.corner_radius_sm,
            .border_width = chip_style.border_width,
            .fill = chip_style.fill,
            .border = chip_style.border,
            .text_color = chip_style.text,
        });
        const chip_vol = try self.arena.addChild(chips_row, .{
            .kind = .card,
            .test_id = "chip-vol",
            .label = "Vol 72%",
            .width = 72.0,
            .height = @max(14.0, bh - 10.0),
            .corner_radius = self.token_table.corner_radius_sm,
            .border_width = chip_style.border_width,
            .fill = chip_style.fill,
            .border = chip_style.border,
            .text_color = chip_style.text,
        });
        const chip_bat = try self.arena.addChild(chips_row, .{
            .kind = .card,
            .test_id = "chip-bat",
            .label = "94%",
            .width = 56.0,
            .height = @max(14.0, bh - 10.0),
            .corner_radius = self.token_table.corner_radius_sm,
            .border_width = chip_style.border_width,
            .fill = chip_style.fill,
            .border = self.token_table.accent_success.toSrgb(),
            .text_color = chip_style.text,
        });
        const chip_menu = try self.arena.addChild(chips_row, .{
            .kind = .card,
            .test_id = "chip-menu",
            .label = "Menu",
            .width = 56.0,
            .height = @max(14.0, bh - 10.0),
            .corner_radius = self.token_table.corner_radius_sm,
            .border_width = chip_style.border_width,
            .fill = chip_style.fill,
            .border = chip_style.border,
            .text_color = chip_style.text,
            .focusable = true,
        });

        const max_arena_quads: usize = 128;
        var tmp_quads: [max_arena_quads]core.QuadInstance = undefined;
        var bar_sdf_count: usize = 0;

        // 2. Centered Command-Palette Launcher Modal (when launcher_open)
        var launcher_input_node: ?core.NodeId = null;
        var launcher_modal_created: ?core.NodeId = null;
        if (launcher_open) {
            self.arena.layout(w, scene_h);
            bar_sdf_count = self.arena.emitQuads(&tmp_quads, scale);

            const backdrop = try self.arena.addChild(root, .{
                .kind = .vstack,
                .test_id = "launcher-backdrop",
                .justify = .center,
                .align_items = .center,
                .fill = .{ 0.0, 0.0, 0.0, 0.45 },
            });

            const modal_w = @min(520.0, @max(240.0, w - 48.0));
            const modal = try self.arena.addChild(backdrop, .{
                .kind = .card,
                .test_id = "launcher-modal",
                .width = modal_w,
                .height = 360.0,
                .padding = self.token_table.space_md,
                .gap = 10.0,
                .fill = card_style.fill,
                .border = self.token_table.border_focus.toSrgb(),
                .border_width = self.token_table.border_width_focus,
                .corner_radius = self.token_table.corner_radius_lg,
                .shadow_blur = self.token_table.shadow_md,
            });
            self.launcher_modal_node = modal;
            launcher_modal_created = modal;

            const raw_query = self.editor.text();
            var label_len = @min(raw_query.len, self.query_label_buf.len);
            if (label_len < raw_query.len) {
                while (label_len > 0 and (raw_query[label_len] & 0xC0) == 0x80) {
                    label_len -= 1;
                }
            }
            @memcpy(self.query_label_buf[0..label_len], raw_query[0..label_len]);
            const query_label = self.query_label_buf[0..label_len];

            const input_node = try self.arena.addChild(modal, .{
                .kind = .card,
                .test_id = "launcher-input",
                .label = if (query_label.len > 0) query_label else "Search applications...",
                .height = 40.0,
                .padding = self.token_table.space_sm,
                .fill = input_style.fill,
                .border = input_style.border,
                .border_width = input_style.border_width,
                .corner_radius = input_style.corner_radius,
                .text_color = if (query_label.len > 0)
                    self.token_table.text_primary.toSrgb()
                else
                    self.token_table.text_muted.toSrgb(),
                .focusable = true,
            });
            launcher_input_node = input_node;

            const results_box = try self.arena.addChild(modal, .{
                .kind = .vstack,
                .test_id = "launcher-results",
                .flex = 1.0,
                .gap = 6.0,
            });

            var matched: usize = 0;
            var shown: usize = 0;
            for (DEFAULT_LAUNCHER_ITEMS) |item| {
                if (!matchesQuery(item, raw_query)) continue;
                matched += 1;
                if (shown < MAX_LAUNCHER_VISIBLE) {
                    const is_top = shown == 0;
                    const item_style = self.token_table.resolve(.button, .{ .checked = is_top });
                    _ = try self.arena.addChild(results_box, .{
                        .kind = .card,
                        .test_id = item.command,
                        .label = item.name,
                        .sublabel = item.command,
                        .height = 40.0,
                        .corner_radius = self.token_table.corner_radius_sm,
                        .border_width = 1.0,
                        .fill = item_style.fill,
                        .border = item_style.border,
                        .text_color = item_style.text,
                        .checked = is_top,
                        .focusable = true,
                    });
                    shown += 1;
                }
            }
            self.matched_count = matched;
        } else {
            self.matched_count = DEFAULT_LAUNCHER_ITEMS.len;
        }

        // Re-bind focus state onto the freshly rebuilt LayoutArena and only push
        // the launcher modal scope when opening or when no trapped scope is active.
        self.restoreFocus(&focus_snap);
        if (launcher_modal_created) |modal| {
            if (!was_launcher_open or self.focus_mgr.topTrappedContainer(&self.arena) == null) {
                try self.focus_mgr.pushScope(&self.arena, modal, true);
            } else if (focus_snap.focused_len > 0 and self.focus_mgr.focused() == null) {
                if (launcher_input_node) |in_node| {
                    self.focus_mgr.setFocusedByKeyboard(&self.arena, in_node);
                }
            }
        }

        // Compute deterministic layout
        self.arena.layout(w, scene_h);

        // Emit arena quads
        const arena_count = self.arena.emitQuads(&tmp_quads, scale);
        if (!launcher_open) {
            bar_sdf_count = arena_count;
        }

        self.quads.clearRetainingCapacity();
        try self.quads.appendSlice(self.allocator, tmp_quads[0..arena_count]);

        // Rasterize procedural ImageAtlas icons and emit icon quads for status chips
        const icon_specs = [_]struct { node: core.NodeId, icon: image_atlas.BuiltinIcon }{
            .{ .node = chip_net, .icon = .wifi },
            .{ .node = chip_vol, .icon = .volume },
            .{ .node = chip_bat, .icon = .battery },
            .{ .node = chip_menu, .icon = .settings },
        };
        const before_bar_icons = self.quads.items.len;
        for (icon_specs) |spec| {
            if (self.arena.getRect(spec.node)) |r| {
                const uv = try self.atlas.getOrRasterizeIcon(spec.icon, 16, scale, self.frame_idx);
                const icon_size: f32 = 12.0 * scale;
                const ix = (r.x + 4.0) * scale;
                const iy = (r.y + @max(0.0, (r.h - 12.0) * 0.5)) * scale;
                try self.quads.append(self.allocator, .{
                    .pos_size = .{ ix, iy, icon_size, icon_size },
                    .uv_rect = uv,
                    .color = self.token_table.text_primary.toSrgb(),
                    .border_color = core.Nord.transparent,
                    .params = .{ 0.0, 0.0, 0.0, 0.0 },
                    .clip_rect = .{ 0.0, 0.0, w * scale, scene_h * scale },
                });
            }
        }
        const bar_icon_count = self.quads.items.len - before_bar_icons;

        const before_launcher_icons = self.quads.items.len;
        if (launcher_input_node) |in_node| {
            if (self.arena.getRect(in_node)) |r| {
                const uv = try self.atlas.getOrRasterizeIcon(.search, 16, scale, self.frame_idx);
                const icon_size: f32 = 16.0 * scale;
                const ix = (r.x + 10.0) * scale;
                const iy = (r.y + @max(0.0, (r.h - 16.0) * 0.5)) * scale;
                try self.quads.append(self.allocator, .{
                    .pos_size = .{ ix, iy, icon_size, icon_size },
                    .uv_rect = uv,
                    .color = self.token_table.border_focus.toSrgb(),
                    .border_color = core.Nord.transparent,
                    .params = .{ 0.0, 0.0, 0.0, 0.0 },
                    .clip_rect = .{ 0.0, 0.0, w * scale, scene_h * scale },
                });
            }
        }
        const launcher_icon_count = self.quads.items.len - before_launcher_icons;

        // Emit anchored dropdown overlay portal quads if open (physical pixels)
        var overlay_buf: [overlay.MAX_OVERLAYS * 2]core.QuadInstance = undefined;
        const overlay_count = self.overlays.emitOverlayQuadsScaled(w, scene_h, scale, &overlay_buf);
        if (overlay_count > 0) {
            try self.quads.appendSlice(self.allocator, overlay_buf[0..overlay_count]);
        }

        // Track breakdown counts from measured quad counts before/after launcher emission
        self.last_bar_quads = bar_sdf_count + bar_icon_count;
        self.last_launcher_quads = if (launcher_open)
            (arena_count -| bar_sdf_count) + launcher_icon_count
        else
            0;
        self.last_overlay_quads = overlay_count;

        self.frame_idx += 1;
        return self.quads.items.len;
    }
};

fn printSummary(out: *std.Io.Writer, shell: *StratifiShell) !void {
    const bar_only_quads = try shell.buildBarScene(1920.0, 32.0, 1, false);
    const bar_icons = shell.atlas.cachedCount();

    shell.toggleLauncher();
    try shell.typeLauncherChar("ter");
    const launcher_total_quads = try shell.buildBarScene(1920.0, 32.0, 2, shell.launcher_open);

    const menu_id = try shell.openBarMenu(1760.0, 1920.0, 1080.0);
    const full_total_quads = try shell.buildBarScene(1920.0, 32.0, 2, shell.launcher_open);
    const menu_rect = shell.overlays.top().?.rect;

    try out.print(
        "stratifi-demo headless summary:\n" ++
            "  bar_only_quads={d} (bar={d}, atlas_icons={d})\n" ++
            "  launcher_open=true query=\"{s}\" matched={d} launcher_quads={d} total_quads={d}\n" ++
            "  bar_menu_overlay id={d} rect=({d:.0},{d:.0},{d:.0}x{d:.0}) xdg_positioner_wire_bytes={d} overlay_quads={d} total_with_overlay={d}\n" ++
            "  multi_monitor outputs={d} min_frame_interval_us={d}\n",
        .{
            bar_only_quads,
            shell.last_bar_quads,
            bar_icons,
            shell.query(),
            shell.matched_count,
            shell.last_launcher_quads,
            launcher_total_quads,
            menu_id,
            menu_rect.x,
            menu_rect.y,
            menu_rect.w,
            menu_rect.h,
            shell.last_positioner_wire_len,
            shell.last_overlay_quads,
            full_total_quads,
            shell.windows.output_count,
            shell.windows.minFrameIntervalUs(),
        },
    );

    const p1 = shell.windows.physicalSize(shell.primary_bar_win_id).?;
    const p2 = shell.windows.physicalSize(shell.secondary_bar_win_id).?;
    const w1 = shell.windows.getWindow(shell.primary_bar_win_id).?;
    const w2 = shell.windows.getWindow(shell.secondary_bar_win_id).?;
    try out.print(
        "  output[1] DP-1: scale={d:.2}x refresh={d}mHz bar_phys={d}x{d}\n" ++
            "  output[2] HDMI-A-1: scale={d:.2}x refresh={d}mHz bar_phys={d}x{d}\n",
        .{
            w1.scale_factor,
            w1.refresh_mhz,
            p1.w,
            p1.h,
            w2.scale_factor,
            w2.refresh_mhz,
            p2.w,
            p2.h,
        },
    );
    try out.flush();
}

fn fallbackToHeadless(
    out: *std.Io.Writer,
    shell: *StratifiShell,
    reason: []const u8,
    sock_path: [*:0]const u8,
    err: anyerror,
) !void {
    try out.print(
        "{s} '{s}' ({s}); falling back to headless summary:\n",
        .{ reason, std.mem.span(sock_path), @errorName(err) },
    );
    try printSummary(out, shell);
}

pub fn main(init: std.process.Init) !void {
    var headless = false;
    var arg_iter = init.minimal.args.iterate();
    _ = arg_iter.next(); // argv[0]
    while (arg_iter.next()) |arg| {
        if (std.mem.eql(u8, arg, "--headless")) {
            headless = true;
        }
    }

    var out_buf: [4096]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writerStreaming(init.io, &out_buf);
    const out = &stdout_writer.interface;

    var shell = try StratifiShell.init(init.gpa);
    defer shell.deinit();

    if (headless) {
        try printSummary(out, &shell);
        return;
    }

    const wayland_display = init.environ_map.get("WAYLAND_DISPLAY") orelse "";
    const xdg_runtime_dir = init.environ_map.get("XDG_RUNTIME_DIR") orelse "";
    if (wayland_display.len == 0) {
        try out.print(
            "WAYLAND_DISPLAY is not set; no live Wayland compositor running. Falling back to headless summary:\n",
            .{},
        );
        try printSummary(out, &shell);
        return;
    }

    var sock_buf: [128]u8 = undefined;
    const sock_path = wayland.resolveSocketPath(xdg_runtime_dir, wayland_display, &sock_buf) catch |err| {
        try out.print(
            "Could not resolve Wayland socket ({s}); falling back to headless summary:\n",
            .{@errorName(err)},
        );
        try printSummary(out, &shell);
        return;
    };

    var client = wayland.WaylandClient.connect(init.gpa, sock_path) catch |err| {
        try fallbackToHeadless(out, &shell, "No Wayland compositor listening on", sock_path, err);
        return;
    };
    defer client.deinit();

    var ep = wayland.EpollLoop.init() catch |err| {
        try fallbackToHeadless(out, &shell, "Failed to initialize Wayland epoll loop for", sock_path, err);
        return;
    };
    defer ep.deinit();

    ep.addFd(client.fd(), 1) catch |err| {
        try fallbackToHeadless(out, &shell, "Failed to watch Wayland socket fd for", sock_path, err);
        return;
    };
    defer ep.removeFd(client.fd());

    _ = ep.wait(50) catch |err| {
        try fallbackToHeadless(out, &shell, "Wayland epoll wait failed on", sock_path, err);
        return;
    };
    _ = client.readAndDispatch() catch |err| {
        try fallbackToHeadless(out, &shell, "Wayland dispatch failed on", sock_path, err);
        return;
    };

    if (client.hasLayerShell()) {
        const bar_surf = client.createLayerSurface(.{
            .layer = .top,
            .anchor = .{ .top = true, .left = true, .right = true },
            .width = 0,
            .height = 32,
            .exclusive_zone = 32,
            .namespace = "stratifi-bar",
        }) catch |err| {
            try fallbackToHeadless(out, &shell, "Wayland layer surface creation failed on", sock_path, err);
            return;
        };
        client.flushSend() catch |err| {
            try fallbackToHeadless(out, &shell, "Wayland flush failed on", sock_path, err);
            return;
        };
        try out.print(
            "Connected to Wayland compositor '{s}' (layer_surface_id={d}); rendered summary:\n",
            .{ std.mem.span(sock_path), bar_surf.layer_surface_id },
        );
    } else {
        try out.print(
            "Connected to Wayland compositor '{s}' (zwlr_layer_shell_v1 unavailable); rendered summary:\n",
            .{std.mem.span(sock_path)},
        );
    }
    try printSummary(out, &shell);
}
