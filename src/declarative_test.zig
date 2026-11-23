const std = @import("std");
const core = @import("core.zig");
const tokens = @import("tokens.zig");
const events = @import("events.zig");
const decl = @import("declarative.zig");

test "Declarative JSON loader builds SoA LayoutArena tree with token refs, bindings, and pollEvents action wiring" {
    const json_src =
        \\{
        \\  "type": "vstack",
        \\  "id": "bloxwm.bar",
        \\  "padding": 12,
        \\  "gap": 8,
        \\  "fill": "bg_base",
        \\  "children": [
        \\    {
        \\      "type": "hstack",
        \\      "id": "bar.row",
        \\      "height": 48,
        \\      "gap": 8,
        \\      "children": [
        \\        { "type": "bar", "id": "sys.cpu", "width": 120, "value": 0.65, "accent": "accent_primary", "label": "CPU" },
        \\        { "type": "toggle", "id": "notify.dnd", "width": 140, "checked": false, "accent": "accent_success", "label": "DND" }
        \\      ]
        \\    },
        \\    { "type": "slider", "id": "audio.vol", "height": 56, "value": 0.5, "accent": "accent_warn", "label": "Volume" }
        \\  ]
        \\}
    ;

    var arena = core.LayoutArena.init(std.testing.allocator);
    defer arena.deinit();
    var str_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer str_arena.deinit();

    const table = tokens.TokenTable.nordDefault();
    const res = try decl.loadJsonIntoArena(std.testing.allocator, str_arena.allocator(), &arena, &table, json_src);
    try std.testing.expectEqual(@as(usize, 5), res.node_count);

    arena.layout(400.0, 200.0);
    const dnd_id = arena.findByTestId("notify.dnd").?;
    const r = arena.getRect(dnd_id).?;
    try std.testing.expect(r.w == 140.0 and r.h == 48.0);

    // Clicking JSON-declared toggle fires pollEvents() cleanly with zero scripting DSL!
    var router = events.EventRouter.init();
    router.dispatch(&arena, .{ .pointer_down = .{ .pointer_id = 0, .x = r.x + r.w * 0.5, .y = r.y + r.h * 0.5 } });
    router.dispatch(&arena, .{ .pointer_up = .{ .pointer_id = 0, .x = r.x + r.w * 0.5, .y = r.y + r.h * 0.5 } });
    const evs = router.pollEvents();
    try std.testing.expectEqual(@as(usize, 1), evs.len);
    try std.testing.expectEqualStrings("notify.dnd", evs[0].toggled.test_id);
    try std.testing.expect(evs[0].toggled.checked);
}

test "Declarative JSON loader rejects unknown node types, malformed JSON, and excessive nesting depth" {
    var arena = core.LayoutArena.init(std.testing.allocator);
    defer arena.deinit();
    var str_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer str_arena.deinit();
    const table = tokens.TokenTable.nordDefault();

    try std.testing.expectError(error.UnknownNodeType, decl.loadJsonIntoArena(
        std.testing.allocator,
        str_arena.allocator(),
        &arena,
        &table,
        "{\"type\":\"script_injection\"}",
    ));

    try std.testing.expectError(error.InvalidJson, decl.loadJsonIntoArena(
        std.testing.allocator,
        str_arena.allocator(),
        &arena,
        &table,
        "{\"type\":\"vstack\", bad_json",
    ));

    try std.testing.expectError(error.ExpectedObject, decl.loadJsonIntoArena(
        std.testing.allocator,
        str_arena.allocator(),
        &arena,
        &table,
        "[1, 2, 3]",
    ));

    try std.testing.expectError(error.MissingType, decl.loadJsonIntoArena(
        std.testing.allocator,
        str_arena.allocator(),
        &arena,
        &table,
        "{\"id\":\"no_type\"}",
    ));

    // Build JSON exceeding MAX_NESTING_DEPTH
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(std.testing.allocator);
    const depth = decl.MAX_NESTING_DEPTH + 1;
    for (0..depth) |_| {
        try buf.appendSlice(std.testing.allocator, "{\"type\":\"vstack\",\"children\":[");
    }
    try buf.appendSlice(std.testing.allocator, "{\"type\":\"card\"}");
    for (0..depth) |_| {
        try buf.appendSlice(std.testing.allocator, "]}");
    }

    try std.testing.expectError(error.MaxDepthExceeded, decl.loadJsonIntoArena(
        std.testing.allocator,
        str_arena.allocator(),
        &arena,
        &table,
        buf.items,
    ));
    try std.testing.expect(arena.getRoot() == null);
    try std.testing.expectEqual(@as(usize, 0), arena.nodes.len);
}

