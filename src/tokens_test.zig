const std = @import("std");
const core = @import("core.zig");
const tokens = @import("tokens.zig");

fn makePidPath(buf: *[128]u8, suffix: []const u8) [*:0]const u8 {
    const pid = std.os.linux.getpid();
    const s = std.fmt.bufPrint(buf, "/tmp/ziggui_tokens_{d}_{s}.bin\x00", .{ pid, suffix }) catch unreachable;
    return @ptrCast(s.ptr);
}

test "TokenTable compiles Oklab tokens, resolves scoped pseudostates, and packs into 32-bit IDs" {
    const table = tokens.TokenTable.nordDefault();
    const base = table.resolve(.toggle, .{});
    const hovered = table.resolve(.toggle, .{ .hover = true });
    const focused = table.resolve(.toggle, .{ .focus_visible = true });
    const disabled = table.resolve(.toggle, .{ .disabled = true });

    // Hover brightens fill slightly over base; focus_visible highlights border; disabled dims alpha/lightness
    try std.testing.expect(core.srgbToOklabL(hovered.fill) > core.srgbToOklabL(base.fill));
    try std.testing.expect(focused.border_width >= base.border_width);
    try std.testing.expect(disabled.fill[3] < base.fill[3] or core.srgbToOklabL(disabled.text) < core.srgbToOklabL(base.text));
}

test "MmapTokenBuffer hot-reloads updated token tables from disk with magic/version validation" {
    var path_buf: [128]u8 = undefined;
    const path = makePidPath(&path_buf, "hotreload");
    var t1 = tokens.TokenTable.nordDefault();
    t1.version = 1;
    t1.corner_radius_md = 12.0;
    try tokens.writeTokenFile(path, &t1);
    defer _ = std.os.linux.unlink(path);

    var buf = try tokens.MmapTokenBuffer.open(path);
    defer buf.close();
    try std.testing.expectEqual(@as(u32, 1), buf.current().version);
    try std.testing.expectEqual(@as(f32, 12.0), buf.current().corner_radius_md);

    // Hot-reload: overwrite file with version 2 and corner_radius_md = 20.0
    var t2 = t1;
    t2.version = 2;
    t2.corner_radius_md = 20.0;
    try tokens.writeTokenFile(path, &t2);

    try std.testing.expect(buf.pollReload());
    try std.testing.expectEqual(@as(u32, 2), buf.current().version);
    try std.testing.expectEqual(@as(f32, 20.0), buf.current().corner_radius_md);
    try std.testing.expect(!buf.pollReload()); // unchanged on second poll
}

fn writeRawBytes(path: [*:0]const u8, bytes: []const u8) !void {
    const linux = std.os.linux;
    const fd_rc = linux.openat(
        linux.AT.FDCWD,
        path,
        .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true, .CLOEXEC = true },
        0o644,
    );
    if (linux.errno(fd_rc) != .SUCCESS) return error.OpenFailed;
    const fd: i32 = @intCast(fd_rc);
    defer _ = linux.close(fd);

    var written: usize = 0;
    while (written < bytes.len) {
        const w_rc = linux.write(fd, bytes[written..].ptr, bytes.len - written);
        if (linux.errno(w_rc) != .SUCCESS or w_rc == 0) return error.WriteFailed;
        written += w_rc;
    }
}

