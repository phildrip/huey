const std = @import("std");
const core = @import("core.zig");
const tokens = @import("tokens.zig");

pub const MAX_NESTING_DEPTH: usize = 32;
pub const MAX_NODES: usize = 2048;
pub const MAX_JSON_BYTES: usize = 512 * 1024;
pub const MAX_STRING_LEN: usize = 4096;
pub const MAX_ROW_SPAN: u16 = 64;

pub const LoadError = error{
    InvalidJson,
    JsonTooLarge,
    ExpectedObject,
    MissingType,
    UnknownNodeType,
    MaxDepthExceeded,
    MaxNodesExceeded,
    InvalidFieldType,
    OutOfMemory,
    InvalidNodeId,
};

pub const LoadResult = struct {
    root: core.NodeId,
    node_count: usize,
};

const NodeMeta = struct {
    kind: core.NodeKind,
    role: core.SemanticRole,
    comp_kind: tokens.ComponentKind,
    is_container: bool,
    allows_children: bool,
};

const node_type_map = std.StaticStringMap(NodeMeta).initComptime(.{
    .{ "vstack", NodeMeta{ .kind = .vstack, .role = .container, .comp_kind = .surface, .is_container = true, .allows_children = true } },
    .{ "hstack", NodeMeta{ .kind = .hstack, .role = .container, .comp_kind = .surface, .is_container = true, .allows_children = true } },
    .{ "zstack", NodeMeta{ .kind = .zstack, .role = .container, .comp_kind = .surface, .is_container = true, .allows_children = true } },
    .{ "grid", NodeMeta{ .kind = .grid, .role = .container, .comp_kind = .surface, .is_container = true, .allows_children = true } },
    .{ "card", NodeMeta{ .kind = .card, .role = .panel, .comp_kind = .card, .is_container = false, .allows_children = true } },
    .{ "toggle", NodeMeta{ .kind = .toggle, .role = .switch_control, .comp_kind = .toggle, .is_container = false, .allows_children = false } },
    .{ "slider", NodeMeta{ .kind = .slider, .role = .slider, .comp_kind = .slider, .is_container = false, .allows_children = false } },
    .{ "bar", NodeMeta{ .kind = .bar, .role = .progress_bar, .comp_kind = .bar, .is_container = false, .allows_children = false } },
});

const justify_map = std.StaticStringMap(core.Justify).initComptime(.{
    .{ "start", .start },
    .{ "center", .center },
    .{ "end", .end },
    .{ "space_between", .space_between },
    .{ "space_around", .space_around },
    .{ "space_evenly", .space_evenly },
});

const align_map = std.StaticStringMap(core.Align).initComptime(.{
    .{ "start", .start },
    .{ "center", .center },
    .{ "end", .end },
    .{ "stretch", .stretch },
});

const TableColorField = enum {
    bg_base,
    bg_surface,
    bg_elevated,
    border_default,
    border_focus,
    text_primary,
    text_muted,
    accent_primary,
    accent_success,
    accent_warn,
    accent_danger,
};

const table_color_map = std.StaticStringMap(TableColorField).initComptime(.{
    .{ "bg_base", .bg_base },
    .{ "bg_surface", .bg_surface },
    .{ "bg_elevated", .bg_elevated },
    .{ "border_default", .border_default },
    .{ "border_focus", .border_focus },
    .{ "text_primary", .text_primary },
    .{ "text_muted", .text_muted },
    .{ "accent_primary", .accent_primary },
    .{ "accent_success", .accent_success },
    .{ "accent_warn", .accent_warn },
    .{ "accent_danger", .accent_danger },
});

const nord_color_map = std.StaticStringMap(core.Color).initComptime(.{
    .{ "transparent", core.Nord.transparent },
    .{ "polar_night_0", core.Nord.polar_night_0 },
    .{ "polar_night_1", core.Nord.polar_night_1 },
    .{ "polar_night_2", core.Nord.polar_night_2 },
    .{ "polar_night_3", core.Nord.polar_night_3 },
    .{ "snow_storm_0", core.Nord.snow_storm_0 },
    .{ "snow_storm_1", core.Nord.snow_storm_1 },
    .{ "snow_storm_2", core.Nord.snow_storm_2 },
    .{ "frost_0", core.Nord.frost_0 },
    .{ "frost_1", core.Nord.frost_1 },
    .{ "frost_2", core.Nord.frost_2 },
    .{ "frost_3", core.Nord.frost_3 },
    .{ "aurora_red", core.Nord.aurora_red },
    .{ "aurora_orange", core.Nord.aurora_orange },
    .{ "aurora_yellow", core.Nord.aurora_yellow },
    .{ "aurora_green", core.Nord.aurora_green },
    .{ "aurora_purple", core.Nord.aurora_purple },
});