test "resolveTokenColor resolves TokenTable names, Nord aliases, #RRGGBB, and #RRGGBBAA hex colors" {
    const table = tokens.TokenTable.nordDefault();

    // TokenTable fields
    try std.testing.expectEqual(table.bg_base.toSrgb(), decl.resolveTokenColor(&table, "bg_base").?);
    try std.testing.expectEqual(table.accent_danger.toSrgb(), decl.resolveTokenColor(&table, "accent_danger").?);
    try std.testing.expectEqual(core.Nord.transparent, decl.resolveTokenColor(&table, "transparent").?);

    // Nord aliases
    try std.testing.expectEqual(core.Nord.polar_night_0, decl.resolveTokenColor(&table, "polar_night_0").?);
    try std.testing.expectEqual(core.Nord.snow_storm_2, decl.resolveTokenColor(&table, "snow_storm_2").?);
    try std.testing.expectEqual(core.Nord.frost_1, decl.resolveTokenColor(&table, "frost_1").?);
    try std.testing.expectEqual(core.Nord.aurora_purple, decl.resolveTokenColor(&table, "aurora_purple").?);

    // #RRGGBB and #RRGGBBAA
    const rgb = decl.resolveTokenColor(&table, "#FF8000").?;
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), rgb[0], 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 128.0 / 255.0), rgb[1], 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), rgb[2], 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), rgb[3], 0.001);

    const rgba = decl.resolveTokenColor(&table, "#00ff0080").?;
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), rgba[0], 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), rgba[1], 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), rgba[2], 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 128.0 / 255.0), rgba[3], 0.001);

    // Reject invalid colors
    try std.testing.expect(decl.resolveTokenColor(&table, "#12345") == null);
    try std.testing.expect(decl.resolveTokenColor(&table, "#GGGGGG") == null);
    try std.testing.expect(decl.resolveTokenColor(&table, "#+F0000") == null);
    try std.testing.expect(decl.resolveTokenColor(&table, "nonexistent_token") == null);
}

