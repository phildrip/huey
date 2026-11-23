const std = @import("std");
const core = @import("../core.zig");
const tokens = @import("../tokens.zig");
const text_edit = @import("../text_edit.zig");
const ime_mod = @import("../ime.zig");

/// Caret blink half-period in seconds.
pub const BLINK_PERIOD_S: f32 = 0.53;

/// Maximum number of digits supported by `InputOtp`.
pub const MAX_OTP: usize = 12;

/// Shared configuration for `TextInput` and `TextArea`.
pub const TextInputConfig = struct {
    placeholder: []const u8 = "",
    max_len: usize = 256,
    uppercase: bool = false,
    password: bool = false,
    error_state: bool = false,
};

/// Form field metadata describing label, helper text, error message, and required status.
pub const FieldSpec = struct {
    label: []const u8,
    helper: []const u8 = "",
    error_msg: ?[]const u8 = null,
    required: bool = false,

    pub fn hasError(self: FieldSpec) bool {
        return self.error_msg != null;
    }

    pub fn supportingText(self: FieldSpec) []const u8 {
        return self.error_msg orelse self.helper;
    }
};

fn utf8ValidPrefixLen(s: []const u8, max_bytes: usize) usize {
    const limit = @min(s.len, max_bytes);
    var i: usize = 0;
    while (i < limit) {
        const seq_len = std.unicode.utf8ByteSequenceLength(s[i]) catch break;
        if (i + seq_len > limit) break;
        i += seq_len;
    }
    return i;
}

fn countUtf8Codepoints(s: []const u8) usize {
    var count: usize = 0;
    var i: usize = 0;
    while (i < s.len) {
        const seq_len = std.unicode.utf8ByteSequenceLength(s[i]) catch 1;
        i += @min(seq_len, s.len - i);
        count += 1;
    }
    return count;
}

fn insertWithConfig(editor: *text_edit.TextEditor, cfg: TextInputConfig, s: []const u8, single_line: bool) !void {
    if (!std.unicode.utf8ValidateSlice(s)) return error.InvalidUtf8;

    const range = editor.selectionRange();
    const sel_len = range[1] - range[0];
    const kept_len = editor.text().len - sel_len;
    const avail_bytes = if (cfg.max_len > kept_len) cfg.max_len - kept_len else 0;

    if (s.len == 0) {
        try editor.insert("");
        return;
    }
    if (avail_bytes == 0) return;

    if (!single_line and !cfg.uppercase) {
        const prefix_len = utf8ValidPrefixLen(s, avail_bytes);
        if (prefix_len == 0) return;
        try editor.insert(s[0..prefix_len]);
        return;
    }

    const max_out = @min(avail_bytes, s.len);
    var stack_buf: [512]u8 = undefined;
    const heap_buf: ?[]u8 = if (max_out > stack_buf.len)
        try editor.allocator.alloc(u8, max_out)
    else
        null;
    defer if (heap_buf) |hb| editor.allocator.free(hb);
    const out_buf: []u8 = if (heap_buf) |hb| hb else stack_buf[0..max_out];

    var out_len: usize = 0;
    var i: usize = 0;
    while (i < s.len and out_len < max_out) {
        const seq_len = std.unicode.utf8ByteSequenceLength(s[i]) catch return error.InvalidUtf8;
        if (i + seq_len > s.len) return error.InvalidUtf8;
        if (single_line and (s[i] == '\r' or s[i] == '\n')) {
            i += seq_len;
            continue;
        }
        if (out_len + seq_len > max_out) break;
        if (cfg.uppercase and seq_len == 1 and s[i] >= 'a' and s[i] <= 'z') {
            out_buf[out_len] = s[i] - 32;
        } else {
            @memcpy(out_buf[out_len .. out_len + seq_len], s[i .. i + seq_len]);
        }
        out_len += seq_len;
        i += seq_len;
    }

    if (out_len == 0) return;
    try editor.insert(out_buf[0..out_len]);
}