test "PseudoState active and checked resolve deterministically across component kinds" {
    const table = tokens.TokenTable.nordDefault();
    const base = table.resolve(.toggle, .{});
    const active = table.resolve(.toggle, .{ .active = true });
    const hover_active = table.resolve(.toggle, .{ .hover = true, .active = true });
    const checked = table.resolve(.toggle, .{ .checked = true });
    const checked_focus = table.resolve(.toggle, .{ .checked = true, .focus_visible = true });
    const checked_hover = table.resolve(.toggle, .{ .checked = true, .hover = true });
    const disabled_focus = table.resolve(.toggle, .{ .disabled = true, .focus_visible = true });

    // :active dims fill lightness in Oklab (-0.03 L), and hover + active dims below base
    try std.testing.expect(core.srgbToOklabL(active.fill) < core.srgbToOklabL(base.fill));
    try std.testing.expect(core.srgbToOklabL(hover_active.fill) < core.srgbToOklabL(base.fill));
    try std.testing.expectEqual(active.fill, hover_active.fill);

    // :checked switches fill/border to accent_primary
    const expected_accent = table.accent_primary.toSrgb();
    try std.testing.expectEqual(expected_accent, checked.fill);
    try std.testing.expectEqual(expected_accent, checked.border);

    // :checked + :focus_visible preserves focus border highlight
    try std.testing.expectEqual(table.border_focus.toSrgb(), checked_focus.border);
    try std.testing.expectEqual(table.border_width_focus, checked_focus.border_width);

    // :checked + :hover brightens the checked fill
    try std.testing.expect(core.srgbToOklabL(checked_hover.fill) > core.srgbToOklabL(checked.fill));

    // :disabled + :focus_visible suppresses focus ring and dims fill/border/accent alpha
    try std.testing.expectEqual(base.border_width, disabled_focus.border_width);
    try std.testing.expect(disabled_focus.border[3] < base.border[3]);
    try std.testing.expect(disabled_focus.accent[3] < base.accent[3]);
    try std.testing.expect(disabled_focus.fill[3] < base.fill[3]);

    // All ComponentKind variants resolve with finite colors and non-negative geometry
    inline for (std.meta.tags(tokens.ComponentKind)) |kind| {
        const s = table.resolve(kind, .{});
        try std.testing.expect(s.corner_radius >= 0.0);
        try std.testing.expect(s.border_width >= 0.0);
        try std.testing.expect(s.shadow_blur >= 0.0);
    }
}

test "TokenTable.isValid enforces strict Oklab/geometry bounds and authenticates version via CRC32" {
    const valid = tokens.TokenTable.nordDefault();
    try std.testing.expect(valid.isValid());

    // Tampering with version fails CRC32
    var bad_ver = valid;
    bad_ver.version += 1;
    try std.testing.expect(!bad_ver.isValid());

    // alpha > 1.0 rejected
    var bad_alpha = valid;
    bad_alpha.bg_base.alpha = 1.5;
    bad_alpha.checksum = bad_alpha.computeChecksum();
    try std.testing.expect(!bad_alpha.isValid());

    // l > 1.0 rejected
    var bad_l = valid;
    bad_l.text_primary.l = 1.2;
    bad_l.checksum = bad_l.computeChecksum();
    try std.testing.expect(!bad_l.isValid());

    // |a| > 1.0 (1e20) rejected
    var bad_a = valid;
    bad_a.accent_primary.a = 1e20;
    bad_a.checksum = bad_a.computeChecksum();
    try std.testing.expect(!bad_a.isValid());

    // |b| > 1.0 rejected
    var bad_b = valid;
    bad_b.accent_warn.b = -1.1;
    bad_b.checksum = bad_b.computeChecksum();
    try std.testing.expect(!bad_b.isValid());

    // geometry > 4096.0 rejected
    var bad_geom = valid;
    bad_geom.shadow_md = 5000.0;
    bad_geom.checksum = bad_geom.computeChecksum();
    try std.testing.expect(!bad_geom.isValid());

    // writeTokenFile rejects empty or trailing-slash paths
    try std.testing.expectError(error.InvalidPath, tokens.writeTokenFile("", &valid));
    try std.testing.expectError(error.InvalidPath, tokens.writeTokenFile("/tmp/", &valid));
}

