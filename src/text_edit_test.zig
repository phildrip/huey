const std = @import("std");
const te = @import("text_edit.zig");

test "TextEditor inserts UTF-8, moves by grapheme cluster (combining marks & emoji), and selects/deletes cleanly" {
    var ed = te.TextEditor.init(std.testing.allocator);
    defer ed.deinit();

    // Insert ASCII + multi-byte UTF-8 + combining mark ("e" + U+0301 acute) + 4-byte emoji
    try ed.insert("hi e\u{0301} 🚀");
    try std.testing.expectEqualStrings("hi e\u{0301} 🚀", ed.text());

    // Backspace once deletes the entire 4-byte emoji cleanly (valid UTF-8!)
    try ed.backspace();
    try std.testing.expectEqualStrings("hi e\u{0301} ", ed.text());
    try std.testing.expect(std.unicode.utf8ValidateSlice(ed.text()));

    // Backspace space, then backspace deletes the entire "e + combining acute" grapheme cluster!
    try ed.backspace();
    try ed.backspace();
    try std.testing.expectEqualStrings("hi ", ed.text());
    try std.testing.expect(std.unicode.utf8ValidateSlice(ed.text()));
}

test "TextEditor word movement, selection replace, and undo/redo stack work deterministically" {
    var ed = te.TextEditor.init(std.testing.allocator);
    defer ed.deinit();

    try ed.insert("hello zig world");
    // Move word-left with selection -> selects "world"
    ed.moveWordLeft(true);
    try std.testing.expectEqualStrings("world", ed.selectedText());

    // Typing replaces selection cleanly
    try ed.insert("stratifi");
    try std.testing.expectEqualStrings("hello zig stratifi", ed.text());

    // Undo restores "hello zig world", redo restores "hello zig stratifi"
    try std.testing.expect(try ed.undo());
    try std.testing.expectEqualStrings("hello zig world", ed.text());
    try std.testing.expect(try ed.redo());
    try std.testing.expectEqualStrings("hello zig stratifi", ed.text());
}

test "TextEditor handles ZWJ emoji sequences, skin tones, variation selectors, and regional indicators as single graphemes" {
    var ed = te.TextEditor.init(std.testing.allocator);
    defer ed.deinit();

    // Family ZWJ sequence + technologist ZWJ sequence + skin-tone wave + two flags
    try ed.insert("a👨‍👩‍👧👩‍💻👋🏽🇺🇸🇬🇧b");
    try std.testing.expectEqual(@as(usize, 0), te.prevGraphemeBoundary(ed.text(), 0));
    try std.testing.expectEqual(ed.text().len, te.nextGraphemeBoundary(ed.text(), ed.text().len));

    // Delete 'b'
    try ed.backspace();
    try std.testing.expectEqualStrings("a👨‍👩‍👧👩‍💻👋🏽🇺🇸🇬🇧", ed.text());

    // Delete second flag 🇬🇧 as 1 grapheme (leaving 🇺🇸 intact)
    try ed.backspace();
    try std.testing.expectEqualStrings("a👨‍👩‍👧👩‍💻👋🏽🇺🇸", ed.text());
    try std.testing.expect(std.unicode.utf8ValidateSlice(ed.text()));

    // Delete first flag 🇺🇸 as 1 grapheme
    try ed.backspace();
    try std.testing.expectEqualStrings("a👨‍👩‍👧👩‍💻👋🏽", ed.text());

    // Delete skin-tone emoji 👋🏽 as 1 grapheme
    try ed.backspace();
    try std.testing.expectEqualStrings("a👨‍👩‍👧👩‍💻", ed.text());

    // Delete ZWJ sequence 👩‍💻 as 1 grapheme
    try ed.backspace();
    try std.testing.expectEqualStrings("a👨‍👩‍👧", ed.text());

    // Delete ZWJ sequence 👨‍👩‍👧 as 1 grapheme
    try ed.backspace();
    try std.testing.expectEqualStrings("a", ed.text());
    try std.testing.expect(std.unicode.utf8ValidateSlice(ed.text()));

    // Verify variation selector + combining mark (rainbow flag 🏳️‍🌈 + keycap 1️⃣) via deleteForward
    try ed.insert("🏳️‍🌈1️⃣z");
    ed.moveHome(false);
    ed.moveRight(false); // past 'a'
    try ed.deleteForward(); // deletes entire 🏳️‍🌈
    try std.testing.expectEqualStrings("a1️⃣z", ed.text());
    try ed.deleteForward(); // deletes entire 1️⃣
    try std.testing.expectEqualStrings("az", ed.text());
}