fn clearEditor(editor: *text_edit.TextEditor) void {
    if (editor.text().len == 0) {
        editor.cursor = 0;
        editor.anchor = 0;
        return;
    }
    editor.selectAll();
    editor.backspace() catch {
        editor.buf.clearRetainingCapacity();
        editor.cursor = 0;
        editor.anchor = 0;
    };
}

pub fn stepBlinkState(focused: bool, blink_accum_s: *f32, caret_on: *bool, dt_s: f32) bool {
    if (!focused) return false;
    if (!std.math.isFinite(dt_s) or dt_s <= 0.0) return false;
    if (!std.math.isFinite(blink_accum_s.*) or blink_accum_s.* < 0.0) {
        blink_accum_s.* = 0.0;
    }

    const cycle: f64 = 2.0 * @as(f64, BLINK_PERIOD_S);
    const prev_phase: f64 = @as(f64, blink_accum_s.*) + (if (caret_on.*) @as(f64, 0.0) else @as(f64, BLINK_PERIOD_S));
    const next_phase: f64 = @mod(prev_phase + @as(f64, dt_s), cycle);
    const next_on = next_phase < @as(f64, BLINK_PERIOD_S);
    const flipped = (next_on != caret_on.*);
    caret_on.* = next_on;
    blink_accum_s.* = @floatCast(if (next_on) next_phase else (next_phase - @as(f64, BLINK_PERIOD_S)));
    return flipped;
}

fn sanitizeNonNeg(v: f32) f32 {
    if (!std.math.isFinite(v) or v <= 0.0) return 0.0;
    return v;
}

fn validateEmitArgs(rect: core.Rect, scale: f32, out_quads: []core.QuadInstance, clip_rect: [4]f32) bool {
    if (out_quads.len == 0) return false;
    if (!std.math.isFinite(scale) or scale <= 0.0) return false;
    if (!std.math.isFinite(rect.x) or !std.math.isFinite(rect.y) or
        !std.math.isFinite(rect.w) or !std.math.isFinite(rect.h))
    {
        return false;
    }
    if (rect.w <= 0.0 or rect.h <= 0.0) return false;
    for (clip_rect) |v| {
        if (!std.math.isFinite(v)) return false;
    }
    if (clip_rect[2] <= clip_rect[0] or clip_rect[3] <= clip_rect[1]) return false;
    return true;
}

fn pushSnappedQuad(
    out_quads: []core.QuadInstance,
    written: *usize,
    rect: core.Rect,
    scale: f32,
    color: core.Color,
    border_color: core.Color,
    params: [4]f32,
    clip_rect: [4]f32,
) void {
    if (written.* >= out_quads.len) return;
    const phys = core.snapRectToPhysical(rect, scale);
    if (!std.math.isFinite(phys.x) or !std.math.isFinite(phys.y) or
        !std.math.isFinite(phys.w) or !std.math.isFinite(phys.h))
    {
        return;
    }
    if (phys.w <= 0.0 or phys.h <= 0.0) return;
    if (phys.x + phys.w <= clip_rect[0] or phys.x >= clip_rect[2] or
        phys.y + phys.h <= clip_rect[1] or phys.y >= clip_rect[3])
    {
        return;
    }
    const clean_params: [4]f32 = .{
        sanitizeNonNeg(params[0]),
        sanitizeNonNeg(params[1]),
        sanitizeNonNeg(params[2]),
        sanitizeNonNeg(params[3]),
    };
    out_quads[written.*] = .{
        .pos_size = .{ phys.x, phys.y, phys.w, phys.h },
        .color = core.sanitizeColor(color),
        .border_color = core.sanitizeColor(border_color),
        .params = clean_params,
        .clip_rect = clip_rect,
    };
    written.* += 1;
}

fn emitInputContainer(
    rect: core.Rect,
    scale: f32,
    tbl: *const tokens.TokenTable,
    focused: bool,
    error_state: bool,
    out_quads: []core.QuadInstance,
    written: *usize,
    clip_rect: [4]f32,
) void {
    const resolved = tbl.resolve(.input, .{ .focus_visible = focused });
    const border_col = if (error_state) tbl.accent_danger.toSrgb() else resolved.border;
    const border_w = if (error_state or focused) tbl.border_width_focus else resolved.border_width;
    pushSnappedQuad(
        out_quads,
        written,
        rect,
        scale,
        resolved.fill,
        border_col,
        .{ resolved.corner_radius * scale, border_w * scale, resolved.shadow_blur * scale, 0.0 },
        clip_rect,
    );
}