test "Declarative JSON loader supports grid, col_span, justify, flex_wrap, #RRGGBB colors, and TokenTable defaults" {
    const json_src =
        \\{
        \\  "type": "vstack",
        \\  "id": "root",
        \\  "padding": 10,
        \\  "gap": 10,
        \\  "fill": "#102030",
        \\  "children": [
        \\    {
        \\      "type": "grid",
        \\      "id": "g",
        \\      "grid_cols": 3,
        \\      "gap": 10,
        \\      "height": 110,
        \\      "children": [
        \\        { "type": "card", "id": "c_span2", "col_span": 2, "height": 50, "label": "Wide", "sublabel": "Span 2" },
        \\        { "type": "card", "id": "c_single", "height": 50, "fill": "frost_2", "border": "#AABBCC80", "border_width": 2 }
        \\      ]
        \\    },
        \\    {
        \\      "type": "hstack",
        \\      "id": "row.wrap",
        \\      "justify": "space_between",
        \\      "align_items": "center",
        \\      "flex_wrap": true,
        \\      "height": 100,
        \\      "children": [
        \\        { "type": "toggle", "id": "t1", "width": 100, "height": 40, "checked": true, "roving_group": true },
        \\        { "type": "slider", "id": "s1", "width": 100, "height": 40, "value": 0.75, "disabled": true }
        \\      ]
        \\    }
        \\  ]
        \\}
    ;

    var arena = core.LayoutArena.init(std.testing.allocator);
    defer arena.deinit();
    var str_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer str_arena.deinit();
    const table = tokens.TokenTable.nordDefault();

    // Heap-allocate json_src and free immediately after loading to verify strings are copied to string_allocator.
    const owned_json = try std.testing.allocator.dupe(u8, json_src);
    const res = try decl.loadJsonIntoArena(std.testing.allocator, str_arena.allocator(), &arena, &table, owned_json);
    @memset(owned_json, 'x');
    std.testing.allocator.free(owned_json);

    try std.testing.expectEqual(@as(usize, 7), res.node_count);

    // Verify grid + col_span + justify layout
    arena.layout(320.0, 300.0); // inner_w = 320 - 20 = 300; 3 cols with 10 gap => col_w = (300 - 20)/3 = 93.333...
    const wide_rect = arena.getRect(arena.findByTestId("c_span2").?).?;
    const single_rect = arena.getRect(arena.findByTestId("c_single").?).?;
    try std.testing.expect(wide_rect.w > single_rect.w * 1.9);
    try std.testing.expectApproxEqAbs(wide_rect.x + wide_rect.w + 10.0, single_rect.x, 0.01);

    // Verify justify: space_between in hstack (inner_w = 300, two 100px children -> x=10 and x=210)
    const t1_id = arena.findByTestId("t1").?;
    const s1_id = arena.findByTestId("s1").?;
    const t1_rect = arena.getRect(t1_id).?;
    const s1_rect = arena.getRect(s1_id).?;
    try std.testing.expectApproxEqAbs(@as(f32, 10.0), t1_rect.x, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 210.0), s1_rect.x, 0.01);
    // align_items: center inside 100px hstack with 40px child -> centered vertically
    try std.testing.expectApproxEqAbs(t1_rect.y + 40.0 * 0.5, s1_rect.y + 40.0 * 0.5, 0.01);

    // Verify TokenTable defaults applied when style fields are omitted on c_span2 (card)
    const c_span2_idx = arena.findByTestId("c_span2").?.index;
    const expected_card_style = table.resolve(.card, .{});
    const slice = arena.nodes.slice();
    try std.testing.expectEqual(expected_card_style.fill, slice.items(.fill)[c_span2_idx]);
    try std.testing.expectEqual(expected_card_style.corner_radius, slice.items(.corner_radius)[c_span2_idx]);
    try std.testing.expectEqualStrings("Wide", slice.items(.label)[c_span2_idx]);
    try std.testing.expectEqualStrings("Span 2", slice.items(.sublabel)[c_span2_idx]);
    try std.testing.expect(arena.isRovingGroup(t1_id));
    try std.testing.expect(arena.isDisabled(s1_id));
    try std.testing.expectApproxEqAbs(@as(f32, 0.75), arena.getSliderValue(s1_id).?, 0.001);
}

test "Hot-reload preserves previous live tree untouched on root or mid-tree errors" {
    var arena = core.LayoutArena.init(std.testing.allocator);
    defer arena.deinit();
    var str_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer str_arena.deinit();
    const table = tokens.TokenTable.nordDefault();

    // First load a valid tree into arena
    const init_res = try decl.loadJsonIntoArena(
        std.testing.allocator,
        str_arena.allocator(),
        &arena,
        &table,
        "{\"type\":\"vstack\",\"id\":\"existing\",\"label\":\"Live Root\",\"children\":[{\"type\":\"card\",\"id\":\"existing.child\",\"label\":\"Keep Me\"}]}",
    );
    try std.testing.expectEqual(@as(usize, 2), init_res.node_count);
    try std.testing.expectEqual(@as(usize, 2), arena.nodes.len);
    const old_root = arena.getRoot().?;

    // Root-level error leaves existing arena untouched
    try std.testing.expectError(error.InvalidJson, decl.loadJsonIntoArena(
        std.testing.allocator,
        str_arena.allocator(),
        &arena,
        &table,
        "{broken",
    ));
    try std.testing.expectEqual(@as(usize, 2), arena.nodes.len);
    try std.testing.expectEqual(old_root, arena.getRoot().?);

    // Mid-tree error after valid root also preserves previous live tree 100% untouched!
    const mid_tree_bad_json =
        \\{
        \\  "type": "vstack",
        \\  "id": "new_root",
        \\  "children": [
        \\    { "type": "card", "id": "ok_child" },
        \\    { "type": "card", "id": "bad_child", "justify": "invalid_justify" }
        \\  ]
        \\}
    ;
    try std.testing.expectError(error.InvalidFieldType, decl.loadJsonIntoArena(
        std.testing.allocator,
        str_arena.allocator(),
        &arena,
        &table,
        mid_tree_bad_json,
    ));
    try std.testing.expectEqual(@as(usize, 2), arena.nodes.len);
    try std.testing.expectEqual(old_root, arena.getRoot().?);
    try std.testing.expect(arena.findByTestId("existing") != null);
    try std.testing.expect(arena.findByTestId("existing.child") != null);
    try std.testing.expect(arena.findByTestId("new_root") == null);
    try std.testing.expect(arena.findByTestId("ok_child") == null);
}