test "TextEditor handles CRLF as a single grapheme cluster on move and delete" {
    var ed = te.TextEditor.init(std.testing.allocator);
    defer ed.deinit();

    try ed.insert("ab\r\ncd");
    // Move left from end: 'd' (5), 'c' (4), '\r\n' (2)
    ed.moveLeft(false);
    try std.testing.expectEqual(@as(usize, 5), ed.cursor);
    ed.moveLeft(false);
    try std.testing.expectEqual(@as(usize, 4), ed.cursor);
    ed.moveLeft(false);
    try std.testing.expectEqual(@as(usize, 2), ed.cursor);

    // Move right with selection over '\r\n'
    ed.moveRight(true);
    try std.testing.expectEqualStrings("\r\n", ed.selectedText());
    try std.testing.expectEqual([2]usize{ 2, 4 }, ed.selectionRange());

    // Collapse right and backspace deletes '\r\n' as 1 grapheme
    ed.moveRight(false);
    try std.testing.expect(!ed.hasSelection());
    try std.testing.expectEqual(@as(usize, 4), ed.cursor);
    try ed.backspace();
    try std.testing.expectEqualStrings("abcd", ed.text());
    try std.testing.expectEqual(@as(usize, 2), ed.cursor);

    // Re-insert CRLF and test deleteForward across '\r\n'
    try ed.insert("\r\n");
    ed.moveLeft(false);
    try std.testing.expectEqual(@as(usize, 2), ed.cursor);
    try ed.deleteForward();
    try std.testing.expectEqualStrings("abcd", ed.text());
}

test "TextEditor navigation, selection, deleteForward, and InvalidUtf8 guard" {
    var ed = te.TextEditor.init(std.testing.allocator);
    defer ed.deinit();

    try ed.insert("alpha beta gamma");

    // moveHome / moveEnd / moveLeft / moveRight / selectAll
    ed.moveHome(false);
    try std.testing.expectEqual(@as(usize, 0), ed.cursor);
    ed.moveWordRight(true);
    try std.testing.expectEqualStrings("alpha", ed.selectedText());

    // moveLeft(false) collapses selection to start
    ed.moveLeft(false);
    try std.testing.expect(!ed.hasSelection());
    try std.testing.expectEqual(@as(usize, 0), ed.cursor);

    // deleteForward at start deletes 'a'
    try ed.deleteForward();
    try std.testing.expectEqualStrings("lpha beta gamma", ed.text());

    // moveEnd(true) from current cursor selects to end
    ed.moveEnd(true);
    try std.testing.expectEqualStrings("lpha beta gamma", ed.selectedText());

    // Invalid UTF-8 must fail without altering text, selection, or undo history
    const bad_utf8 = [_]u8{ 0xFF, 0xFE, 0x80 };
    try std.testing.expectError(error.InvalidUtf8, ed.insert(&bad_utf8));
    try std.testing.expectEqualStrings("lpha beta gamma", ed.text());
    try std.testing.expectEqualStrings("lpha beta gamma", ed.selectedText());

    // selectAll + deleteForward clears buffer
    ed.moveHome(false);
    ed.selectAll();
    try std.testing.expect(ed.hasSelection());
    try ed.deleteForward();
    try std.testing.expectEqualStrings("", ed.text());
    try std.testing.expect(!ed.hasSelection());

    // deleteForward at end and backspace at start are no-ops
    try ed.deleteForward();
    try ed.backspace();
    try std.testing.expectEqualStrings("", ed.text());
}