/// Single-line UTF-8 text input with IME state, uppercase/password modes,
/// codepoint-safe `max_len` clamping, selection, and blinking caret quad emission.
pub const TextInput = struct {
    editor: text_edit.TextEditor,
    ime: ime_mod.ImeState = ime_mod.ImeState.init(),
    cfg: TextInputConfig = .{},
    focused: bool = false,
    blink_accum_s: f32 = 0.0,
    caret_on: bool = true,
    scroll_x: f32 = 0.0,

    pub fn init(allocator: std.mem.Allocator, cfg: TextInputConfig) !TextInput {
        return .{
            .editor = text_edit.TextEditor.init(allocator),
            .ime = ime_mod.ImeState.init(),
            .cfg = cfg,
        };
    }

    pub fn deinit(self: *TextInput) void {
        const alloc = self.editor.allocator;
        self.editor.deinit();
        self.editor = text_edit.TextEditor.init(alloc);
    }

    pub fn setFocused(self: *TextInput, f: bool) void {
        self.focused = f;
        if (!f) self.ime.cancel();
        self.blink_accum_s = 0.0;
        self.caret_on = true;
    }

    pub fn insertText(self: *TextInput, s: []const u8) !void {
        try insertWithConfig(&self.editor, self.cfg, s, true);
        self.blink_accum_s = 0.0;
        self.caret_on = true;
    }

    pub fn backspace(self: *TextInput) void {
        self.editor.backspace() catch {};
        self.blink_accum_s = 0.0;
        self.caret_on = true;
    }

    pub fn deleteForward(self: *TextInput) void {
        self.editor.deleteForward() catch {};
        self.blink_accum_s = 0.0;
        self.caret_on = true;
    }

    pub fn moveLeft(self: *TextInput, extend: bool) void {
        self.editor.moveLeft(extend);
        self.blink_accum_s = 0.0;
        self.caret_on = true;
    }

    pub fn moveRight(self: *TextInput, extend: bool) void {
        self.editor.moveRight(extend);
        self.blink_accum_s = 0.0;
        self.caret_on = true;
    }

    pub fn selectAll(self: *TextInput) void {
        self.editor.selectAll();
    }

    pub fn clear(self: *TextInput) void {
        clearEditor(&self.editor);
        self.ime.cancel();
        self.scroll_x = 0.0;
        self.blink_accum_s = 0.0;
        self.caret_on = true;
    }

    pub fn text(self: *const TextInput) []const u8 {
        return self.editor.text();
    }

    pub fn displayText(self: *const TextInput, out_buf: []u8) []const u8 {
        const raw = self.text();
        if (!self.cfg.password) return raw;
        var count: usize = 0;
        var i: usize = 0;
        while (i < raw.len and count < out_buf.len) {
            const seq_len = std.unicode.utf8ByteSequenceLength(raw[i]) catch 1;
            i += @min(seq_len, raw.len - i);
            out_buf[count] = '*';
            count += 1;
        }
        return out_buf[0..count];
    }

    pub fn caretVisible(self: *const TextInput) bool {
        return self.focused and self.caret_on;
    }

    pub fn stepBlink(self: *TextInput, dt_s: f32) bool {
        return stepBlinkState(self.focused, &self.blink_accum_s, &self.caret_on, dt_s);
    }

    pub fn emitQuads(
        self: *const TextInput,
        rect: core.Rect,
        scale: f32,
        tbl: *const tokens.TokenTable,
        out_quads: []core.QuadInstance,
        clip_rect: [4]f32,
    ) usize {
        if (!validateEmitArgs(rect, scale, out_quads, clip_rect)) return 0;

        var written: usize = 0;
        emitInputContainer(rect, scale, tbl, self.focused, self.cfg.error_state, out_quads, &written, clip_rect);
        if (written == 0) return 0;

        const pad_x = @min(tbl.space_sm, rect.w * 0.1);
        const pad_y = @min(tbl.space_xs, rect.h * 0.15);
        const inner_w = @max(0.0, rect.w - pad_x * 2.0);
        const inner_h = @max(0.0, rect.h - pad_y * 2.0);
        if (inner_w <= 0.0 or inner_h <= 0.0) return written;

        const char_w: f32 = @max(4.0, @min(10.0, rect.h * 0.42));
        const inner_x0 = rect.x + pad_x;
        const inner_x1 = inner_x0 + inner_w;
        const buf = self.text();

        const caret_w = @min(2.0, inner_w);
        const max_caret_rel_x = @max(0.0, inner_w - caret_w);
        const cp_cursor = countUtf8Codepoints(buf[0..@min(self.editor.cursor, buf.len)]);
        const caret_rel_x = @as(f32, @floatFromInt(cp_cursor)) * char_w;
        var eff_scroll_x: f32 = if (std.math.isFinite(self.scroll_x) and self.scroll_x >= 0.0) self.scroll_x else 0.0;
        if (caret_rel_x < eff_scroll_x) {
            eff_scroll_x = caret_rel_x;
        } else if (caret_rel_x > eff_scroll_x + max_caret_rel_x) {
            eff_scroll_x = caret_rel_x - max_caret_rel_x;
        }
        if (eff_scroll_x < 0.0 or !std.math.isFinite(eff_scroll_x)) eff_scroll_x = 0.0;

        if (self.editor.hasSelection() and written < out_quads.len) {
            const range = self.editor.selectionRange();
            const cp_start = countUtf8Codepoints(buf[0..range[0]]);
            const cp_sel = countUtf8Codepoints(buf[range[0]..range[1]]);
            const raw_x0 = inner_x0 + @as(f32, @floatFromInt(cp_start)) * char_w - eff_scroll_x;
            const raw_x1 = inner_x0 + @as(f32, @floatFromInt(cp_start + cp_sel)) * char_w - eff_scroll_x;
            const sx0 = std.math.clamp(raw_x0, inner_x0, inner_x1);
            const sx1 = std.math.clamp(raw_x1, inner_x0, inner_x1);
            if (sx1 > sx0) {
                var sel_col = tbl.accent_primary.toSrgb();
                sel_col[3] = 0.35;
                pushSnappedQuad(
                    out_quads,
                    &written,
                    .{ .x = sx0, .y = rect.y + pad_y, .w = sx1 - sx0, .h = inner_h },
                    scale,
                    sel_col,
                    core.Nord.transparent,
                    .{ 2.0 * scale, 0.0, 0.0, 0.0 },
                    clip_rect,
                );
            }
        }

        if (self.caretVisible() and written < out_quads.len) {
            const raw_cx = inner_x0 + caret_rel_x - eff_scroll_x;
            const cx = std.math.clamp(raw_cx, inner_x0, @max(inner_x0, inner_x1 - caret_w));
            pushSnappedQuad(
                out_quads,
                &written,
                .{ .x = cx, .y = rect.y + pad_y, .w = caret_w, .h = inner_h },
                scale,
                tbl.border_focus.toSrgb(),
                core.Nord.transparent,
                .{ 0.0, 0.0, 0.0, 0.0 },
                clip_rect,
            );
        }

        return written;
    }
};