fn parseHexNibble(c: u8) ?u8 {
    return switch (c) {
        '0'...'9' => c - '0',
        'a'...'f' => c - 'a' + 10,
        'A'...'F' => c - 'A' + 10,
        else => null,
    };
}

fn parseHexByte(s: []const u8) ?u8 {
    if (s.len != 2) return null;
    const hi = parseHexNibble(s[0]) orelse return null;
    const lo = parseHexNibble(s[1]) orelse return null;
    return (hi << 4) | lo;
}

fn parseHexColor(name: []const u8) ?core.Color {
    if (name.len != 7 and name.len != 9) return null;
    if (name[0] != '#') return null;
    const r = parseHexByte(name[1..3]) orelse return null;
    const g = parseHexByte(name[3..5]) orelse return null;
    const b = parseHexByte(name[5..7]) orelse return null;
    const a: u8 = if (name.len == 9) (parseHexByte(name[7..9]) orelse return null) else 255;
    return .{
        @as(f32, @floatFromInt(r)) / 255.0,
        @as(f32, @floatFromInt(g)) / 255.0,
        @as(f32, @floatFromInt(b)) / 255.0,
        @as(f32, @floatFromInt(a)) / 255.0,
    };
}

/// Resolves a token name, Nord color alias, or `#RRGGBB` / `#RRGGBBAA` hex string to sRGB `Color`.
pub fn resolveTokenColor(table: *const tokens.TokenTable, name: []const u8) ?core.Color {
    if (table_color_map.get(name)) |field| {
        return switch (field) {
            inline else => |f| @field(table, @tagName(f)).toSrgb(),
        };
    }
    if (nord_color_map.get(name)) |c| {
        return c;
    }
    if (name.len > 0 and name[0] == '#') {
        return parseHexColor(name);
    }
    return null;
}

fn parseNodeMeta(obj: std.json.ObjectMap) LoadError!NodeMeta {
    const type_val = obj.get("type") orelse return error.MissingType;
    const type_str = switch (type_val) {
        .string => |s| s,
        else => return error.InvalidFieldType,
    };
    return node_type_map.get(type_str) orelse error.UnknownNodeType;
}

fn readOptionalString(
    string_allocator: ?std.mem.Allocator,
    obj: std.json.ObjectMap,
    key: []const u8,
) LoadError![]const u8 {
    const val = obj.get(key) orelse return "";
    const s = switch (val) {
        .string => |str| str,
        else => return error.InvalidFieldType,
    };
    if (s.len > MAX_STRING_LEN) return error.InvalidFieldType;
    if (s.len == 0) return "";
    if (string_allocator) |alloc| {
        return try alloc.dupe(u8, s);
    }
    return "";
}

fn getOptionalBool(obj: std.json.ObjectMap, key: []const u8, default: bool) LoadError!bool {
    const val = obj.get(key) orelse return default;
    return switch (val) {
        .bool => |b| b,
        else => error.InvalidFieldType,
    };
}

fn getOptionalFloat(obj: std.json.ObjectMap, key: []const u8, default: f32) LoadError!f32 {
    const val = obj.get(key) orelse return default;
    return switch (val) {
        .float => |f| blk: {
            if (!std.math.isFinite(f)) return error.InvalidFieldType;
            const res: f32 = @floatCast(f);
            if (!std.math.isFinite(res)) return error.InvalidFieldType;
            break :blk res;
        },
        .integer => |i| @floatFromInt(i),
        .number_string => |s| blk: {
            const res = std.fmt.parseFloat(f32, s) catch return error.InvalidFieldType;
            if (!std.math.isFinite(res)) return error.InvalidFieldType;
            break :blk res;
        },
        else => error.InvalidFieldType,
    };
}

