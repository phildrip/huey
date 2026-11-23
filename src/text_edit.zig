const std = @import("std");

/// Maximum number of undo snapshots retained by `TextEditor`.
pub const MAX_UNDO: usize = 64;

const ZWJ: u21 = 0x200D;
const ZWNJ: u21 = 0x200C;
const REPLACEMENT_CHAR: u21 = 0xFFFD;

const DecodedNext = struct {
    cp: u21,
    end: usize,
};

const DecodedPrev = struct {
    cp: u21,
    start: usize,
};

const CodepointSpan = struct {
    start: usize,
    end: usize,
};

fn decodeNext(buf: []const u8, pos: usize) DecodedNext {
    std.debug.assert(pos < buf.len);
    const seq_len = std.unicode.utf8ByteSequenceLength(buf[pos]) catch {
        return .{ .cp = REPLACEMENT_CHAR, .end = pos + 1 };
    };
    if (pos + seq_len > buf.len) {
        return .{ .cp = REPLACEMENT_CHAR, .end = pos + 1 };
    }
    const cp = std.unicode.utf8Decode(buf[pos .. pos + seq_len]) catch {
        return .{ .cp = REPLACEMENT_CHAR, .end = pos + 1 };
    };
    return .{ .cp = cp, .end = pos + seq_len };
}

fn decodePrev(buf: []const u8, pos: usize) DecodedPrev {
    std.debug.assert(pos > 0);
    var start = pos - 1;
    var steps: usize = 0;
    while (start > 0 and steps < 3 and (buf[start] & 0xC0) == 0x80) : (steps += 1) {
        start -= 1;
    }
    const seq_len = std.unicode.utf8ByteSequenceLength(buf[start]) catch {
        return .{ .cp = REPLACEMENT_CHAR, .start = pos - 1 };
    };
    if (start + seq_len != pos) {
        return .{ .cp = REPLACEMENT_CHAR, .start = pos - 1 };
    }
    const cp = std.unicode.utf8Decode(buf[start..pos]) catch {
        return .{ .cp = REPLACEMENT_CHAR, .start = pos - 1 };
    };
    return .{ .cp = cp, .start = start };
}

fn enclosingCodepointSpan(buf: []const u8, pos: usize) ?CodepointSpan {
    if (pos == 0 or pos >= buf.len) return null;
    if ((buf[pos] & 0xC0) != 0x80) return null;

    var start = pos;
    var steps: usize = 0;
    while (start > 0 and steps < 3 and (buf[start] & 0xC0) == 0x80) : (steps += 1) {
        start -= 1;
    }
    if ((buf[start] & 0xC0) == 0x80) return null;
    const seq_len = std.unicode.utf8ByteSequenceLength(buf[start]) catch return null;
    const end = start + seq_len;
    if (end > buf.len or pos >= end) return null;
    _ = std.unicode.utf8Decode(buf[start..end]) catch return null;
    return .{ .start = start, .end = end };
}

fn isCombiningMark(cp: u21) bool {
    return (cp >= 0x0300 and cp <= 0x036F) or
        (cp >= 0x1AB0 and cp <= 0x1AFF) or
        (cp >= 0x1DC0 and cp <= 0x1DFF) or
        (cp >= 0x20D0 and cp <= 0x20FF) or
        (cp >= 0xFE20 and cp <= 0xFE2F);
}

fn isVariationSelector(cp: u21) bool {
    return (cp >= 0xFE00 and cp <= 0xFE0F) or
        (cp >= 0xE0100 and cp <= 0xE01EF);
}

fn isSkinToneModifier(cp: u21) bool {
    return cp >= 0x1F3FB and cp <= 0x1F3FF;
}

fn isEmojiTag(cp: u21) bool {
    return cp >= 0xE0020 and cp <= 0xE007F;
}

fn isRegionalIndicator(cp: u21) bool {
    return cp >= 0x1F1E6 and cp <= 0x1F1FF;
}

fn isGraphemeExtend(cp: u21) bool {
    return isCombiningMark(cp) or
        isVariationSelector(cp) or
        isSkinToneModifier(cp) or
        cp == ZWNJ or
        isEmojiTag(cp);
}

fn isCrLfOrControl(cp: u21) bool {
    return cp == '\r' or cp == '\n' or cp < 0x20 or cp == 0x7F or (cp >= 0x80 and cp <= 0x9F);
}

