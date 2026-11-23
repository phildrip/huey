const std = @import("std");
const text_input = @import("widgets/text_input.zig");
const core = @import("core.zig");
const tokens = @import("tokens.zig");

test "TextInput: uppercase filter, max_len=17 VIN entry, selection & caret blink" {
    const alloc = std.testing.allocator;
    var inp = try text_input.TextInput.init(alloc, .{
        .placeholder = "Enter 17-char VIN",
        .max_len = 17,
        .uppercase = true,
    });
    defer inp.deinit();

    inp.setFocused(true);
    try inp.insertText("5yj3e1ea7lf000001extra");
    // Uppercased and clamped to 17 chars!
    try std.testing.expectEqualStrings("5YJ3E1EA7LF000001", inp.text());
    try std.testing.expectEqual(@as(usize, 17), inp.text().len);

    // Caret blink toggles cleanly
    try std.testing.expect(inp.caretVisible());
    _ = inp.stepBlink(0.6);
    try std.testing.expect(!inp.caretVisible());

    // Emits border/fill + caret quads cleanly
    const tbl = tokens.TokenTable.nordDefault();
    var quads: [64]core.QuadInstance = undefined;
    const n = inp.emitQuads(.{ .x = 20, .y = 40, .w = 220, .h = 48 }, 2.0, &tbl, &quads, .{ 0, 0, 800, 800 });
    try std.testing.expect(n >= 1);
}

test "TextInput: password masking & InputOtp segmented boxes" {
    const alloc = std.testing.allocator;
    var pw = try text_input.TextInput.init(alloc, .{ .password = true });
    defer pw.deinit();
    try pw.insertText("secret");
    var mask_buf: [32]u8 = undefined;
    const display = pw.displayText(&mask_buf);
    try std.testing.expectEqualStrings("******", display);

    // InputOtp 6-digit code
    var otp = text_input.InputOtp.init(6);
    try std.testing.expect(otp.pushDigit('4'));
    try std.testing.expect(otp.pushDigit('2'));
    try std.testing.expect(!otp.pushDigit('x')); // rejects non-digit
    try std.testing.expectEqualStrings("42", otp.slice());
    try std.testing.expect(!otp.isComplete());
    otp.paste("901234");
    try std.testing.expect(otp.isComplete());
    try std.testing.expectEqualStrings("901234", otp.slice());
    otp.backspace();
    try std.testing.expectEqualStrings("90123", otp.slice());
}

test "TextArea: multi-line insert, newline, and line count" {
    const alloc = std.testing.allocator;
    var ta = try text_input.TextArea.init(alloc, .{ .max_len = 256 });
    defer ta.deinit();
    try ta.insertText("Line 1\nLine 2\nLine 3");
    try std.testing.expectEqual(@as(usize, 3), ta.lineCount());
}

test "C1/M5: stepBlink handles huge finite dt_s (1e9, 1e20) without UB" {
    const alloc = std.testing.allocator;
    var inp = try text_input.TextInput.init(alloc, .{});
    defer inp.deinit();
    inp.setFocused(true);

    _ = inp.stepBlink(1e9);
    try std.testing.expect(std.math.isFinite(inp.blink_accum_s));
    try std.testing.expect(inp.blink_accum_s >= 0.0 and inp.blink_accum_s < text_input.BLINK_PERIOD_S);

    _ = inp.stepBlink(1e20);
    try std.testing.expect(std.math.isFinite(inp.blink_accum_s));
    try std.testing.expect(inp.blink_accum_s >= 0.0 and inp.blink_accum_s < text_input.BLINK_PERIOD_S);

    // Subsequent normal dt still advances cleanly
    var ta = try text_input.TextArea.init(alloc, .{});
    defer ta.deinit();
    ta.setFocused(true);
    _ = ta.stepBlink(1e20);
    try std.testing.expect(std.math.isFinite(ta.blink_accum_s));
    try std.testing.expect(ta.blink_accum_s >= 0.0 and ta.blink_accum_s < text_input.BLINK_PERIOD_S);
}

