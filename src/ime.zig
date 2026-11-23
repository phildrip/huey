const std = @import("std");
const core = @import("core.zig");

pub const MAX_IME_BUF: usize = 256;

/// Zero-allocation IME composition and commit state.
pub const ImeState = struct {
    preedit_buf: [MAX_IME_BUF]u8 = [_]u8{0} ** MAX_IME_BUF,
    preedit_len: usize = 0,
    cursor_start: usize = 0,
    cursor_end: usize = 0,
    composing: bool = false,

    committed_buf: [MAX_IME_BUF]u8 = [_]u8{0} ** MAX_IME_BUF,
    committed_len: usize = 0,
    has_committed: bool = false,

    target_node: ?core.NodeId = null,

    pub fn init() ImeState {
        return .{};
    }

    fn validUtf8PrefixLen(text: []const u8, max_len: usize) usize {
        const limit = @min(text.len, max_len);
        var i: usize = 0;
        while (i < limit) {
            const seq_len = std.unicode.utf8ByteSequenceLength(text[i]) catch break;
            if (i + seq_len > limit) break;
            _ = std.unicode.utf8Decode(text[i .. i + seq_len]) catch break;
            i += seq_len;
        }
        return i;
    }

    fn clampUtf8Cursor(valid_slice: []const u8, raw_idx: usize) usize {
        const target = @min(raw_idx, valid_slice.len);
        var i: usize = 0;
        while (i < target) {
            const seq_len = std.unicode.utf8ByteSequenceLength(valid_slice[i]) catch break;
            if (i + seq_len > target) break;
            i += seq_len;
        }
        return i;
    }

    pub fn setPreedit(self: *ImeState, text: []const u8, cursor_start: usize, cursor_end: usize) void {
        const copy_len = validUtf8PrefixLen(text, MAX_IME_BUF);
        if (copy_len == 0) {
            self.cancel();
            return;
        }
        @memcpy(self.preedit_buf[0..copy_len], text[0..copy_len]);
        self.preedit_len = copy_len;
        const active = self.preedit_buf[0..copy_len];
        const cs = clampUtf8Cursor(active, cursor_start);
        const ce = clampUtf8Cursor(active, cursor_end);
        self.cursor_start = @min(cs, ce);
        self.cursor_end = @max(cs, ce);
        self.composing = true;
    }

    pub fn preeditText(self: *const ImeState) []const u8 {
        return self.preedit_buf[0..self.preedit_len];
    }

    pub fn commit(self: *ImeState, text: []const u8) void {
        self.cancel();
        const copy_len = validUtf8PrefixLen(text, MAX_IME_BUF);
        if (copy_len == 0) return;
        @memcpy(self.committed_buf[0..copy_len], text[0..copy_len]);
        self.committed_len = copy_len;
        self.has_committed = true;
    }

    pub fn takeCommitted(self: *ImeState) ?[]const u8 {
        if (!self.has_committed) return null;
        self.has_committed = false;
        return self.committed_buf[0..self.committed_len];
    }

    pub fn cancel(self: *ImeState) void {
        self.preedit_len = 0;
        self.cursor_start = 0;
        self.cursor_end = 0;
        self.composing = false;
    }

    pub fn caretRect(self: *const ImeState, arena: *const core.LayoutArena) ?core.Rect {
        const target = self.target_node orelse return null;
        if (!arena.isEnabledTree(target)) return null;
        const r = arena.getRect(target) orelse return null;
        if (!std.math.isFinite(r.x) or !std.math.isFinite(r.y) or
            !std.math.isFinite(r.w) or !std.math.isFinite(r.h))
        {
            return null;
        }
        if (r.w <= 0.0 or r.h <= 0.0) return null;

        const pad_x: f32 = @min(8.0, r.w * 0.1);
        const pad_y: f32 = @min(4.0, r.h * 0.15);
        const caret_w: f32 = @min(2.0, @max(0.0, r.w - pad_x));
        const caret_h: f32 = @max(0.0, r.h - pad_y * 2.0);
        if (caret_w <= 0.0 or caret_h <= 0.0) return null;

        var x0 = r.x + pad_x;
        var y0 = r.y + pad_y;
        var x1 = x0 + caret_w;
        var y1 = y0 + caret_h;

        var anc_opt = arena.getParent(target);
        var steps: usize = 0;
        const max_steps = arena.nodes.len;
        while (anc_opt) |anc| : (steps += 1) {
            if (steps >= max_steps) break;
            if (arena.isClipChildren(anc)) {
                const ar = arena.getRect(anc) orelse return null;
                if (!std.math.isFinite(ar.x) or !std.math.isFinite(ar.y) or
                    !std.math.isFinite(ar.w) or !std.math.isFinite(ar.h) or
                    ar.w <= 0.0 or ar.h <= 0.0)
                {
                    return null;
                }
                x0 = @max(x0, ar.x);
                y0 = @max(y0, ar.y);
                x1 = @min(x1, ar.x + ar.w);
                y1 = @min(y1, ar.y + ar.h);
                if (x1 <= x0 or y1 <= y0) return null;
            }
            anc_opt = arena.getParent(anc);
        }

        return .{
            .x = x0,
            .y = y0,
            .w = x1 - x0,
            .h = y1 - y0,
        };
    }
};