fn getOptionalBoundedU16(
    obj: std.json.ObjectMap,
    key: []const u8,
    default: u16,
    min_val: u16,
    max_val: u16,
) LoadError!u16 {
    const val = obj.get(key) orelse return default;
    const parsed: u16 = switch (val) {
        .integer => |i| blk: {
            if (i < min_val or i > max_val) return error.InvalidFieldType;
            break :blk @intCast(i);
        },
        .float => |f| blk: {
            if (!std.math.isFinite(f) or f < @as(f64, min_val) or f > @as(f64, max_val) or @floor(f) != f) {
                return error.InvalidFieldType;
            }
            break :blk @intFromFloat(f);
        },
        else => return error.InvalidFieldType,
    };
    return parsed;
}

fn getOptionalColor(
    table: *const tokens.TokenTable,
    obj: std.json.ObjectMap,
    key: []const u8,
    default: core.Color,
) LoadError!core.Color {
    const val = obj.get(key) orelse return default;
    const name = switch (val) {
        .string => |s| s,
        else => return error.InvalidFieldType,
    };
    return resolveTokenColor(table, name) orelse error.InvalidFieldType;
}

fn getOptionalMapped(
    comptime T: type,
    map: std.StaticStringMap(T),
    obj: std.json.ObjectMap,
    key: []const u8,
    default: T,
) LoadError!T {
    const val = obj.get(key) orelse return default;
    const s = switch (val) {
        .string => |str| str,
        else => return error.InvalidFieldType,
    };
    return map.get(s) orelse error.InvalidFieldType;
}

const ParsedNode = struct {
    desc: core.NodeDesc,
    children: ?std.json.Array,
};

fn parseNode(
    obj: std.json.ObjectMap,
    table: *const tokens.TokenTable,
    string_allocator: ?std.mem.Allocator,
) LoadError!ParsedNode {
    const meta = try parseNodeMeta(obj);
    const checked = try getOptionalBool(obj, "checked", false);
    const disabled = try getOptionalBool(obj, "disabled", false);

    const resolved = table.resolve(meta.comp_kind, .{
        .checked = checked,
        .disabled = disabled,
    });

    const default_fill = if (meta.is_container) core.Nord.transparent else resolved.fill;

    const desc = core.NodeDesc{
        .kind = meta.kind,
        .role = meta.role,
        .test_id = try readOptionalString(string_allocator, obj, "id"),
        .label = try readOptionalString(string_allocator, obj, "label"),
        .sublabel = try readOptionalString(string_allocator, obj, "sublabel"),
        .font_size = try getOptionalFloat(obj, "font_size", 16.0),
        .text_color = try getOptionalColor(table, obj, "text_color", resolved.text),
        .width = try getOptionalFloat(obj, "width", 0.0),
        .height = try getOptionalFloat(obj, "height", 0.0),
        .flex = try getOptionalFloat(obj, "flex", 1.0),
        .flex_shrink = try getOptionalFloat(obj, "flex_shrink", 0.0),
        .min_width = try getOptionalFloat(obj, "min_width", 0.0),
        .max_width = try getOptionalFloat(obj, "max_width", 0.0),
        .min_height = try getOptionalFloat(obj, "min_height", 0.0),
        .max_height = try getOptionalFloat(obj, "max_height", 0.0),
        .justify = try getOptionalMapped(core.Justify, justify_map, obj, "justify", .start),
        .align_items = try getOptionalMapped(core.Align, align_map, obj, "align_items", .stretch),
        .flex_wrap = try getOptionalBool(obj, "flex_wrap", false),
        .grid_cols = try getOptionalBoundedU16(obj, "grid_cols", 0, 1, core.MAX_GRID_COLS),
        .col_span = try getOptionalBoundedU16(obj, "col_span", 1, 1, core.MAX_GRID_COLS),
        .row_span = try getOptionalBoundedU16(obj, "row_span", 1, 1, MAX_ROW_SPAN),
        .padding = try getOptionalFloat(obj, "padding", 0.0),
        .gap = try getOptionalFloat(obj, "gap", 0.0),
        .corner_radius = try getOptionalFloat(obj, "corner_radius", resolved.corner_radius),
        .border_width = try getOptionalFloat(obj, "border_width", resolved.border_width),
        .shadow_blur = try getOptionalFloat(obj, "shadow_blur", resolved.shadow_blur),
        .fill = try getOptionalColor(table, obj, "fill", default_fill),
        .border = try getOptionalColor(table, obj, "border", resolved.border),
        .accent = try getOptionalColor(table, obj, "accent", resolved.accent),
        .checked = checked,
        .slider_val = try getOptionalFloat(obj, "value", 0.0),
        .disabled = disabled,
        .roving_group = try getOptionalBool(obj, "roving_group", false),
        .clip_children = try getOptionalBool(obj, "clip_children", false),
    };

    var children: ?std.json.Array = null;
    if (obj.get("children")) |children_val| {
        const arr = switch (children_val) {
            .array => |a| a,
            else => return error.InvalidFieldType,
        };
        if (!meta.allows_children and arr.items.len > 0) {
            return error.InvalidFieldType;
        }
        children = arr;
    }

    return .{
        .desc = desc,
        .children = children,
    };
}

