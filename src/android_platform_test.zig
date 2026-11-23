const std = @import("std");
const ap = @import("android_platform.zig");

test "HapticPattern: maps tap, confirm, double_pulse, and error to bounded vibration ms" {
    try std.testing.expectEqual(@as(u32, 18), ap.hapticDurationMs(.tap));
    try std.testing.expectEqual(@as(u32, 45), ap.hapticDurationMs(.confirm));
    try std.testing.expectEqual(@as(u32, 80), ap.hapticDurationMs(.err));
    const pulses = ap.hapticPattern(.double_pulse);
    try std.testing.expect(pulses.len >= 3);
}

test "SoftKeyboardState: idempotent show/hide and uppercase/IME key translation" {
    var kb = ap.SoftKeyboardState.init();
    try std.testing.expect(!kb.visible);
    try std.testing.expect(kb.requestShow());
    try std.testing.expect(kb.visible);
    // Repeated show is a no-op returning false
    try std.testing.expect(!kb.requestShow());
    try std.testing.expect(kb.requestHide());
    try std.testing.expect(!kb.visible);
    try std.testing.expect(!kb.requestHide());

    kb.syncVisible(true);
    try std.testing.expect(kb.visible);
    try std.testing.expect(!kb.requestShow());
    kb.syncVisible(false);
    try std.testing.expect(!kb.visible);
    try std.testing.expect(!kb.requestHide());

    // Android AKEYCODE -> ASCII translation for VIN/MAC entry
    // AKEYCODE_A = 29, AKEYCODE_0 = 7, AKEYCODE_DEL = 67
    try std.testing.expectEqual(@as(?u8, 'a'), ap.androidKeycodeToAscii(29, false));
    try std.testing.expectEqual(@as(?u8, 'A'), ap.androidKeycodeToAscii(29, true));
    try std.testing.expectEqual(@as(?u8, '0'), ap.androidKeycodeToAscii(7, false));
    try std.testing.expectEqual(@as(?u8, '9'), ap.androidKeycodeToAscii(16, false));
    try std.testing.expectEqual(@as(?u8, '0'), ap.androidKeycodeToAscii(144, false));
    try std.testing.expectEqual(@as(?u8, '9'), ap.androidKeycodeToAscii(153, true));
    try std.testing.expectEqual(@as(?u8, '-'), ap.androidKeycodeToAscii(69, false));
    try std.testing.expectEqual(@as(?u8, '_'), ap.androidKeycodeToAscii(69, true));
    try std.testing.expectEqual(@as(?u8, null), ap.androidKeycodeToAscii(67, false));
    try std.testing.expect(ap.isAndroidBackspace(67));
    try std.testing.expect(ap.isAndroidEnter(66));
}

test "KeepScreenOnState: tracks flag transitions cleanly" {
    var ks = ap.KeepScreenOnState.init();
    try std.testing.expect(!ks.enabled);
    try std.testing.expect(ks.setEnabled(true));
    try std.testing.expect(!ks.setEnabled(true));
    try std.testing.expect(ks.setEnabled(false));
    try std.testing.expect(!ks.enabled);
}

test "AndroidBridge: references native bridge methods and returns false on host" {
    const keep_fn = &ap.AndroidBridge.setKeepScreenOnNative;
    const show_fn = &ap.AndroidBridge.showSoftInputNative;
    const hide_fn = &ap.AndroidBridge.hideSoftInputNative;
    const vib_fn = &ap.AndroidBridge.vibrateNative;
    _ = .{ keep_fn, show_fn, hide_fn, vib_fn };

    if (comptime !ap.is_android) {
        var dummy: u8 = 0;
        const ptr: *anyopaque = @ptrCast(&dummy);
        keep_fn(ptr, true);
        show_fn(ptr);
        hide_fn(ptr);
        try std.testing.expect(!vib_fn(ptr, .tap));
    }
}