fn countPrecedingRegionalIndicators(buf: []const u8, pos: usize) usize {
    var count: usize = 0;
    var scan = pos;
    while (scan > 0) {
        const p = decodePrev(buf, scan);
        if (!isRegionalIndicator(p.cp)) break;
        count += 1;
        scan = p.start;
    }
    return count;
}

/// Returns the byte offset of the grapheme cluster boundary immediately before `pos`
/// (UAX #29 practical subset: combining marks, variation selectors, ZWJ/ZWNJ sequences,
/// skin-tone modifiers, emoji tag sequences, regional indicator pairs, and CRLF).
pub fn prevGraphemeBoundary(buf: []const u8, raw_pos: usize) usize {
    var pos = @min(raw_pos, buf.len);
    if (pos == 0) return 0;
    if (enclosingCodepointSpan(buf, pos)) |span| {
        pos = span.end;
    }

    if (buf[pos - 1] == '\n') {
        if (pos >= 2 and buf[pos - 2] == '\r') {
            return pos - 2;
        }
        return pos - 1;
    }

    var cur = pos;
    const last = decodePrev(buf, cur);
    cur = last.start;

    if (isCrLfOrControl(last.cp)) {
        return cur;
    }

    if (isRegionalIndicator(last.cp)) {
        const ri_before = countPrecedingRegionalIndicators(buf, cur);
        if (ri_before % 2 == 1 and cur > 0) {
            cur = decodePrev(buf, cur).start;
        }
        return cur;
    }

    var need_base = isGraphemeExtend(last.cp) or (last.cp == ZWJ);
    while (cur > 0) {
        const p = decodePrev(buf, cur);
        if (need_base) {
            if (isCrLfOrControl(p.cp)) {
                break;
            }
            cur = p.start;
            if (isRegionalIndicator(p.cp)) {
                const ri_before = countPrecedingRegionalIndicators(buf, cur);
                if (ri_before % 2 == 1 and cur > 0) {
                    cur = decodePrev(buf, cur).start;
                }
                break;
            }
            if (isGraphemeExtend(p.cp) or p.cp == ZWJ) {
                continue;
            }
            need_base = false;
            continue;
        } else {
            if (p.cp == ZWJ and p.start > 0) {
                const before_zwj = decodePrev(buf, p.start);
                if (!isCrLfOrControl(before_zwj.cp) and !isRegionalIndicator(before_zwj.cp) and before_zwj.cp != ZWJ) {
                    cur = p.start;
                    need_base = true;
                    continue;
                }
            }
            break;
        }
    }

    return cur;
}

/// Returns the byte offset of the grapheme cluster boundary immediately after `pos`
/// (UAX #29 practical subset: combining marks, variation selectors, ZWJ/ZWNJ sequences,
/// skin-tone modifiers, emoji tag sequences, regional indicator pairs, and CRLF).
pub fn nextGraphemeBoundary(buf: []const u8, raw_pos: usize) usize {
    var pos = @min(raw_pos, buf.len);
    if (pos >= buf.len) return buf.len;
    if (enclosingCodepointSpan(buf, pos)) |span| {
        pos = span.start;
    }

    if (buf[pos] == '\r') {
        if (pos + 1 < buf.len and buf[pos + 1] == '\n') {
            return pos + 2;
        }
        return pos + 1;
    }

    const first = decodeNext(buf, pos);
    var cur = first.end;
    var prev_cp = first.cp;

    if (isCrLfOrControl(first.cp)) {
        return cur;
    }

    if (isRegionalIndicator(first.cp)) {
        const ri_before = countPrecedingRegionalIndicators(buf, pos);
        if (ri_before % 2 == 0 and cur < buf.len) {
            const nxt = decodeNext(buf, cur);
            if (isRegionalIndicator(nxt.cp)) {
                cur = nxt.end;
                prev_cp = nxt.cp;
            }
        }
    }

    while (cur < buf.len) {
        const nxt = decodeNext(buf, cur);
        if (isGraphemeExtend(nxt.cp)) {
            cur = nxt.end;
            prev_cp = nxt.cp;
            continue;
        }
        if (nxt.cp == ZWJ) {
            const can_join_after = !isCrLfOrControl(prev_cp) and !isRegionalIndicator(prev_cp) and prev_cp != ZWJ;
            cur = nxt.end;
            prev_cp = ZWJ;
            if (can_join_after and cur < buf.len) {
                const after_zwj = decodeNext(buf, cur);
                if (!isCrLfOrControl(after_zwj.cp) and !isRegionalIndicator(after_zwj.cp) and after_zwj.cp != ZWJ) {
                    cur = after_zwj.end;
                    prev_cp = after_zwj.cp;
                    continue;
                }
            }
            continue;
        }
        break;
    }

    return cur;
}