test "H2: TextInput strips CR and LF without OOM on oversized input" {
    const alloc = std.testing.allocator;
    var inp = try text_input.TextInput.init(alloc, .{ .max_len = 8 });
    defer inp.deinit();

    try inp.insertText("ab\r\ncd\nef\rghijkl");
    try std.testing.expectEqualStrings("abcdefgh", inp.text());
    try std.testing.expect(std.mem.indexOfAny(u8, inp.text(), "\r\n") == null);
}

test "M4: 0-byte clamp preserves existing selection" {
    const alloc = std.testing.allocator;
    var inp = try text_input.TextInput.init(alloc, .{ .max_len = 5 });
    defer inp.deinit();

    try inp.insertText("abcde");
    inp.moveLeft(true); // selects "e" (kept_len = 4, avail_bytes = 1)
    try std.testing.expectEqualStrings("e", inp.editor.selectedText());

    // 3-byte codepoint doesn't fit in 1 byte -> 0-byte insertable slice -> selection preserved
    try inp.insertText("€");
    try std.testing.expectEqualStrings("abcde", inp.text());
    try std.testing.expectEqualStrings("e", inp.editor.selectedText());

    // Stripped to 0 bytes -> selection preserved
    try inp.insertText("\r\n");
    try std.testing.expectEqualStrings("abcde", inp.text());
    try std.testing.expectEqualStrings("e", inp.editor.selectedText());

    // avail_bytes == 0 with selection -> selection preserved
    var capped = try text_input.TextInput.init(alloc, .{ .max_len = 4 });
    defer capped.deinit();
    try capped.insertText("abcd");
    try std.testing.expectEqualStrings("abcd", capped.text());
    capped.cfg.max_len = 3; // kept_len = 3 with 1-char selection -> avail_bytes = 0
    capped.moveLeft(true);
    try capped.insertText("z");
    try std.testing.expectEqualStrings("abcd", capped.text());
    try std.testing.expectEqualStrings("d", capped.editor.selectedText());
}

test "H3: overflow auto-scroll keeps caret and selection visible in TextInput and TextArea" {
    const alloc = std.testing.allocator;
    const tbl = tokens.TokenTable.nordDefault();
    var quads: [16]core.QuadInstance = undefined;

    // TextInput horizontal overflow
    var inp = try text_input.TextInput.init(alloc, .{ .max_len = 256 });
    defer inp.deinit();
    inp.setFocused(true);
    try inp.insertText("0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ");
    inp.moveLeft(true); // select 'Z' at the far right overflowed end
    const n_in = inp.emitQuads(.{ .x = 0, .y = 0, .w = 100, .h = 32 }, 1.0, &tbl, &quads, .{ 0, 0, 800, 800 });
    try std.testing.expectEqual(@as(usize, 3), n_in); // container + selection + caret
    // Caret quad (last) must lie strictly inside the input rect
    try std.testing.expect(quads[2].pos_size[0] >= 0.0 and quads[2].pos_size[0] + quads[2].pos_size[2] <= 100.0);

    // TextArea vertical overflow
    var ta = try text_input.TextArea.init(alloc, .{ .max_len = 512 });
    defer ta.deinit();
    ta.setFocused(true);
    try ta.insertText("L0\nL1\nL2\nL3\nL4\nL5\nL6\nL7\nL8\nL9");
    const n_ta = ta.emitQuads(.{ .x = 0, .y = 0, .w = 200, .h = 60 }, 1.0, &tbl, &quads, .{ 0, 0, 800, 800 });
    try std.testing.expectEqual(@as(usize, 2), n_ta); // container + caret
    try std.testing.expect(quads[1].pos_size[1] >= 0.0 and quads[1].pos_size[1] + quads[1].pos_size[3] <= 60.0);
}