fn validateNodeTree(
    obj: std.json.ObjectMap,
    table: *const tokens.TokenTable,
    depth: usize,
    node_count: *usize,
) LoadError!void {
    if (depth >= MAX_NESTING_DEPTH) return error.MaxDepthExceeded;
    if (node_count.* >= MAX_NODES) return error.MaxNodesExceeded;

    const parsed = try parseNode(obj, table, null);
    node_count.* += 1;

    if (parsed.children) |arr| {
        for (arr.items) |child_val| {
            const child_obj = switch (child_val) {
                .object => |co| co,
                else => return error.ExpectedObject,
            };
            try validateNodeTree(child_obj, table, depth + 1, node_count);
        }
    }
}

fn populateNode(
    string_allocator: std.mem.Allocator,
    arena: *core.LayoutArena,
    table: *const tokens.TokenTable,
    obj: std.json.ObjectMap,
    parent_id: ?core.NodeId,
    node_count: *usize,
) LoadError!core.NodeId {
    const parsed = try parseNode(obj, table, string_allocator);

    const node_id = if (parent_id) |pid|
        try arena.addChild(pid, parsed.desc)
    else
        try arena.addNode(parsed.desc);
    node_count.* += 1;

    if (parsed.children) |arr| {
        for (arr.items) |child_val| {
            const child_obj = switch (child_val) {
                .object => |co| co,
                else => return error.ExpectedObject,
            };
            _ = try populateNode(
                string_allocator,
                arena,
                table,
                child_obj,
                node_id,
                node_count,
            );
        }
    }

    return node_id;
}

/// Parses a declarative JSON layout tree and populates `arena` atomically.
/// Performs a full read-only validation pass before resetting `arena` or
/// allocating strings, leaving any existing live tree untouched on error.
pub fn loadJsonIntoArena(
    scratch_allocator: std.mem.Allocator,
    string_allocator: std.mem.Allocator,
    arena: *core.LayoutArena,
    table: *const tokens.TokenTable,
    json_src: []const u8,
) LoadError!LoadResult {
    if (json_src.len > MAX_JSON_BYTES) return error.JsonTooLarge;

    var parsed = std.json.parseFromSlice(
        std.json.Value,
        scratch_allocator,
        json_src,
        .{ .max_value_len = MAX_STRING_LEN },
    ) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.ValueTooLong => return error.InvalidFieldType,
        else => return error.InvalidJson,
    };
    defer parsed.deinit();

    const root_obj = switch (parsed.value) {
        .object => |obj| obj,
        else => return error.ExpectedObject,
    };

    // Full read-only validation pass BEFORE mutating arena or string_allocator.
    var validated_nodes: usize = 0;
    try validateNodeTree(root_obj, table, 0, &validated_nodes);

    arena.reset();
    errdefer arena.reset();

    var node_count: usize = 0;
    const root_id = try populateNode(
        string_allocator,
        arena,
        table,
        root_obj,
        null,
        &node_count,
    );

    return .{
        .root = root_id,
        .node_count = node_count,
    };
}