const CharClass = enum {
    whitespace,
    word,
    symbol,
};

fn isWhitespaceCp(cp: u21) bool {
    return cp == ' ' or
        cp == '\t' or
        cp == '\n' or
        cp == '\r' or
        cp == 0x0B or
        cp == 0x0C or
        cp == 0x00A0 or
        (cp >= 0x2000 and cp <= 0x200A) or
        cp == 0x2028 or
        cp == 0x2029 or
        cp == 0x202F or
        cp == 0x205F or
        cp == 0x3000;
}

fn classifyCodepoint(cp: u21) CharClass {
    if (isWhitespaceCp(cp)) return .whitespace;
    if ((cp >= 'a' and cp <= 'z') or
        (cp >= 'A' and cp <= 'Z') or
        (cp >= '0' and cp <= '9') or
        cp == '_')
    {
        return .word;
    }
    if (cp < 0x80) return .symbol;
    // Non-ASCII general punctuation and emoji/symbol blocks act as symbols;
    // alphabetic/CJK/Hangul scripts act as word characters.
    if ((cp >= 0x2000 and cp <= 0x206F) or
        (cp >= 0x2190 and cp <= 0x27BF) or
        (cp >= 0x2E00 and cp <= 0x2E7F) or
        (cp >= 0x3001 and cp <= 0x303F) or
        (cp >= 0x1F000 and cp <= 0x1FAFF))
    {
        return .symbol;
    }
    return .word;
}

fn graphemeClassAt(buf: []const u8, start: usize) CharClass {
    const first = decodeNext(buf, start);
    return classifyCodepoint(first.cp);
}

/// Moves backward across whitespace and then across one contiguous word or symbol run.
pub fn prevWordBoundary(buf: []const u8, raw_pos: usize) usize {
    var cur = @min(raw_pos, buf.len);
    if (enclosingCodepointSpan(buf, cur)) |span| {
        cur = span.end;
    }
    while (cur > 0) {
        const prev = prevGraphemeBoundary(buf, cur);
        if (graphemeClassAt(buf, prev) != .whitespace) break;
        cur = prev;
    }
    if (cur == 0) return 0;

    const prev0 = prevGraphemeBoundary(buf, cur);
    const target_class = graphemeClassAt(buf, prev0);
    cur = prev0;

    while (cur > 0) {
        const prev = prevGraphemeBoundary(buf, cur);
        if (graphemeClassAt(buf, prev) != target_class) break;
        cur = prev;
    }
    return cur;
}

/// Moves forward across whitespace and then across one contiguous word or symbol run.
pub fn nextWordBoundary(buf: []const u8, raw_pos: usize) usize {
    var cur = @min(raw_pos, buf.len);
    if (enclosingCodepointSpan(buf, cur)) |span| {
        cur = span.start;
    }
    while (cur < buf.len) {
        if (graphemeClassAt(buf, cur) != .whitespace) break;
        cur = nextGraphemeBoundary(buf, cur);
    }
    if (cur >= buf.len) return buf.len;

    const target_class = graphemeClassAt(buf, cur);
    cur = nextGraphemeBoundary(buf, cur);

    while (cur < buf.len) {
        if (graphemeClassAt(buf, cur) != target_class) break;
        cur = nextGraphemeBoundary(buf, cur);
    }
    return cur;
}

const Snapshot = struct {
    text: []u8,
    cursor: usize,
    anchor: usize,
};

