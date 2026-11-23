const std = @import("std");
const mw = @import("multi_window.zig");

test "MultiWindowManager: simultaneous 1.0x, 1.5x, and 2.0x outputs with independent scales and refresh" {
    var mgr = mw.MultiWindowManager.init();
    try mgr.addOutput(.{ .id = 1, .logical_w = 1920, .logical_h = 1080, .scale_factor = 1.0, .refresh_mhz = 60_000 });
    try mgr.addOutput(.{ .id = 2, .logical_w = 2560, .logical_h = 1440, .scale_factor = 1.5, .refresh_mhz = 144_000 });
    try mgr.addOutput(.{ .id = 3, .logical_w = 1536, .logical_h = 2048, .scale_factor = 2.0, .refresh_mhz = 60_000 });

    const w1 = try mgr.createWindow(.layer_shell, 1, 1920, 28);
    const w2 = try mgr.createWindow(.toplevel, 2, 800, 600);
    const w3 = try mgr.createWindow(.layer_shell, 3, 1536, 32);

    const p1 = mgr.physicalSize(w1).?;
    const p2 = mgr.physicalSize(w2).?;
    const p3 = mgr.physicalSize(w3).?;
    try std.testing.expectEqual(@as(u32, 1920), p1.w);
    try std.testing.expectEqual(@as(u32, 28), p1.h);
    try std.testing.expectEqual(@as(u32, 1200), p2.w);
    try std.testing.expectEqual(@as(u32, 900), p2.h);
    try std.testing.expectEqual(@as(u32, 3072), p3.w);
    try std.testing.expectEqual(@as(u32, 64), p3.h);

    // Glyph atlas scale keys are distinct so 1.0x, 1.5x, 2.0x never thrash each other
    const k1 = mw.glyphScaleKey(1.0);
    const k2 = mw.glyphScaleKey(1.5);
    const k3 = mw.glyphScaleKey(2.0);
    try std.testing.expect(k1 != k2 and k2 != k3 and k1 != k3);

    // Fastest refresh across active outputs is 144Hz -> ~6944us
    try std.testing.expectEqual(@as(u32, 6944), mgr.minFrameIntervalUs());
}

test "MultiWindowManager: dragging window across monitors triggers scale transition and reraster" {
    var mgr = mw.MultiWindowManager.init();
    try mgr.addOutput(.{ .id = 1, .logical_w = 1920, .logical_h = 1080, .scale_factor = 1.0, .refresh_mhz = 60_000 });
    try mgr.addOutput(.{ .id = 2, .logical_w = 3840, .logical_h = 2160, .scale_factor = 2.0, .refresh_mhz = 120_000 });

    const wid = try mgr.createWindow(.toplevel, 1, 640, 480);
    mgr.clearDirty(wid);
    try std.testing.expect(!mgr.anyDirty());

    const scale_changed = try mgr.moveWindowToOutput(wid, 2);
    try std.testing.expect(scale_changed);
    const win = mgr.getWindow(wid).?;
    try std.testing.expectApproxEqAbs(@as(f32, 2.0), win.scale_factor, 0.001);
    try std.testing.expectEqual(@as(u32, 120_000), win.refresh_mhz);
    try std.testing.expect(win.needs_reraster);
    try std.testing.expect(mgr.anyDirty());
}

test "MultiWindowManager: monitor unplug migrates windows to remaining primary output" {
    var mgr = mw.MultiWindowManager.init();
    try mgr.addOutput(.{ .id = 1, .logical_w = 1920, .logical_h = 1080, .scale_factor = 1.0, .refresh_mhz = 60_000 });
    try mgr.addOutput(.{ .id = 2, .logical_w = 2560, .logical_h = 1440, .scale_factor = 1.5, .refresh_mhz = 144_000 });

    const wid = try mgr.createWindow(.toplevel, 2, 800, 600);
    mgr.clearDirty(wid);

    // Unplug monitor 2 -> window must migrate to monitor 1 and mark needs_reraster
    mgr.removeOutput(2);
    const win = mgr.getWindow(wid).?;
    try std.testing.expectEqual(@as(u32, 1), win.output_id);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), win.scale_factor, 0.001);
    try std.testing.expect(win.needs_reraster);
    try std.testing.expectEqual(@as(u32, 16666), mgr.minFrameIntervalUs());
}