test "MmapTokenBuffer rejects corrupt/bad-magic files on open and handles in-place overwrites on pollReload" {
    var bad_path_buf: [128]u8 = undefined;
    const bad_path = makePidPath(&bad_path_buf, "bad");
    defer _ = std.os.linux.unlink(bad_path);

    // 1. Wrong file size rejected on open
    try writeRawBytes(bad_path, "too short");
    try std.testing.expectError(error.InvalidTokenFileSize, tokens.MmapTokenBuffer.open(bad_path));

    // 2. Bad magic rejected on open
    var bad_magic = tokens.TokenTable.nordDefault();
    bad_magic.magic = 0xDEADBEEF;
    bad_magic.checksum = bad_magic.computeChecksum();
    try writeRawBytes(bad_path, std.mem.asBytes(&bad_magic));
    try std.testing.expectError(error.InvalidTokenTable, tokens.MmapTokenBuffer.open(bad_path));

    // 3. Bad checksum rejected on open
    var bad_crc = tokens.TokenTable.nordDefault();
    bad_crc.checksum ^= 0x1;
    try writeRawBytes(bad_path, std.mem.asBytes(&bad_crc));
    try std.testing.expectError(error.InvalidTokenTable, tokens.MmapTokenBuffer.open(bad_path));

    // 4. Negative geometry token (even with matching CRC) rejected on open
    var neg_geom = tokens.TokenTable.nordDefault();
    neg_geom.corner_radius_md = -1.0;
    neg_geom.checksum = neg_geom.computeChecksum();
    try writeRawBytes(bad_path, std.mem.asBytes(&neg_geom));
    try std.testing.expectError(error.InvalidTokenTable, tokens.MmapTokenBuffer.open(bad_path));

    // 5. pollReload ignores corrupt overwrite (in-place and via atomic rename) and preserves previous valid table
    var reload_path_buf: [128]u8 = undefined;
    const reload_path = makePidPath(&reload_path_buf, "corrupt_reload");
    defer _ = std.os.linux.unlink(reload_path);

    var valid_v1 = tokens.TokenTable.nordDefault();
    valid_v1.version = 10;
    valid_v1.corner_radius_md = 14.0;
    try tokens.writeTokenFile(reload_path, &valid_v1);

    var buf = try tokens.MmapTokenBuffer.open(reload_path);
    defer buf.close();

    // Corrupt in-place with bad magic -> ignored, v1 preserved
    try writeRawBytes(reload_path, std.mem.asBytes(&bad_magic));
    try std.testing.expect(!buf.pollReload());
    try std.testing.expectEqual(@as(u32, 10), buf.current().version);
    try std.testing.expectEqual(@as(f32, 14.0), buf.current().corner_radius_md);

    // Truncated in-place -> ignored without SIGBUS, v1 preserved
    try writeRawBytes(reload_path, "trunc");
    try std.testing.expect(!buf.pollReload());
    try std.testing.expectEqual(@as(u32, 10), buf.current().version);

    // Same-inode in-place overwrite with valid v2 -> detected by pollReload without SIGBUS
    var valid_v2_inplace = valid_v1;
    valid_v2_inplace.version = 11;
    valid_v2_inplace.corner_radius_md = 18.0;
    valid_v2_inplace.checksum = valid_v2_inplace.computeChecksum();
    try writeRawBytes(reload_path, std.mem.asBytes(&valid_v2_inplace));
    try std.testing.expect(buf.pollReload());
    try std.testing.expectEqual(@as(u32, 11), buf.current().version);
    try std.testing.expectEqual(@as(f32, 18.0), buf.current().corner_radius_md);

    // Recover via atomic rename hot-reload -> succeeds
    var valid_v3 = valid_v1;
    valid_v3.version = 12;
    valid_v3.corner_radius_md = 22.0;
    try tokens.writeTokenFile(reload_path, &valid_v3);
    try std.testing.expect(buf.pollReload());
    try std.testing.expectEqual(@as(u32, 12), buf.current().version);
    try std.testing.expectEqual(@as(f32, 22.0), buf.current().corner_radius_md);
}

test "MmapTokenBuffer double close is safe" {
    var path_buf: [128]u8 = undefined;
    const path = makePidPath(&path_buf, "double_close");
    const t = tokens.TokenTable.nordDefault();
    try tokens.writeTokenFile(path, &t);
    defer _ = std.os.linux.unlink(path);

    var buf = try tokens.MmapTokenBuffer.open(path);
    buf.close();
    buf.close();
    try std.testing.expect(!buf.pollReload());
}