/// Single-buffer UTF-8 text editor with grapheme-aware caret navigation,
/// anchor/cursor selection, word-boundary movement, and bounded undo/redo.
pub const TextEditor = struct {
    allocator: std.mem.Allocator,
    buf: std.ArrayList(u8) = .empty,
    cursor: usize = 0,
    anchor: usize = 0,
    undo_stack: std.ArrayList(Snapshot) = .empty,
    redo_stack: std.ArrayList(Snapshot) = .empty,

    pub fn init(allocator: std.mem.Allocator) TextEditor {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *TextEditor) void {
        self.clearStack(&self.undo_stack);
        self.clearStack(&self.redo_stack);
        self.undo_stack.deinit(self.allocator);
        self.redo_stack.deinit(self.allocator);
        self.buf.deinit(self.allocator);
    }

    pub fn text(self: *const TextEditor) []const u8 {
        return self.buf.items;
    }

    pub fn hasSelection(self: *const TextEditor) bool {
        return self.cursor != self.anchor;
    }

    pub fn selectionRange(self: *const TextEditor) [2]usize {
        return .{
            @min(self.cursor, self.anchor),
            @max(self.cursor, self.anchor),
        };
    }

    pub fn selectedText(self: *const TextEditor) []const u8 {
        const range = self.selectionRange();
        return self.buf.items[range[0]..range[1]];
    }

    /// Validates UTF-8, records an undo snapshot, replaces any active selection,
    /// and inserts `str` at the caret.
    pub fn insert(self: *TextEditor, str: []const u8) !void {
        if (!std.unicode.utf8ValidateSlice(str)) return error.InvalidUtf8;
        if (str.len == 0 and !self.hasSelection()) return;

        const snap_text = try self.allocator.dupe(u8, self.buf.items);
        errdefer self.allocator.free(snap_text);
        if (self.undo_stack.items.len < MAX_UNDO) {
            try self.undo_stack.ensureUnusedCapacity(self.allocator, 1);
        }

        // Re-slice `str` into `snap_text` when it aliases `self.buf.items`.
        var safe_str = str;
        if (str.len > 0 and self.buf.items.len > 0) {
            const buf_start = @intFromPtr(self.buf.items.ptr);
            const buf_end = buf_start + self.buf.items.len;
            const str_start = @intFromPtr(str.ptr);
            const str_end = str_start + str.len;
            if (str_start >= buf_start and str_end <= buf_end) {
                const offset = str_start - buf_start;
                safe_str = snap_text[offset .. offset + str.len];
            }
        }

        const range = self.selectionRange();
        const sel_len = range[1] - range[0];
        try self.buf.replaceRange(self.allocator, range[0], sel_len, safe_str);

        self.pushPreparedSnapshot(&self.undo_stack, .{
            .text = snap_text,
            .cursor = self.cursor,
            .anchor = self.anchor,
        });
        self.clearStack(&self.redo_stack);

        const new_pos = range[0] + safe_str.len;
        self.cursor = new_pos;
        self.anchor = new_pos;
    }

    /// Deletes the active selection or one grapheme cluster before the caret.
    pub fn backspace(self: *TextEditor) !void {
        if (self.hasSelection()) {
            const range = self.selectionRange();
            try self.deleteByteRange(range[0], range[1]);
            return;
        }
        if (self.cursor == 0) return;
        const prev = prevGraphemeBoundary(self.buf.items, self.cursor);
        try self.deleteByteRange(prev, self.cursor);
    }

    /// Deletes the active selection or one grapheme cluster after the caret.
    pub fn deleteForward(self: *TextEditor) !void {
        if (self.hasSelection()) {
            const range = self.selectionRange();
            try self.deleteByteRange(range[0], range[1]);
            return;
        }
        if (self.cursor >= self.buf.items.len) return;
        const next = nextGraphemeBoundary(self.buf.items, self.cursor);
        try self.deleteByteRange(self.cursor, next);
    }

    pub fn moveLeft(self: *TextEditor, extend_sel: bool) void {
        if (!extend_sel and self.hasSelection()) {
            const range = self.selectionRange();
            self.cursor = range[0];
            self.anchor = range[0];
            return;
        }
        self.cursor = prevGraphemeBoundary(self.buf.items, self.cursor);
        if (!extend_sel) self.anchor = self.cursor;
    }

    pub fn moveRight(self: *TextEditor, extend_sel: bool) void {
        if (!extend_sel and self.hasSelection()) {
            const range = self.selectionRange();
            self.cursor = range[1];
            self.anchor = range[1];
            return;
        }
        self.cursor = nextGraphemeBoundary(self.buf.items, self.cursor);
        if (!extend_sel) self.anchor = self.cursor;
    }

    pub fn moveWordLeft(self: *TextEditor, extend_sel: bool) void {
        self.cursor = prevWordBoundary(self.buf.items, self.cursor);
        if (!extend_sel) self.anchor = self.cursor;
    }

    pub fn moveWordRight(self: *TextEditor, extend_sel: bool) void {
        self.cursor = nextWordBoundary(self.buf.items, self.cursor);
        if (!extend_sel) self.anchor = self.cursor;
    }

    pub fn moveHome(self: *TextEditor, extend_sel: bool) void {
        self.cursor = 0;
        if (!extend_sel) self.anchor = self.cursor;
    }

    pub fn moveEnd(self: *TextEditor, extend_sel: bool) void {
        self.cursor = self.buf.items.len;
        if (!extend_sel) self.anchor = self.cursor;
    }

    pub fn selectAll(self: *TextEditor) void {
        self.anchor = 0;
        self.cursor = self.buf.items.len;
    }

    /// Restores the previous snapshot (text, cursor, anchor) and pushes the current
    /// state onto the redo stack. Returns `false` when the undo stack is empty.
    pub fn undo(self: *TextEditor) !bool {
        return self.transferSnapshot(&self.undo_stack, &self.redo_stack);
    }

    /// Re-applies the next snapshot (text, cursor, anchor) from the redo stack
    /// and pushes the current state onto the undo stack. Returns `false` when empty.
    pub fn redo(self: *TextEditor) !bool {
        return self.transferSnapshot(&self.redo_stack, &self.undo_stack);
    }

    fn deleteByteRange(self: *TextEditor, start: usize, end: usize) !void {
        if (end <= start) return;
        try self.saveUndo();
        self.clearStack(&self.redo_stack);

        const del_len = end - start;
        const tail_len = self.buf.items.len - end;
        if (tail_len > 0) {
            std.mem.copyForwards(
                u8,
                self.buf.items[start .. start + tail_len],
                self.buf.items[end..],
            );
        }
        self.buf.items.len -= del_len;
        self.cursor = start;
        self.anchor = start;
    }

    fn saveUndo(self: *TextEditor) !void {
        const snap_text = try self.allocator.dupe(u8, self.buf.items);
        errdefer self.allocator.free(snap_text);
        if (self.undo_stack.items.len < MAX_UNDO) {
            try self.undo_stack.ensureUnusedCapacity(self.allocator, 1);
        }
        self.pushPreparedSnapshot(&self.undo_stack, .{
            .text = snap_text,
            .cursor = self.cursor,
            .anchor = self.anchor,
        });
    }

    fn pushPreparedSnapshot(self: *TextEditor, stack: *std.ArrayList(Snapshot), snap: Snapshot) void {
        if (stack.items.len >= MAX_UNDO) {
            const oldest = stack.orderedRemove(0);
            self.allocator.free(oldest.text);
        }
        stack.appendAssumeCapacity(snap);
    }

    fn transferSnapshot(
        self: *TextEditor,
        from: *std.ArrayList(Snapshot),
        to: *std.ArrayList(Snapshot),
    ) !bool {
        if (from.items.len == 0) return false;

        const target = from.items[from.items.len - 1];
        const saved_text = try self.allocator.dupe(u8, self.buf.items);
        errdefer self.allocator.free(saved_text);

        if (to.items.len < MAX_UNDO) {
            try to.ensureUnusedCapacity(self.allocator, 1);
        }
        try self.buf.ensureTotalCapacity(self.allocator, target.text.len);

        _ = from.pop();
        self.pushPreparedSnapshot(to, .{
            .text = saved_text,
            .cursor = self.cursor,
            .anchor = self.anchor,
        });

        self.buf.clearRetainingCapacity();
        self.buf.appendSliceAssumeCapacity(target.text);
        self.cursor = target.cursor;
        self.anchor = target.anchor;
        self.allocator.free(target.text);
        return true;
    }

    fn clearStack(self: *TextEditor, stack: *std.ArrayList(Snapshot)) void {
        for (stack.items) |snap| {
            self.allocator.free(snap.text);
        }
        stack.clearRetainingCapacity();
    }
};