test "MultiWindowManager: wp_fractional_scale_v1 scale_120 updates window scale safely" {
    var mgr = mw.MultiWindowManager.init();
    try mgr.addOutput(.{ .id = 1, .logical_w = 1920, .logical_h = 1080, .scale_factor = 1.0, .refresh_mhz = 60_000 });
    const wid = try mgr.createWindow(.toplevel, 1, 800, 600);
    mgr.clearDirty(wid);

    // 150 / 120 = 1.25x
    try std.testing.expect(try mgr.setWindowFractionalScale(wid, 150));
    const win = mgr.getWindow(wid).?;
    try std.testing.expectApproxEqAbs(@as(f32, 1.25), win.scale_factor, 0.001);
    try std.testing.expect(win.needs_reraster);

    // Out-of-range scale_120 rejected
    try std.testing.expectError(error.InvalidScale, mgr.setWindowFractionalScale(wid, 0));
    try std.testing.expectError(error.InvalidScale, mgr.setWindowFractionalScale(wid, 9999));
}

test "H1: updateOutput preserves setWindowFractionalScale override and move/migrate clear it" {
    var mgr = mw.MultiWindowManager.init();
    try mgr.addOutput(.{ .id = 1, .logical_w = 1920, .logical_h = 1080, .scale_factor = 1.0, .refresh_mhz = 60_000 });
    try mgr.addOutput(.{ .id = 2, .logical_w = 2560, .logical_h = 1440, .scale_factor = 1.5, .refresh_mhz = 144_000 });

    const wid = try mgr.createWindow(.toplevel, 1, 800, 600);
    try std.testing.expect(try mgr.setWindowFractionalScale(wid, 150)); // 1.25x
    try std.testing.expect(mgr.getWindow(wid).?.has_fractional_scale);
    mgr.clearDirty(wid);

    // Output 1 updates scale & refresh: refresh updates, fractional scale is preserved.
    try mgr.updateOutput(.{ .id = 1, .logical_w = 1920, .logical_h = 1080, .scale_factor = 2.0, .refresh_mhz = 120_000 });
    const after_update = mgr.getWindow(wid).?;
    try std.testing.expect(after_update.has_fractional_scale);
    try std.testing.expectApproxEqAbs(@as(f32, 1.25), after_update.scale_factor, 0.001);
    try std.testing.expectEqual(@as(u32, 120_000), after_update.refresh_mhz);
    try std.testing.expect(!after_update.needs_reraster);

    // moveWindowToOutput resets has_fractional_scale and adopts destination output scale.
    try std.testing.expect(try mgr.moveWindowToOutput(wid, 2));
    const after_move = mgr.getWindow(wid).?;
    try std.testing.expect(!after_move.has_fractional_scale);
    try std.testing.expectApproxEqAbs(@as(f32, 1.5), after_move.scale_factor, 0.001);

    // Set fractional scale again, then migrate via removeOutput -> resets has_fractional_scale.
    try std.testing.expect(try mgr.setWindowFractionalScale(wid, 210)); // 1.75x
    try std.testing.expect(mgr.getWindow(wid).?.has_fractional_scale);
    mgr.removeOutput(2);
    const after_migrate = mgr.getWindow(wid).?;
    try std.testing.expectEqual(@as(u32, 1), after_migrate.output_id);
    try std.testing.expect(!after_migrate.has_fractional_scale);
    try std.testing.expectApproxEqAbs(@as(f32, 2.0), after_migrate.scale_factor, 0.001);
}