test "M7: TextArea selection ending at col 0 excludes trailing empty line" {
    const alloc = std.testing.allocator;
    var ta = try text_input.TextArea.init(alloc, .{ .max_len = 256 });
    defer ta.deinit();
    try ta.insertText("Line 1\nLine 2");
    // Select exactly "Line 1\n" (cursor=7 -> line 1 col 0, anchor=0 -> line 0 col 0)
    ta.editor.anchor = 0;
    ta.editor.cursor = 7;

    const tbl = tokens.TokenTable.nordDefault();
    var quads: [16]core.QuadInstance = undefined;
    const n = ta.emitQuads(.{ .x = 0, .y = 0, .w = 200, .h = 100 }, 1.0, &tbl, &quads, .{ 0, 0, 800, 800 });
    try std.testing.expectEqual(@as(usize, 2), n); // container + selection (unfocused)
    // Selection height should be 1 line (20px), not 2 lines (40px)
    try std.testing.expectApproxEqAbs(@as(f32, 20.0), quads[1].pos_size[3], 1.0);
}

test "M6: clip_rect culling and IME cancel on blur/clear" {
    const alloc = std.testing.allocator;
    var inp = try text_input.TextInput.init(alloc, .{});
    defer inp.deinit();
    inp.setFocused(true);
    inp.ime.setPreedit("nihao", 0, 5);
    try std.testing.expect(inp.ime.composing);
    inp.setFocused(false);
    try std.testing.expect(!inp.ime.composing);

    inp.setFocused(true);
    inp.ime.setPreedit("ni", 0, 2);
    inp.clear();
    try std.testing.expect(!inp.ime.composing);

    var ta = try text_input.TextArea.init(alloc, .{});
    defer ta.deinit();
    ta.setFocused(true);
    ta.ime.setPreedit("ka", 0, 2);
    ta.setFocused(false);
    try std.testing.expect(!ta.ime.composing);
    ta.setFocused(true);
    ta.ime.setPreedit("ka", 0, 2);
    ta.clear();
    try std.testing.expect(!ta.ime.composing);

    const tbl = tokens.TokenTable.nordDefault();
    var quads: [16]core.QuadInstance = undefined;
    // Completely outside clip_rect -> 0 quads
    const n_culled = inp.emitQuads(.{ .x = 100, .y = 100, .w = 200, .h = 40 }, 1.0, &tbl, &quads, .{ 0, 0, 50, 50 });
    try std.testing.expectEqual(@as(usize, 0), n_culled);

    // Caret outside clip_rect while container intersects -> container only (1 quad)
    inp.setFocused(true);
    try inp.insertText("abcdefghij");
    const n_partial = inp.emitQuads(.{ .x = 0, .y = 0, .w = 200, .h = 40 }, 1.0, &tbl, &quads, .{ 0, 0, 30, 40 });
    try std.testing.expectEqual(@as(usize, 1), n_partial);
}

test "L9: InputOtp clamps target_len and ignores non-digit paste" {
    var otp0 = text_input.InputOtp.init(0);
    try std.testing.expectEqual(@as(u8, 1), otp0.target_len);
    try std.testing.expect(!otp0.isComplete());
    try std.testing.expect(otp0.pushDigit('7'));
    try std.testing.expect(otp0.isComplete());

    var otp = text_input.InputOtp.init(4);
    try std.testing.expect(otp.pushDigit('1'));
    try std.testing.expect(otp.pushDigit('2'));
    otp.paste("abc"); // no ASCII digits -> preserves "12"
    try std.testing.expectEqualStrings("12", otp.slice());

    // Direct struct literal with out-of-range target_len still bounds-clamps safely
    var huge = text_input.InputOtp{ .target_len = 250 };
    huge.paste("123456789012345");
    try std.testing.expectEqual(@as(usize, text_input.MAX_OTP), huge.slice().len);
    try std.testing.expect(!huge.pushDigit('9'));
    try std.testing.expect(huge.isComplete());
}

test "L11: TextInput and TextArea idempotent deinit" {
    const alloc = std.testing.allocator;
    var inp = try text_input.TextInput.init(alloc, .{});
    try inp.insertText("hello");
    inp.deinit();
    inp.deinit();

    var ta = try text_input.TextArea.init(alloc, .{});
    try ta.insertText("hello\nworld");
    ta.deinit();
    ta.deinit();
}