/// Multi-line UTF-8 text editor wrapper with line counting and SDF quad emission.
pub const TextArea = struct {
    editor: text_edit.TextEditor,
    ime: ime_mod.ImeState = ime_mod.ImeState.init(),
    cfg: TextInputConfig = .{},
    focused: bool = false,
    blink_accum_s: f32 = 0.0,
    caret_on: bool = true,
    scroll_y: f32 = 0.0,

    pub fn init(allocator: std.mem.Allocator, cfg: TextInputConfig) !TextArea {
        return .{
            .editor = text_edit.TextEditor.init(allocator),
            .ime = ime_mod.ImeState.init(),
            .cfg = cfg,
        };
    }

    pub fn deinit(self: *TextArea) void {
        const alloc = self.editor.allocator;
        self.editor.deinit();
        self.editor = text_edit.TextEditor.init(alloc);
    }

    pub fn setFocused(self: *TextArea, f: bool) void {
        self.focused = f;
        if (!f) self.ime.cancel();
        self.blink_accum_s = 0.0;
        self.caret_on = true;
    }

    pub fn insertText(self: *TextArea, s: []const u8) !void {
        try insertWithConfig(&self.editor, self.cfg, s, false);
        self.blink_accum_s = 0.0;
        self.caret_on = true;
    }

    pub fn backspace(self: *TextArea) void {
        self.editor.backspace() catch {};
        self.blink_accum_s = 0.0;
        self.caret_on = true;
    }

    pub fn deleteForward(self: *TextArea) void {
        self.editor.deleteForward() catch {};
        self.blink_accum_s = 0.0;
        self.caret_on = true;
    }

    pub fn moveLeft(self: *TextArea, extend: bool) void {
        self.editor.moveLeft(extend);
        self.blink_accum_s = 0.0;
        self.caret_on = true;
    }

    pub fn moveRight(self: *TextArea, extend: bool) void {
        self.editor.moveRight(extend);
        self.blink_accum_s = 0.0;
        self.caret_on = true;
    }

    pub fn selectAll(self: *TextArea) void {
        self.editor.selectAll();
    }

    pub fn clear(self: *TextArea) void {
        clearEditor(&self.editor);
        self.ime.cancel();
        self.scroll_y = 0.0;
        self.blink_accum_s = 0.0;
        self.caret_on = true;
    }

    pub fn text(self: *const TextArea) []const u8 {
        return self.editor.text();
    }

    pub fn lineCount(self: *const TextArea) usize {
        var lines: usize = 1;
        for (self.text()) |ch| {
            if (ch == '\n') lines += 1;
        }
        return lines;
    }

    pub fn caretVisible(self: *const TextArea) bool {
        return self.focused and self.caret_on;
    }

    pub fn stepBlink(self: *TextArea, dt_s: f32) bool {
        return stepBlinkState(self.focused, &self.blink_accum_s, &self.caret_on, dt_s);
    }

    pub fn emitQuads(
        self: *const TextArea,
        rect: core.Rect,
        scale: f32,
        tbl: *const tokens.TokenTable,
        out_quads: []core.QuadInstance,
        clip_rect: [4]f32,
    ) usize {
        if (!validateEmitArgs(rect, scale, out_quads, clip_rect)) return 0;

        var written: usize = 0;
        emitInputContainer(rect, scale, tbl, self.focused, self.cfg.error_state, out_quads, &written, clip_rect);
        if (written == 0) return 0;

        const pad_x = @min(tbl.space_sm, rect.w * 0.1);
        const pad_y = @min(tbl.space_sm, rect.h * 0.1);
        const inner_w = @max(0.0, rect.w - pad_x * 2.0);
        const inner_h = @max(0.0, rect.h - pad_y * 2.0);
        if (inner_w <= 0.0 or inner_h <= 0.0) return written;

        const line_h: f32 = @min(20.0, inner_h);
        const char_w: f32 = 9.0;
        const inner_x0 = rect.x + pad_x;
        const inner_x1 = inner_x0 + inner_w;
        const inner_y0 = rect.y + pad_y;
        const inner_y1 = inner_y0 + inner_h;
        const buf = self.text();

        const caret_pos = lineColAtOffset(buf, @min(self.editor.cursor, buf.len));
        const caret_rel_y = @as(f32, @floatFromInt(caret_pos.line)) * line_h;
        const max_caret_rel_y = @max(0.0, inner_h - line_h);
        var eff_scroll_y: f32 = if (std.math.isFinite(self.scroll_y) and self.scroll_y >= 0.0) self.scroll_y else 0.0;
        if (caret_rel_y < eff_scroll_y) {
            eff_scroll_y = caret_rel_y;
        } else if (caret_rel_y > eff_scroll_y + max_caret_rel_y) {
            eff_scroll_y = caret_rel_y - max_caret_rel_y;
        }
        if (eff_scroll_y < 0.0 or !std.math.isFinite(eff_scroll_y)) eff_scroll_y = 0.0;

        if (self.editor.hasSelection() and written < out_quads.len) {
            const range = self.editor.selectionRange();
            const sel_pos = lineColAtOffset(buf, range[0]);
            const end_pos = lineColAtOffset(buf, range[1]);
            const end_line_excl = if (sel_pos.line != end_pos.line and end_pos.col == 0)
                end_pos.line
            else
                end_pos.line + 1;
            const sy0 = std.math.clamp(inner_y0 + @as(f32, @floatFromInt(sel_pos.line)) * line_h - eff_scroll_y, inner_y0, inner_y1);
            const sy1 = std.math.clamp(inner_y0 + @as(f32, @floatFromInt(end_line_excl)) * line_h - eff_scroll_y, inner_y0, inner_y1);
            if (sy1 > sy0) {
                var sel_col = tbl.accent_primary.toSrgb();
                sel_col[3] = 0.35;
                const sx0 = if (sel_pos.line == end_pos.line)
                    std.math.clamp(inner_x0 + @as(f32, @floatFromInt(sel_pos.col)) * char_w, inner_x0, inner_x1)
                else
                    inner_x0;
                const sx1 = if (sel_pos.line == end_pos.line)
                    std.math.clamp(inner_x0 + @as(f32, @floatFromInt(end_pos.col)) * char_w, inner_x0, inner_x1)
                else
                    inner_x1;
                if (sx1 > sx0) {
                    pushSnappedQuad(
                        out_quads,
                        &written,
                        .{ .x = sx0, .y = sy0, .w = sx1 - sx0, .h = sy1 - sy0 },
                        scale,
                        sel_col,
                        core.Nord.transparent,
                        .{ 2.0 * scale, 0.0, 0.0, 0.0 },
                        clip_rect,
                    );
                }
            }
        }

        if (self.caretVisible() and written < out_quads.len) {
            const caret_w = @min(2.0, inner_w);
            const cx = std.math.clamp(
                inner_x0 + @as(f32, @floatFromInt(caret_pos.col)) * char_w,
                inner_x0,
                @max(inner_x0, inner_x1 - caret_w),
            );
            const cy = inner_y0 + caret_rel_y - eff_scroll_y;
            if (cy + line_h > inner_y0 and cy < inner_y1) {
                const clamped_y0 = @max(cy, inner_y0);
                const clamped_y1 = @min(cy + line_h, inner_y1);
                if (clamped_y1 > clamped_y0) {
                    pushSnappedQuad(
                        out_quads,
                        &written,
                        .{ .x = cx, .y = clamped_y0, .w = caret_w, .h = clamped_y1 - clamped_y0 },
                        scale,
                        tbl.border_focus.toSrgb(),
                        core.Nord.transparent,
                        .{ 0.0, 0.0, 0.0, 0.0 },
                        clip_rect,
                    );
                }
            }
        }

        return written;
    }
};