test "H2: orphan reset to 60Hz/16666us and automatic reattach on addOutput and updateOutput reconnect" {
    var mgr = mw.MultiWindowManager.init();
    try mgr.addOutput(.{ .id = 1, .logical_w = 2560, .logical_h = 1440, .scale_factor = 1.5, .refresh_mhz = 144_000 });

    const wid = try mgr.createWindow(.toplevel, 1, 800, 600);
    _ = try mgr.setWindowFractionalScale(wid, 180);
    mgr.clearDirty(wid);

    // Disconnect output 1 with no other output -> window becomes orphaned.
    try mgr.updateOutput(.{ .id = 1, .logical_w = 0, .logical_h = 0, .scale_factor = 0, .refresh_mhz = 0, .connected = false });
    const orphaned = mgr.getWindow(wid).?;
    try std.testing.expectEqual(@as(u32, 0), orphaned.output_id);
    try std.testing.expectEqual(@as(u32, 60_000), orphaned.refresh_mhz);
    try std.testing.expectEqual(mw.DEFAULT_FRAME_INTERVAL_US, orphaned.frame_budget_us);
    try std.testing.expect(!orphaned.has_fractional_scale);
    try std.testing.expect(orphaned.dirty);

    // Reconnecting output 1 via updateOutput reattaches orphan.
    mgr.clearDirty(wid);
    try mgr.updateOutput(.{ .id = 1, .logical_w = 3840, .logical_h = 2160, .scale_factor = 2.0, .refresh_mhz = 120_000, .connected = true });
    const reconnected = mgr.getWindow(wid).?;
    try std.testing.expectEqual(@as(u32, 1), reconnected.output_id);
    try std.testing.expectApproxEqAbs(@as(f32, 2.0), reconnected.scale_factor, 0.001);
    try std.testing.expectEqual(@as(u32, 120_000), reconnected.refresh_mhz);
    try std.testing.expectEqual(@as(u32, 8333), reconnected.frame_budget_us);
    try std.testing.expect(reconnected.dirty);
    try std.testing.expect(reconnected.needs_reraster);

    // Remove output 1 -> orphan again, then addOutput reattaches with same scale (no reraster needed).
    mgr.removeOutput(1);
    try std.testing.expectEqual(@as(u32, 0), mgr.getWindow(wid).?.output_id);
    mgr.clearDirty(wid);
    try mgr.addOutput(.{ .id = 2, .logical_w = 1920, .logical_h = 1080, .scale_factor = 2.0, .refresh_mhz = 75_000 });
    const readded = mgr.getWindow(wid).?;
    try std.testing.expectEqual(@as(u32, 2), readded.output_id);
    try std.testing.expectEqual(@as(u32, 75_000), readded.refresh_mhz);
    try std.testing.expectEqual(@as(u32, 13333), readded.frame_budget_us);
    try std.testing.expect(readded.dirty);
    try std.testing.expect(!readded.needs_reraster);
}

test "H3: updateOutput with connected = false and zeroed fields migrates cleanly" {
    var mgr = mw.MultiWindowManager.init();
    try mgr.addOutput(.{ .id = 1, .logical_w = 1920, .logical_h = 1080, .scale_factor = 1.0, .refresh_mhz = 60_000 });
    try mgr.addOutput(.{ .id = 2, .logical_w = 2560, .logical_h = 1440, .scale_factor = 1.5, .refresh_mhz = 144_000 });

    const wid = try mgr.createWindow(.toplevel, 2, 800, 600);
    mgr.clearDirty(wid);

    try std.testing.expectError(error.InvalidOutput, mgr.updateOutput(.{ .id = 0, .logical_w = 0, .logical_h = 0, .scale_factor = 0, .refresh_mhz = 0, .connected = false }));
    try std.testing.expectError(error.OutputNotFound, mgr.updateOutput(.{ .id = 99, .logical_w = 0, .logical_h = 0, .scale_factor = 0, .refresh_mhz = 0, .connected = false }));

    try mgr.updateOutput(.{ .id = 2, .logical_w = 0, .logical_h = 0, .scale_factor = 0, .refresh_mhz = 0, .connected = false });
    const win = mgr.getWindow(wid).?;
    try std.testing.expectEqual(@as(u32, 1), win.output_id);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), win.scale_factor, 0.001);
    try std.testing.expect(win.needs_reraster);
    try std.testing.expect(win.dirty);
    try std.testing.expectEqual(@as(u32, 16666), mgr.minFrameIntervalUs());
}