test "TextEditor enforces MAX_UNDO cap without memory leaks and clears redo on new edit" {
    var ed = te.TextEditor.init(std.testing.allocator);
    defer ed.deinit();

    // Perform more than MAX_UNDO (64) edits: 80 single-char inserts
    const total_edits: usize = te.MAX_UNDO + 16;
    for (0..total_edits) |i| {
        const ch = [1]u8{@intCast('a' + (i % 26))};
        try ed.insert(&ch);
    }
    try std.testing.expectEqual(total_edits, ed.text().len);

    // Undo up to MAX_UNDO times succeeds; the 65th undo returns false
    var undo_count: usize = 0;
    while (try ed.undo()) {
        undo_count += 1;
    }
    try std.testing.expectEqual(te.MAX_UNDO, undo_count);
    try std.testing.expectEqual(total_edits - te.MAX_UNDO, ed.text().len);

    // Redo restores a couple steps, then a new edit clears the redo stack
    try std.testing.expect(try ed.redo());
    try std.testing.expect(try ed.redo());
    try ed.insert("!");
    try std.testing.expect(!(try ed.redo()));
}

fn expectGraphemeSymmetry(buf: []const u8) !void {
    var fwd_bounds: std.ArrayList(usize) = .empty;
    defer fwd_bounds.deinit(std.testing.allocator);
    try fwd_bounds.append(std.testing.allocator, 0);
    var pos: usize = 0;
    while (pos < buf.len) {
        const nxt = te.nextGraphemeBoundary(buf, pos);
        try std.testing.expect(nxt > pos);
        try fwd_bounds.append(std.testing.allocator, nxt);
        pos = nxt;
    }
    try std.testing.expectEqual(buf.len, pos);

    var rev_bounds: std.ArrayList(usize) = .empty;
    defer rev_bounds.deinit(std.testing.allocator);
    try rev_bounds.append(std.testing.allocator, buf.len);
    pos = buf.len;
    while (pos > 0) {
        const prv = te.prevGraphemeBoundary(buf, pos);
        try std.testing.expect(prv < pos);
        try rev_bounds.append(std.testing.allocator, prv);
        pos = prv;
    }
    try std.testing.expectEqual(@as(usize, 0), pos);

    try std.testing.expectEqual(fwd_bounds.items.len, rev_bounds.items.len);
    for (fwd_bounds.items, 0..) |b, idx| {
        try std.testing.expectEqual(b, rev_bounds.items[rev_bounds.items.len - 1 - idx]);
    }
}

test "Grapheme boundaries snap mid-UTF-8 pos to codepoint boundaries and handle invalid UTF-8 safely" {
    const rocket = "🚀";
    try std.testing.expectEqual(@as(usize, 0), te.prevGraphemeBoundary(rocket, 1));
    try std.testing.expectEqual(@as(usize, 0), te.prevGraphemeBoundary(rocket, 2));
    try std.testing.expectEqual(@as(usize, 0), te.prevGraphemeBoundary(rocket, 3));
    try std.testing.expectEqual(@as(usize, 4), te.nextGraphemeBoundary(rocket, 1));
    try std.testing.expectEqual(@as(usize, 4), te.nextGraphemeBoundary(rocket, 2));
    try std.testing.expectEqual(@as(usize, 4), te.nextGraphemeBoundary(rocket, 3));

    const prefixed = "a🚀";
    try std.testing.expectEqual(@as(usize, 1), te.prevGraphemeBoundary(prefixed, 3));
    try std.testing.expectEqual(@as(usize, 5), te.nextGraphemeBoundary(prefixed, 3));

    // Invalid UTF-8 continuation/high bytes (0x80..0x9F must not be treated as C1 control or raw byte)
    const raw_invalid = [_]u8{ 0x80, 0xFF, 'a' };
    try expectGraphemeSymmetry(&raw_invalid);
}