const LineCol = struct {
    line: usize,
    col: usize,
};

fn lineColAtOffset(buf: []const u8, offset: usize) LineCol {
    const end = @min(offset, buf.len);
    const line_start = if (std.mem.lastIndexOfScalar(u8, buf[0..end], '\n')) |nl| nl + 1 else 0;
    var lines: usize = 0;
    for (buf[0..line_start]) |ch| {
        if (ch == '\n') lines += 1;
    }
    return .{
        .line = lines,
        .col = countUtf8Codepoints(buf[line_start..end]),
    };
}

/// Zero-allocation fixed-capacity segmented OTP digit input.
pub const InputOtp = struct {
    digits: [MAX_OTP]u8 = [_]u8{0} ** MAX_OTP,
    count: u8 = 0,
    target_len: u8 = 6,
    focused: bool = false,
    error_state: bool = false,

    fn effectiveTargetLen(self: *const InputOtp) u8 {
        return std.math.clamp(self.target_len, 1, @as(u8, MAX_OTP));
    }

    pub fn init(len: u8) InputOtp {
        const clamped: u8 = std.math.clamp(len, 1, @as(u8, MAX_OTP));
        return .{
            .target_len = clamped,
        };
    }

    pub fn pushDigit(self: *InputOtp, ch: u8) bool {
        if (ch < '0' or ch > '9') return false;
        const limit = self.effectiveTargetLen();
        if (self.count >= limit) return false;
        self.digits[self.count] = ch;
        self.count += 1;
        return true;
    }

    pub fn backspace(self: *InputOtp) void {
        if (self.count > 0) {
            self.count -= 1;
        }
    }

    pub fn paste(self: *InputOtp, s: []const u8) void {
        var has_digit = false;
        for (s) |ch| {
            if (ch >= '0' and ch <= '9') {
                has_digit = true;
                break;
            }
        }
        if (!has_digit) return;

        const limit = self.effectiveTargetLen();
        self.count = 0;
        for (s) |ch| {
            if (ch >= '0' and ch <= '9') {
                if (self.count >= limit) break;
                self.digits[self.count] = ch;
                self.count += 1;
            }
        }
    }

    pub fn slice(self: *const InputOtp) []const u8 {
        return self.digits[0..@min(self.count, self.effectiveTargetLen())];
    }

    pub fn isComplete(self: *const InputOtp) bool {
        return self.count >= self.effectiveTargetLen();
    }

    pub fn clear(self: *InputOtp) void {
        self.count = 0;
    }

    pub fn emitQuads(
        self: *const InputOtp,
        rect: core.Rect,
        scale: f32,
        tbl: *const tokens.TokenTable,
        out_quads: []core.QuadInstance,
        clip_rect: [4]f32,
    ) usize {
        if (!validateEmitArgs(rect, scale, out_quads, clip_rect)) return 0;
        const n: usize = @intCast(self.effectiveTargetLen());
        const resolved = tbl.resolve(.input, .{});
        const gap = if (n > 1)
            @min(tbl.space_sm, (rect.w * 0.4) / @as(f32, @floatFromInt(n - 1)))
        else
            0.0;
        const total_gap = gap * @as(f32, @floatFromInt(n - 1));
        const cell_w = @max(0.0, (rect.w - total_gap) / @as(f32, @floatFromInt(n)));
        if (cell_w <= 0.0) return 0;

        var written: usize = 0;
        for (0..n) |i| {
            if (written >= out_quads.len) break;
            const cx = rect.x + @as(f32, @floatFromInt(i)) * (cell_w + gap);
            const is_active = self.focused and (i == self.count or (self.isComplete() and i == n - 1));
            const border_col = if (self.error_state)
                tbl.accent_danger.toSrgb()
            else if (is_active)
                tbl.border_focus.toSrgb()
            else if (i < self.count)
                tbl.accent_primary.toSrgb()
            else
                resolved.border;
            const border_w = if (self.error_state or is_active) tbl.border_width_focus else resolved.border_width;
            const fill_col = if (i < self.count) tbl.bg_surface.toSrgb() else resolved.fill;

            pushSnappedQuad(
                out_quads,
                &written,
                .{ .x = cx, .y = rect.y, .w = cell_w, .h = rect.h },
                scale,
                fill_col,
                border_col,
                .{ resolved.corner_radius * scale, border_w * scale, 0.0, 0.0 },
                clip_rect,
            );

            if (i < self.count and written < out_quads.len) {
                const dot_d = @min(cell_w, rect.h) * 0.28;
                if (dot_d > 0.0) {
                    pushSnappedQuad(
                        out_quads,
                        &written,
                        .{
                            .x = cx + (cell_w - dot_d) * 0.5,
                            .y = rect.y + (rect.h - dot_d) * 0.5,
                            .w = dot_d,
                            .h = dot_d,
                        },
                        scale,
                        tbl.text_primary.toSrgb(),
                        core.Nord.transparent,
                        .{ (dot_d * 0.5) * scale, 0.0, 0.0, 0.0 },
                        clip_rect,
                    );
                }
            }
        }
        return written;
    }
};