test "Leaf widgets reject children while card allows children" {
    var arena = core.LayoutArena.init(std.testing.allocator);
    defer arena.deinit();
    var str_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer str_arena.deinit();
    const table = tokens.TokenTable.nordDefault();

    // Card allows children
    const card_ok = try decl.loadJsonIntoArena(
        std.testing.allocator,
        str_arena.allocator(),
        &arena,
        &table,
        "{\"type\":\"card\",\"id\":\"c\",\"children\":[{\"type\":\"bar\",\"id\":\"b\"}]}",
    );
    try std.testing.expectEqual(@as(usize, 2), card_ok.node_count);

    // Leaf widgets reject non-empty children
    const leaf_cases = [_][]const u8{
        "{\"type\":\"toggle\",\"children\":[{\"type\":\"card\"}]}",
        "{\"type\":\"slider\",\"children\":[{\"type\":\"card\"}]}",
        "{\"type\":\"bar\",\"children\":[{\"type\":\"card\"}]}",
    };
    for (leaf_cases) |bad| {
        try std.testing.expectError(error.InvalidFieldType, decl.loadJsonIntoArena(
            std.testing.allocator,
            str_arena.allocator(),
            &arena,
            &table,
            bad,
        ));
    }
    // Previous valid card tree remains preserved after failed loads
    try std.testing.expectEqual(@as(usize, 2), arena.nodes.len);
    try std.testing.expect(arena.findByTestId("c") != null);
}

test "Domain bounds on grid_cols, col_span, row_span, and numeric edge cases (1e309, large number_string)" {
    var arena = core.LayoutArena.init(std.testing.allocator);
    defer arena.deinit();
    var str_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer str_arena.deinit();
    const table = tokens.TokenTable.nordDefault();

    const invalid_cases = [_][]const u8{
        "{\"type\":\"grid\",\"grid_cols\":0}",
        "{\"type\":\"grid\",\"grid_cols\":65}",
        "{\"type\":\"grid\",\"grid_cols\":-1}",
        "{\"type\":\"grid\",\"grid_cols\":99999999}",
        "{\"type\":\"card\",\"col_span\":0}",
        "{\"type\":\"card\",\"col_span\":65}",
        "{\"type\":\"card\",\"row_span\":0}",
        "{\"type\":\"card\",\"row_span\":65}",
        "{\"type\":\"card\",\"row_span\":65535}",
        "{\"type\":\"card\",\"width\":1e309}",
    };
    for (invalid_cases) |bad| {
        try std.testing.expectError(error.InvalidFieldType, decl.loadJsonIntoArena(
            std.testing.allocator,
            str_arena.allocator(),
            &arena,
            &table,
            bad,
        ));
    }

    // Valid finite large integer (.number_string in std.json) works cleanly
    const res = try decl.loadJsonIntoArena(
        std.testing.allocator,
        str_arena.allocator(),
        &arena,
        &table,
        "{\"type\":\"card\",\"id\":\"big\",\"max_width\":100000000000000000000}",
    );
    try std.testing.expectEqual(@as(usize, 1), res.node_count);
    const big_idx = arena.findByTestId("big").?.index;
    try std.testing.expect(std.math.isFinite(arena.nodes.items(.flex_props)[big_idx].max_width));
}