test "Grapheme boundary forward/backward symmetry on double-ZWJ, RI+ZWJ, triple-RI, ZWNJ, and tag sequences" {
    try expectGraphemeSymmetry("👨\u{200D}\u{200D}👩");
    try expectGraphemeSymmetry("🇦\u{200D}👨");
    try expectGraphemeSymmetry("🇦🇧🇨");
    try expectGraphemeSymmetry("👨\u{200C}👩");
    try expectGraphemeSymmetry("🏴󠁧󠁢󠁥󠁮󠁧󠁿");
}

test "TextEditor insert(ed.selectedText()) and insert(ed.text()) self-aliasing safety" {
    var ed = te.TextEditor.init(std.testing.allocator);
    defer ed.deinit();

    try ed.insert("hello world");
    ed.moveWordLeft(true);
    try std.testing.expectEqualStrings("world", ed.selectedText());
    try ed.insert(ed.selectedText());
    try std.testing.expectEqualStrings("hello world", ed.text());

    // Self-aliasing insert that also grows and reallocates `buf`
    ed.moveEnd(false);
    try ed.insert(ed.text());
    try std.testing.expectEqualStrings("hello worldhello world", ed.text());

    // Repeating enough times to force heap reallocation during self-aliasing insert
    for (0..4) |_| {
        ed.moveEnd(false);
        try ed.insert(ed.text());
    }
    try std.testing.expectEqual(@as(usize, 22 * 16), ed.text().len);
    try std.testing.expect(std.unicode.utf8ValidateSlice(ed.text()));
}

test "TextEditor backspace and deleteForward are OOM-atomic and undo/redo restore exact text, cursor, and anchor" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var ed = te.TextEditor.init(failing.allocator());
    defer ed.deinit();

    try ed.insert("hello");
    try ed.insert(" world");
    ed.moveWordLeft(true); // anchor = 11, cursor = 6, selectedText = "world"
    try std.testing.expectEqualStrings("world", ed.selectedText());

    // Trigger OOM on next allocation inside backspace()
    failing.fail_index = failing.alloc_index;
    try std.testing.expectError(error.OutOfMemory, ed.backspace());

    // State, selection, and undo/redo must remain completely intact after OOM
    try std.testing.expectEqualStrings("hello world", ed.text());
    try std.testing.expectEqual(@as(usize, 6), ed.cursor);
    try std.testing.expectEqual(@as(usize, 11), ed.anchor);

    // Also test OOM atomicity on deleteForward()
    failing.fail_index = failing.alloc_index;
    try std.testing.expectError(error.OutOfMemory, ed.deleteForward());
    try std.testing.expectEqualStrings("hello world", ed.text());
    try std.testing.expectEqual(@as(usize, 6), ed.cursor);
    try std.testing.expectEqual(@as(usize, 11), ed.anchor);

    // Lift OOM fault and verify backspace() + undo()/redo() restore exact cursor & anchor
    failing.fail_index = std.math.maxInt(usize);
    try ed.backspace();
    try std.testing.expectEqualStrings("hello ", ed.text());
    try std.testing.expectEqual(@as(usize, 6), ed.cursor);
    try std.testing.expectEqual(@as(usize, 6), ed.anchor);

    try std.testing.expect(try ed.undo());
    try std.testing.expectEqualStrings("hello world", ed.text());
    try std.testing.expectEqual(@as(usize, 6), ed.cursor);
    try std.testing.expectEqual(@as(usize, 11), ed.anchor);
    try std.testing.expectEqualStrings("world", ed.selectedText());

    try std.testing.expect(try ed.redo());
    try std.testing.expectEqualStrings("hello ", ed.text());
    try std.testing.expectEqual(@as(usize, 6), ed.cursor);
    try std.testing.expectEqual(@as(usize, 6), ed.anchor);
}