test "M4: addOutput rejects connected = false, zero dimensions, and duplicate ID" {
    var mgr = mw.MultiWindowManager.init();
    try std.testing.expectError(error.InvalidOutput, mgr.addOutput(.{ .id = 1, .logical_w = 1920, .logical_h = 1080, .connected = false }));
    try std.testing.expectError(error.InvalidOutput, mgr.addOutput(.{ .id = 1, .logical_w = 0, .logical_h = 1080 }));
    try std.testing.expectError(error.InvalidOutput, mgr.addOutput(.{ .id = 1, .logical_w = 1920, .logical_h = 0 }));

    try mgr.addOutput(.{ .id = 1, .logical_w = 1920, .logical_h = 1080 });
    try std.testing.expectError(error.DuplicateOutput, mgr.addOutput(.{ .id = 1, .logical_w = 1920, .logical_h = 1080 }));
}

test "M5: scaleChanged detects glyphScaleKey boundary crossing (1.004 -> 1.005) and prevents drift" {
    var mgr = mw.MultiWindowManager.init();
    try mgr.addOutput(.{ .id = 1, .logical_w = 1920, .logical_h = 1080, .scale_factor = 1.004 });
    const wid = try mgr.createWindow(.toplevel, 1, 800, 600);
    mgr.clearDirty(wid);

    // 1.004 * 120 = 120.48 -> 120; 1.005 * 120 = 120.60 -> 121 (delta < SCALE_EPSILON in f32, yet key changes).
    try mgr.updateOutput(.{ .id = 1, .logical_w = 1920, .logical_h = 1080, .scale_factor = 1.005 });
    const win = mgr.getWindow(wid).?;
    try std.testing.expectApproxEqAbs(@as(f32, 1.005), win.scale_factor, 1e-6);
    try std.testing.expect(win.needs_reraster);
    try std.testing.expect(win.dirty);

    // Small sub-epsilon update without key change still updates stored scale_factor to avoid drift.
    mgr.clearDirty(wid);
    try mgr.updateOutput(.{ .id = 1, .logical_w = 1920, .logical_h = 1080, .scale_factor = 1.0054 });
    const no_key_change = mgr.getWindow(wid).?;
    try std.testing.expectApproxEqAbs(@as(f32, 1.0054), no_key_change.scale_factor, 1e-6);
    try std.testing.expect(!no_key_change.needs_reraster);
}

test "M6: same-scale migration and moveWindowToOutput set dirty without needs_reraster" {
    var mgr = mw.MultiWindowManager.init();
    try mgr.addOutput(.{ .id = 1, .logical_w = 1920, .logical_h = 1080, .scale_factor = 1.5, .refresh_mhz = 60_000 });
    try mgr.addOutput(.{ .id = 2, .logical_w = 2560, .logical_h = 1440, .scale_factor = 1.5, .refresh_mhz = 144_000 });
    try mgr.addOutput(.{ .id = 3, .logical_w = 1920, .logical_h = 1080, .scale_factor = 1.5, .refresh_mhz = 75_000 });

    const wid = try mgr.createWindow(.toplevel, 2, 800, 600);
    mgr.clearDirty(wid);

    // Same-scale moveWindowToOutput sets dirty = true, needs_reraster = false.
    try std.testing.expect(!try mgr.moveWindowToOutput(wid, 3));
    const after_move = mgr.getWindow(wid).?;
    try std.testing.expectEqual(@as(u32, 3), after_move.output_id);
    try std.testing.expect(after_move.dirty);
    try std.testing.expect(!after_move.needs_reraster);

    // Same-scale migration sets dirty = true, needs_reraster = false.
    mgr.clearDirty(wid);
    mgr.removeOutput(3);
    const after_migrate = mgr.getWindow(wid).?;
    try std.testing.expectEqual(@as(u32, 1), after_migrate.output_id);
    try std.testing.expect(after_migrate.dirty);
    try std.testing.expect(!after_migrate.needs_reraster);
}