test "TextInput: invalid UTF-8 rejected, multi-byte max_len truncated at codepoint boundary" {
    const alloc = std.testing.allocator;
    var inp = try TextInput.init(alloc, .{ .max_len = 4, .uppercase = true });
    defer inp.deinit();
    // Idempotent deinit verified separately
    try std.testing.expectError(error.InvalidUtf8, inp.insertText("\xFF\xFE"));
    try inp.insertText("ab€"); // "ab" (2) + "€" (3) = 5 bytes -> clamps to "ab" -> "AB"
    try std.testing.expectEqualStrings("AB", inp.text());
    try std.testing.expect(std.unicode.utf8ValidateSlice(inp.text()));
}

test "TextInput: selection quad, blink edge cases, editing ops, and idempotent deinit" {
    const alloc = std.testing.allocator;
    var inp = try TextInput.init(alloc, .{ .max_len = 16, .error_state = true });
    defer inp.deinit();

    inp.setFocused(true);
    try std.testing.expect(!inp.stepBlink(0.0));
    try std.testing.expect(!inp.stepBlink(-1.0));
    try std.testing.expect(!inp.stepBlink(std.math.nan(f32)));
    try std.testing.expect(!inp.stepBlink(std.math.inf(f32)));
    try std.testing.expect(inp.caretVisible());

    try inp.insertText("hello");
    inp.moveLeft(true);
    inp.moveLeft(true);
    try std.testing.expectEqualStrings("lo", inp.editor.selectedText());

    const tbl = tokens.TokenTable.nordDefault();
    var quads: [16]core.QuadInstance = undefined;
    const n = inp.emitQuads(.{ .x = 10, .y = 10, .w = 200, .h = 40 }, 2.0, &tbl, &quads, .{ 0, 0, 800, 800 });
    try std.testing.expectEqual(@as(usize, 3), n); // box + selection + caret

    // Overwriting selection respects max_len
    try inp.insertText("p!");
    try std.testing.expectEqualStrings("help!", inp.text());
    inp.backspace();
    try std.testing.expectEqualStrings("help", inp.text());
    inp.moveLeft(false);
    inp.deleteForward();
    try std.testing.expectEqualStrings("hel", inp.text());
    inp.selectAll();
    inp.clear();
    try std.testing.expectEqualStrings("", inp.text());

    // Idempotent deinit
    inp.deinit();
    inp.deinit();
}