test "Exact MAX_NESTING_DEPTH boundary, MAX_JSON_BYTES, and MAX_STRING_LEN enforcement" {
    var arena = core.LayoutArena.init(std.testing.allocator);
    defer arena.deinit();
    var str_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer str_arena.deinit();
    const table = tokens.TokenTable.nordDefault();

    // Helper buffer for nested JSON: depth=31 (32 nodes total, depths 0..31) MUST PASS
    var buf_ok: std.ArrayList(u8) = .empty;
    defer buf_ok.deinit(std.testing.allocator);
    for (0..decl.MAX_NESTING_DEPTH - 1) |_| {
        try buf_ok.appendSlice(std.testing.allocator, "{\"type\":\"vstack\",\"children\":[");
    }
    try buf_ok.appendSlice(std.testing.allocator, "{\"type\":\"card\",\"id\":\"deepest\"}");
    for (0..decl.MAX_NESTING_DEPTH - 1) |_| {
        try buf_ok.appendSlice(std.testing.allocator, "]}");
    }
    const ok_res = try decl.loadJsonIntoArena(
        std.testing.allocator,
        str_arena.allocator(),
        &arena,
        &table,
        buf_ok.items,
    );
    try std.testing.expectEqual(decl.MAX_NESTING_DEPTH, ok_res.node_count);
    try std.testing.expect(arena.findByTestId("deepest") != null);

    // depth=32 (33 nodes total, depths 0..32) MUST FAIL with MaxDepthExceeded
    var buf_bad: std.ArrayList(u8) = .empty;
    defer buf_bad.deinit(std.testing.allocator);
    for (0..decl.MAX_NESTING_DEPTH) |_| {
        try buf_bad.appendSlice(std.testing.allocator, "{\"type\":\"vstack\",\"children\":[");
    }
    try buf_bad.appendSlice(std.testing.allocator, "{\"type\":\"card\"}");
    for (0..decl.MAX_NESTING_DEPTH) |_| {
        try buf_bad.appendSlice(std.testing.allocator, "]}");
    }
    try std.testing.expectError(error.MaxDepthExceeded, decl.loadJsonIntoArena(
        std.testing.allocator,
        str_arena.allocator(),
        &arena,
        &table,
        buf_bad.items,
    ));

    // MAX_JSON_BYTES exceeded returns error.JsonTooLarge
    const too_large = try std.testing.allocator.alloc(u8, decl.MAX_JSON_BYTES + 1);
    defer std.testing.allocator.free(too_large);
    @memset(too_large, ' ');
    try std.testing.expectError(error.JsonTooLarge, decl.loadJsonIntoArena(
        std.testing.allocator,
        str_arena.allocator(),
        &arena,
        &table,
        too_large,
    ));

    // MAX_STRING_LEN exceeded returns error.InvalidFieldType (or clean LoadError), while exact MAX_STRING_LEN passes
    const max_str = try std.testing.allocator.alloc(u8, decl.MAX_STRING_LEN);
    defer std.testing.allocator.free(max_str);
    @memset(max_str, 'a');
    const ok_str_json = try std.fmt.allocPrint(std.testing.allocator, "{{\"type\":\"card\",\"label\":\"{s}\"}}", .{max_str});
    defer std.testing.allocator.free(ok_str_json);
    const ok_str_res = try decl.loadJsonIntoArena(
        std.testing.allocator,
        str_arena.allocator(),
        &arena,
        &table,
        ok_str_json,
    );
    try std.testing.expectEqual(@as(usize, 1), ok_str_res.node_count);

    const over_str = try std.testing.allocator.alloc(u8, decl.MAX_STRING_LEN + 1);
    defer std.testing.allocator.free(over_str);
    @memset(over_str, 'a');
    const bad_str_json = try std.fmt.allocPrint(std.testing.allocator, "{{\"type\":\"card\",\"label\":\"{s}\"}}", .{over_str});
    defer std.testing.allocator.free(bad_str_json);
    try std.testing.expectError(error.InvalidFieldType, decl.loadJsonIntoArena(
        std.testing.allocator,
        str_arena.allocator(),
        &arena,
        &table,
        bad_str_json,
    ));
}

test "Declarative JSON loader enforces MAX_NODES limit" {
    var arena = core.LayoutArena.init(std.testing.allocator);
    defer arena.deinit();
    var str_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer str_arena.deinit();
    const table = tokens.TokenTable.nordDefault();

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(std.testing.allocator);
    try buf.appendSlice(std.testing.allocator, "{\"type\":\"vstack\",\"children\":[");
    for (0..decl.MAX_NODES) |i| {
        if (i > 0) try buf.append(std.testing.allocator, ',');
        try buf.appendSlice(std.testing.allocator, "{\"type\":\"card\"}");
    }
    try buf.appendSlice(std.testing.allocator, "]}");

    // 1 root + MAX_NODES children = MAX_NODES + 1 nodes
    try std.testing.expectError(error.MaxNodesExceeded, decl.loadJsonIntoArena(
        std.testing.allocator,
        str_arena.allocator(),
        &arena,
        &table,
        buf.items,
    ));
    try std.testing.expect(arena.getRoot() == null);
    try std.testing.expectEqual(@as(usize, 0), arena.nodes.len);
}