test "M7: glyphScaleKey handles zero and negative scales safely" {
    try std.testing.expectEqual(@as(u16, 120), mw.glyphScaleKey(0.0));
    try std.testing.expectEqual(@as(u16, 120), mw.glyphScaleKey(-1.5));
    try std.testing.expectEqual(@as(u16, 60), mw.glyphScaleKey(0.1));
}

test "L11: capacity limits, ID wraparound, invalid window sizes, and fractional scale boundaries" {
    var mgr = mw.MultiWindowManager.init();

    // Fill MAX_OUTPUTS and verify TooManyOutputs.
    var out_id: u32 = 1;
    while (out_id <= mw.MAX_OUTPUTS) : (out_id += 1) {
        try mgr.addOutput(.{ .id = out_id, .logical_w = 1920, .logical_h = 1080 });
    }
    try std.testing.expectError(error.TooManyOutputs, mgr.addOutput(.{ .id = 100, .logical_w = 1920, .logical_h = 1080 }));

    // Invalid window sizes rejected.
    try std.testing.expectError(error.InvalidWindowSize, mgr.createWindow(.toplevel, 1, 0, 100));
    try std.testing.expectError(error.InvalidWindowSize, mgr.createWindow(.toplevel, 1, 100, -1));
    try std.testing.expectError(error.InvalidWindowSize, mgr.createWindow(.toplevel, 1, std.math.nan(f32), 100));
    try std.testing.expectError(error.InvalidWindowSize, mgr.createWindow(.toplevel, 1, 100, std.math.inf(f32)));

    // Fill MAX_WINDOWS and verify TooManyWindows.
    var w_idx: usize = 0;
    while (w_idx < mw.MAX_WINDOWS) : (w_idx += 1) {
        _ = try mgr.createWindow(.toplevel, 1, 640, 480);
    }
    try std.testing.expectError(error.TooManyWindows, mgr.createWindow(.toplevel, 1, 640, 480));

    // Fractional scale boundaries: 59 (invalid), 60 (valid), 1200 (valid), 1201 (invalid).
    const first_win_id = mgr.windows[0].id;
    try std.testing.expectError(error.InvalidScale, mgr.setWindowFractionalScale(first_win_id, 59));
    try std.testing.expect(try mgr.setWindowFractionalScale(first_win_id, 60));
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), mgr.getWindow(first_win_id).?.scale_factor, 0.001);
    try std.testing.expect(try mgr.setWindowFractionalScale(first_win_id, 1200));
    try std.testing.expectApproxEqAbs(@as(f32, 10.0), mgr.getWindow(first_win_id).?.scale_factor, 0.001);
    try std.testing.expectError(error.InvalidScale, mgr.setWindowFractionalScale(first_win_id, 1201));

    // next_window_id wraparound past maxInt(u32) skips 0 and live IDs (window 1 is still alive).
    try std.testing.expect(mgr.destroyWindow(2));
    mgr.next_window_id = std.math.maxInt(u32);
    const id_max = try mgr.createWindow(.toplevel, 1, 640, 480);
    try std.testing.expectEqual(std.math.maxInt(u32), id_max);

    try std.testing.expect(mgr.destroyWindow(3));
    const id_wrapped = try mgr.createWindow(.toplevel, 1, 640, 480);
    try std.testing.expectEqual(@as(u32, 2), id_wrapped);
}