test "TextInput: password masking clamps to out_buf and counts codepoints" {
    const alloc = std.testing.allocator;
    var pw = try TextInput.init(alloc, .{ .password = true });
    defer pw.deinit();
    try pw.insertText("a€b");
    var small: [2]u8 = undefined;
    try std.testing.expectEqualStrings("**", pw.displayText(&small));
    var exact: [8]u8 = undefined;
    try std.testing.expectEqualStrings("***", pw.displayText(&exact));
}

test "InputOtp & FieldSpec edge cases" {
    var otp = InputOtp.init(20); // clamps to MAX_OTP=12
    try std.testing.expectEqual(@as(u8, MAX_OTP), otp.target_len);
    otp.paste("12-34 56");
    try std.testing.expectEqualStrings("123456", otp.slice());
    try std.testing.expect(!otp.isComplete());
    otp.clear();
    try std.testing.expectEqualStrings("", otp.slice());

    const tbl = tokens.TokenTable.nordDefault();
    var quads: [32]core.QuadInstance = undefined;
    otp.paste("123");
    const n = otp.emitQuads(.{ .x = 0, .y = 0, .w = 300, .h = 44 }, 2.0, &tbl, &quads, .{ 0, 0, 800, 800 });
    try std.testing.expectEqual(@as(usize, 15), n); // 12 cells + 3 dots

    const f = FieldSpec{ .label = "VIN", .helper = "17 chars", .error_msg = "Invalid VIN", .required = true };
    try std.testing.expect(f.hasError());
    try std.testing.expectEqualStrings("Invalid VIN", f.supportingText());
}
